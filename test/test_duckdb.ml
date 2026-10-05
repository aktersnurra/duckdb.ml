open! Base
module D = Duckdb
external arm : int -> unit = "test_arm" [@@noalloc]
external entered : unit -> int = "test_entered" [@@noalloc]
external release : unit -> unit = "test_release" [@@noalloc]
external fail_rollback : unit -> unit = "test_fail_rollback" [@@noalloc]
external trace_reset : unit -> unit = "test_trace_reset" [@@noalloc]
external trace : unit -> int = "test_trace" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let rec same_error (a : D.Error.cause) (b : D.Error.cause) = match a, b with
  | Invalid_configuration a, Invalid_configuration b | Native a, Native b -> String.equal a b
  | Embedded_nul, Embedded_nul | Closed, Closed | Busy, Busy
  | Unsupported_statement, Unsupported_statement | Effects_not_allowed, Effects_not_allowed -> true
  | Rollback_failed a, Rollback_failed b ->
    same_error a.primary.cause b.primary.cause && same_error a.rollback.cause b.rollback.cause
  | _ -> false
let error (expected : D.Error.cause) = function
  | Error { D.Error.cause; _ } when same_error expected cause -> () | _ -> failwith "wrong error"
let native_error = function Error { D.Error.cause = Native _; _ } -> () | _ -> failwith "expected native error"
let config = ok (D.Config.create Memory)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
(* Owned handles are global: callbacks and threads may capture them. *)
let with_owned f =
  let db = ok (D.Owned.open_database config) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f db c))
let wait predicate =
  let rec loop n = if predicate () then () else if n = 0 then failwith "handshake timeout"
    else (Thread.delay 0.001; loop (n - 1)) in loop 5000
exception Callback
let lifecycle () =
  List.iter [0; -1; Int.min_value] ~f:(fun threads ->
    match D.Config.create ~threads Memory with Error { cause = Invalid_configuration _; _ } -> () | _ -> assert false);
  List.iter [""; ":memory:"; "bad\000path"; "md:remote"; "https://remote"] ~f:(fun path ->
    match D.Config.create (File path) with Error { cause = Invalid_configuration _; _ } -> () | _ -> assert false);
  (match D.Config.create ~access:Read_only Memory with Error { cause = Invalid_configuration _; _ } -> () | _ -> assert false);
  (match D.Config.create ~memory_limit_bytes:(-1) Memory with Error { cause = Invalid_configuration _; _ } -> () | _ -> assert false);
  for _ = 1 to 20 do
    native_error (D.Owned.open_database (ok (D.Config.create (File "/proc/duckdb-stage3a-missing/db")))); clean ()
  done;
  ok (D.with_database (ok (D.Config.create ~threads:2 ~memory_limit_bytes:128_000_000 Memory))
    ~f:(fun db -> D.with_connection db ~f:(fun c ->
      D.execute c "select case when current_setting('threads')=2 then 1 else error('threads') end")));
  (match D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun _ -> raise Callback)) with
   | exception Callback -> () | _ -> assert false);
  clean ();
  let db = ok (D.Owned.open_database config) in
  let c = ok (D.Owned.connect db) in
  error D.Error.Busy (D.Owned.close_database db);
  ok (D.execute c "create table t(i integer)");
  for _ = 1 to 50 do native_error (D.execute c "select missing from nowhere"); ok (D.execute c "select 42") done;
  error Embedded_nul (D.execute c "select 1\000; select 2");
  List.iter ["COMMIT"; "BEGIN"; "ROLLBACK"; "select 1; select 2"; "PREPARE x AS SELECT 1"; "EXPLAIN ANALYZE COMMIT"]
    ~f:(fun sql -> error D.Error.Unsupported_statement (D.execute c sql));
  let alias = c in
  ok (D.Owned.close_connection c); ok (D.Owned.close_connection alias);
  error Closed (D.execute alias "select 1");
  ok (D.Owned.close_database db); ok (D.Owned.close_database db); error Closed (D.Owned.connect db); clean ();
  Stdlib.print_endline "duckdb: config/errors/aliases/parent-child/scoped=ok"
let persistence () =
  let path = Stdlib.Filename.temp_file "duckdb-stage3a" ".db" in
  Stdlib.Sys.remove path;
  Exn.protect ~finally:(fun () -> Stdlib.Sys.remove path) ~f:(fun () ->
    let file = ok (D.Config.create (File path)) in
    ok (D.with_database file ~f:(fun db -> D.with_connection db ~f:(fun c ->
      ok (D.execute c "create table persisted(i integer)"); D.execute c "insert into persisted values (42)")));
    let file = ok (D.Config.create ~access:Read_only (File path)) in
    ok (D.with_database file ~f:(fun db -> D.with_connection db ~f:(fun c ->
      native_error (D.execute c "insert into persisted values (7)");
      D.execute c "select case when sum(i)=42 then 1 else error('persistence') end from persisted"))));
  clean (); Stdlib.print_endline "duckdb: persistence/read-only=ok"
let transactions () =
  with_owned (fun db c ->
    ok (D.execute c "create table t(i integer)");
    let count n = ok (D.execute c ("select case when count(*)=" ^ Int.to_string n ^
      " then 1 else error('transaction count') end from t")) in
    ok (D.with_transaction c ~f:(fun tx ->
      error Busy (D.execute c "select 1"); error Busy (D.Owned.close_connection c);
      error Busy (D.Owned.close_database db);
      error Busy (D.with_transaction c ~f:(fun _ -> Ok ()));
      D.execute tx "insert into t values (1)")); count 1;
    error Effects_not_allowed (D.with_transaction c ~f:(fun tx ->
      ok (D.execute tx "insert into t values (2)");
      Error { context = Transaction; cause = Effects_not_allowed })); count 1;
    (match D.with_transaction c ~f:(fun tx ->
      ok (D.execute tx "insert into t values (3)"); raise Callback) with
     | exception Callback -> () | _ -> assert false); count 1;
    native_error (D.with_transaction c ~f:(fun tx ->
      ok (D.execute tx "insert into t values (4)"); D.execute tx "select missing")); count 1);
  clean (); Stdlib.print_endline "duckdb: transactions/rollback/error/exn=ok"
type _ Stdlib.Effect.t += Pause : unit Stdlib.Effect.t
let effects () =
  let delivered = ref false in
  let result = Stdlib.Effect.Deep.try_with (fun () ->
    D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
      D.with_transaction c ~f:(fun _ -> Stdlib.Effect.perform Pause; Ok ())))) ()
    { effc = fun (type a) (_ : a Stdlib.Effect.t) -> delivered := true; None } in
  error Effects_not_allowed result; assert (not !delivered); clean ();
  error Effects_not_allowed (D.with_database config ~f:(fun _ ->
    (try Stdlib.Effect.perform Pause with _ -> ()); Ok ()));
  clean ();
  (* A handler inside the callback cannot capture [tx] in its thunk
     (test/scope_compile/effect_escape.ml.fail). A handler installed outside
     the scope still captures a continuation holding [tx] on its stack: only
     the runtime barrier above (Effects_not_allowed) stops it. *)
  Stdlib.print_endline "duckdb: effects/no-escape=ok"
let ownership () =
  let db = ok (D.Owned.open_database config) in
  let c = ok (D.Owned.connect db) in
  arm 1;
  let result = ref None in
  let worker = Thread.create (fun () ->
    let sql = String.concat ["select 42 /*"; String.make 100_000 'x'; "*/"] in
    result := Some (D.execute c sql)) () in
  wait (fun () -> entered () = 1);
  Stdlib.Gc.full_major (); Stdlib.Gc.compact ();
  error Busy (D.execute c "select 1"); error Busy (D.Owned.close_connection c); error Busy (D.Owned.close_database db);
  release (); Thread.join worker; ok (Option.value_exn !result);
  ok (D.Owned.close_connection c); ok (D.Owned.close_database db); clean ();
  Stdlib.print_endline "duckdb: systhreads/exclusion=ok"
let rollback_failures () =
  with_owned (fun db c ->
    fail_rollback ();
    (match D.with_transaction c ~f:(fun _ -> Error { D.Error.context = Transaction; cause = Effects_not_allowed }) with
     | Error { cause = Rollback_failed { primary = { cause = Effects_not_allowed; _ }; rollback = { cause = Native _; _ } }; _ } -> ()
     | _ -> assert false);
    error Closed (D.execute c "select 1");
    let c = ok (D.Owned.connect db) in
    fail_rollback ();
    (match D.with_transaction c ~f:(fun _ -> raise Callback) with
     | exception D.Cleanup_exception ({ cause = Native _; _ }, Callback) -> () | _ -> assert false);
    error Closed (D.execute c "select 1"); ok (D.Owned.close_connection c));
  clean (); Stdlib.print_endline "duckdb: rollback-failure/outcome-preservation/discard=ok"
let destruction_order () =
  (* The old case, a scoped database closing an un-closed Owned child, can no
     longer be written: a scoped database cannot reach [Owned.connect]. *)
  trace_reset ();
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun _ -> Ok ())));
  assert (trace () = 12); clean ();
  Stdlib.print_endline "duckdb: disconnect-before-database-close=ok"
let () = lifecycle (); persistence (); transactions (); effects (); ownership ();
  rollback_failures (); destruction_order ()
(* Native counters were checked before GC at every scope. This only lets the
   OCaml runtime finalize its mutex/condition/thread bookkeeping for diagnostics. *)
let () = Stdlib.Gc.full_major (); Stdlib.Gc.full_major (); clean ()
