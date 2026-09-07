open! Base
module D = Duckdb
external arm : int -> unit = "test_arm" [@@noalloc]
external entered : unit -> int = "test_entered" [@@noalloc]
external release : unit -> unit = "test_release" [@@noalloc]
external waiting : unit -> bool = "test_waiting" [@@noalloc]
external calls : unit -> int = "test_calls" [@@noalloc]
external fail_rollback : unit -> unit = "test_fail_rollback" [@@noalloc]
external trace_reset : unit -> unit = "test_trace_reset" [@@noalloc]
external trace : unit -> int = "test_trace" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let rec same_error (a : D.error) (b : D.error) = match a, b with
  | Invalid_configuration a, Invalid_configuration b | Native_error a, Native_error b -> String.equal a b
  | Embedded_nul, Embedded_nul | Closed, Closed | Busy, Busy | Live_children, Live_children
  | Unsupported_statement, Unsupported_statement | Effects_not_allowed, Effects_not_allowed -> true
  | Rollback_failed (a, b), Rollback_failed (c, d) -> same_error a c && same_error b d
  | _ -> false
let error (expected : D.error) = function Error actual when same_error expected actual -> () | _ -> failwith "wrong error"
let native_error = function Error (D.Native_error _) -> () | _ -> failwith "expected native error"
let config = ok (D.Config.create Memory)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let wait predicate =
  let rec loop n = if predicate () then () else if n = 0 then failwith "handshake timeout"
    else (Thread.delay 0.001; loop (n - 1)) in loop 5000
exception Callback
let lifecycle () =
  List.iter [0; -1; Int.min_value] ~f:(fun threads ->
    match D.Config.create ~threads Memory with Error (Invalid_configuration _) -> () | _ -> assert false);
  List.iter [""; ":memory:"; "bad\000path"; "md:remote"; "https://remote"] ~f:(fun path ->
    match D.Config.create (File path) with Error (Invalid_configuration _) -> () | _ -> assert false);
  (match D.Config.create ~access:Read_only Memory with Error (Invalid_configuration _) -> () | _ -> assert false);
  (match D.Config.create ~memory_limit_bytes:(-1) Memory with Error (Invalid_configuration _) -> () | _ -> assert false);
  for _ = 1 to 20 do
    native_error (D.open_database (ok (D.Config.create (File "/proc/duckdb-stage3a-missing/db")))); clean ()
  done;
  ok (D.with_database (ok (D.Config.create ~threads:2 ~memory_limit_bytes:128_000_000 Memory))
    ~f:(fun db -> D.with_connection db ~f:(fun c ->
      D.execute c "select case when current_setting('threads')=2 then 1 else error('threads') end")));
  ok (D.with_database config ~f:D.close_database);
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:D.close_connection));
  clean ();
  (match D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun _ -> raise Callback)) with
   | exception Callback -> () | _ -> assert false);
  clean ();
  let db = ok (D.open_database config) in
  let c = ok (D.connect db) in
  error D.Live_children (D.close_database db);
  ok (D.execute c "create table t(i integer)");
  for _ = 1 to 50 do native_error (D.execute c "select missing from nowhere"); ok (D.execute c "select 42") done;
  error Embedded_nul (D.execute c "select 1\000; select 2");
  List.iter ["COMMIT"; "BEGIN"; "ROLLBACK"; "select 1; select 2"; "PREPARE x AS SELECT 1"; "EXPLAIN ANALYZE COMMIT"]
    ~f:(fun sql -> error D.Unsupported_statement (D.execute c sql));
  let alias = c in
  ok (D.close_connection c); ok (D.close_connection alias);
  error Closed (D.execute alias "select 1");
  ok (D.close_database db); ok (D.close_database db); error Closed (D.connect db); clean ();
  let escaped_db = ok (D.with_database config ~f:(fun db ->
    let escaped_c = ok (D.with_connection db ~f:(fun c -> Ok c)) in
    error Closed (D.execute escaped_c "select 1");
    let _ = ok (D.connect db) in Ok db)) in
  error Closed (D.connect escaped_db); clean ();
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
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
    ok (D.execute c "create table t(i integer)");
    let count n = ok (D.execute c ("select case when count(*)=" ^ Int.to_string n ^
      " then 1 else error('transaction count') end from t")) in
    let escaped = ok (D.with_transaction c ~f:(fun tx ->
      error Busy (D.execute c "select 1"); error Busy (D.close_connection c);
      error Live_children (D.close_database db);
      error Busy (D.with_transaction c ~f:(fun _ -> Ok ()));
      ok (D.execute_transaction tx "insert into t values (1)"); Ok tx)) in
    error Closed (D.execute_transaction escaped "select 1"); count 1;
    error Effects_not_allowed (D.with_transaction c ~f:(fun tx ->
      ok (D.execute_transaction tx "insert into t values (2)"); Error Effects_not_allowed)); count 1;
    (match D.with_transaction c ~f:(fun tx ->
      ok (D.execute_transaction tx "insert into t values (3)"); raise Callback) with
     | exception Callback -> () | _ -> assert false); count 1;
    native_error (D.with_transaction c ~f:(fun tx ->
      ok (D.execute_transaction tx "insert into t values (4)"); D.execute_transaction tx "select missing")); count 1;
    Ok ()))); clean (); Stdlib.print_endline "duckdb: transactions/rollback/error/exn/revocation=ok"
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
  let saved : (unit, (unit, D.error) Result.t) Stdlib.Effect.Deep.continuation option ref = ref None in
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
    D.with_transaction c ~f:(fun tx ->
      Stdlib.Effect.Deep.match_with
        (fun () -> Stdlib.Effect.perform Pause; D.execute_transaction tx "select 1") ()
        { retc = Fn.id; exnc = raise;
          effc = fun (type a) (effect : a Stdlib.Effect.t) -> match effect with
            | Pause -> Some (fun (continuation : (a, _) Stdlib.Effect.Deep.continuation) -> saved := Some continuation; Ok ())
            | _ -> None }))));
  error Closed (Stdlib.Effect.Deep.continue (Option.value_exn !saved) ());
  clean (); Stdlib.print_endline "duckdb: effects/no-escape/inner-continuation-revoked=ok"
let ownership () =
  let db = ok (D.open_database config) in
  let c = ok (D.connect db) in
  arm 1;
  let result = ref None in
  let worker = Thread.create (fun () ->
    let sql = String.concat ["select 42 /*"; String.make 100_000 'x'; "*/"] in
    result := Some (D.execute c sql)) () in
  wait (fun () -> entered () = 1);
  Stdlib.Gc.full_major (); Stdlib.Gc.compact ();
  error Busy (D.execute c "select 1"); error Busy (D.close_connection c); error Live_children (D.close_database db);
  release (); Thread.join worker; ok (Option.value_exn !result);
  ok (D.close_connection c); ok (D.close_database db); clean ();
  let worker = ref None and observer = ref None in
  ok (D.with_database config ~f:(fun db ->
    let c = ok (D.connect db) in
    arm 1;
    worker := Some (Thread.create (fun () -> ok (D.execute c "select 42")) ());
    wait (fun () -> entered () = 1);
    observer := Some (Thread.create (fun () ->
      wait (fun () -> match D.execute c "select 1" with Error Closed -> true | Error Busy -> false | _ -> assert false);
      release ()) ());
    Ok ()));
  Thread.join (Option.value_exn !worker); Thread.join (Option.value_exn !observer); clean ();
  (* Concurrent manual close must be drained, not duplicated by scoped close. *)
  let closer = ref None and releaser = ref None in
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
    arm 2;
    closer := Some (Thread.create (fun () -> ok (D.close_connection c)) ());
    wait (fun () -> entered () = 2);
    releaser := Some (Thread.create (fun () -> wait waiting; release ()) ());
    Ok ())));
  Thread.join (Option.value_exn !closer); Thread.join (Option.value_exn !releaser);
  assert (calls () = 1); clean ();
  Stdlib.print_endline "duckdb: systhreads/exclusion/revocation/drain=ok"
let rollback_failures () =
  ok (D.with_database config ~f:(fun db ->
    let c = ok (D.connect db) in
    fail_rollback ();
    (match D.with_transaction c ~f:(fun _ -> Error D.Effects_not_allowed) with
     | Error (Rollback_failed (Effects_not_allowed, Native_error _)) -> () | _ -> assert false);
    error Closed (D.execute c "select 1");
    let c = ok (D.connect db) in
    fail_rollback ();
    (match D.with_transaction c ~f:(fun _ -> raise Callback) with
     | exception D.Rollback_exception (Callback, Native_error _) -> () | _ -> assert false);
    error Closed (D.execute c "select 1"); Ok ()));
  clean (); Stdlib.print_endline "duckdb: rollback-failure/outcome-preservation/discard=ok"
let transaction_drain () =
  let worker = ref None and observer = ref None in
  ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
    ok (D.execute c "create table t(i integer)");
    ok (D.with_transaction c ~f:(fun tx ->
      arm 1;
      worker := Some (Thread.create (fun () -> ok (D.execute_transaction tx "insert into t values (42)")) ());
      wait (fun () -> entered () = 1);
      error Busy (D.execute_transaction tx "select 1");
      observer := Some (Thread.create (fun () ->
        wait (fun () -> match D.execute_transaction tx "select 1" with
          | Error Closed -> true | Error Busy -> false | _ -> assert false);
        error Busy (D.execute c "select 1");
        release ()) ());
      Ok ()));
    Thread.join (Option.value_exn !worker); Thread.join (Option.value_exn !observer);
    arm 0;
    D.execute c "select case when sum(i)=42 then 1 else error('drain') end from t")));
  clean (); Stdlib.print_endline "duckdb: transaction/concurrent-token/revocation/drain=ok"
let destruction_order () =
  trace_reset ();
  ok (D.with_database config ~f:(fun db -> let _ = ok (D.connect db) in Ok ()));
  assert (trace () = 12); clean ();
  Stdlib.print_endline "duckdb: disconnect-before-database-close=ok"
let () = lifecycle (); persistence (); transactions (); effects (); ownership ();
  rollback_failures (); transaction_drain (); destruction_order ()
(* Native counters were checked before GC at every scope. This only lets the
   OCaml runtime finalize its mutex/condition/thread bookkeeping for diagnostics. *)
let () = Stdlib.Gc.full_major (); Stdlib.Gc.full_major (); clean ()
