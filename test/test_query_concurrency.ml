open! Base
module D = Duckdb
external arm : int -> unit = "query_arm" [@@noalloc]
external entered : unit -> int = "query_entered" [@@noalloc]
external release : unit -> unit = "query_release" [@@noalloc]
external waiting : unit -> bool = "query_waiting" [@@noalloc]
external fail_bind : unit -> unit = "query_fail_bind" [@@noalloc]
external fail_fetch : unit -> unit = "query_fail_fetch" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let busy = function Error { D.Error.cause = Busy; _ } -> () | _ -> failwith "expected Busy"
let wait predicate =
  let deadline = Unix.gettimeofday () +. 10. in
  while not (predicate ()) do
    if Float.(Unix.gettimeofday () > deadline) then (release (); failwith "handshake timeout");
    Thread.delay 0.001
  done
(* Thread.join alone does not propagate worker exceptions on this runtime. *)
let start f arg =
  let outcome = ref None in
  let thread = Thread.create (fun arg -> outcome := Some (try Ok (f arg) with exn -> Error exn)) arg in
  thread, outcome
let join (thread, outcome) =
  Thread.join thread;
  match !outcome with Some (Ok value) -> value | Some (Error exn) -> raise exn | None -> failwith "missing thread outcome"
let config = ok (D.Config.create Memory)
(* Owned handles are global, so threads may share them. A prepared statement
   is always local to its scope: threads prepare their own. *)
let with_owned f =
  let db = ok (D.Owned.open_database config) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () -> f db)
let owned_connection db f =
  let c = ok (D.Owned.connect db) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c)
let connected f = with_owned (fun db -> owned_connection db (fun c -> ok (f c)))
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let () =
  connected (fun c ->
    D.Statement.with_prepared c "select ?::BIGINT" ~f:(fun p ->
      ok (D.Statement.bind p 1 (D.Codec.Values.int64) 1L);
      fail_bind ();
      (match D.Statement.bind p 1 (D.Codec.Values.int64) 2L with Error { cause = Native _; _ } -> () | _ -> assert false);
      (match D.Statement.execute p with Error { cause = Unbound_parameter 1; _ } -> () | _ -> assert false);
      ok (D.Statement.bind p 1 (D.Codec.Values.int64) 3L);
      fail_fetch ();
      (match D.Statement.fold_chunks p ~init:() ~f:(fun _ () -> assert false) with Error { cause = Native _; _ } -> () | _ -> assert false);
      ok (D.Statement.execute p); Ok ()));
  clean (); Stdlib.print_endline "query: injected bind/fetch errors clean and reusable=ok"
let () =
  List.iter [1; 2] ~f:(fun point ->
    connected (fun c ->
      (* The fold pauses in execution (1) or in its first fetch (2). *)
      arm point;
      let outcome = ref None in
      let worker = start (fun () -> outcome := Some (
        D.Statement.with_prepared c "SELECT i FROM range(5000) t(i)" ~f:(fun p ->
          D.Statement.fold_chunks p ~init:() ~f:(fun _ () -> Ok (D.Stop ()))))) () in
      Exn.protect ~finally:(fun () -> release (); join worker; arm 0) ~f:(fun () ->
        wait (fun () -> entered () = point);
        busy (D.execute c "select 1");
        for _ = 1 to 10 do let _ = String.make 100000 'x' in Stdlib.Gc.compact () done);
      ok (Option.value_exn !outcome); Ok ()));
  clean (); Stdlib.print_endline "query: concurrent execute/fetch exclusion + unlocked GC progress=ok"
let () =
  connected (fun c ->
    D.Statement.with_prepared c "select 42::BIGINT" ~f:(fun p ->
      let result = D.Statement.fold_chunks p ~init:() ~f:(fun chunk () ->
        let outcome = ref None in
        let thread = start (fun () ->
          busy (D.execute c "select 1");
          busy (D.Statement.with_prepared c "select 1" ~f:(fun _ -> Ok ())); outcome := Some ()) () in
        join thread; assert (Option.is_some !outcome);
        assert (Int64.equal (ok (D.Statement.column chunk ~column:0 ~row:0 (D.Codec.Values.int64))) 42L);
        Ok (D.Stop ())) in
      result));
  clean (); Stdlib.print_endline "query: live borrowed callback allows concurrent fail-fast connection use without mutex deadlock=ok"
let () =
  connected (fun c ->
    let transaction_entered = Stdlib.Atomic.make false in
    let settle = Stdlib.Atomic.make false in
    let worker = ref None in
    arm 0;
    let releaser = start (fun () -> wait waiting; Stdlib.Atomic.set settle true) () in
    Exn.protect ~finally:(fun () -> Stdlib.Atomic.set settle true; join releaser; Option.iter !worker ~f:join)
      ~f:(fun () ->
        D.Statement.with_prepared c "select 1" ~f:(fun _ ->
          worker := Some (start (fun () -> ok (D.with_transaction c ~f:(fun tx ->
            Stdlib.Atomic.set transaction_entered true;
            wait (fun () -> Stdlib.Atomic.get settle);
            D.execute tx "select 2"))) ());
          wait (fun () -> Stdlib.Atomic.get transaction_entered); Ok ())));
  clean (); Stdlib.print_endline "query: scoped connection-prepared close drains another transaction lease=ok"
let () =
  List.iter [3; 4] ~f:(fun point ->
    connected (fun c ->
      (* Point 3 pauses in the extraction of the long dynamic SQL, point 4 in
         binding the long text. *)
      let sql = if point = 4 then "select ?::VARCHAR" else "select ?::VARCHAR /*" ^ String.make 100000 'x' ^ "*/" in
      arm point;
      let worker = start (fun () -> ok (D.Statement.with_prepared c sql ~f:(fun p ->
        let text = String.init 200000 ~f:(fun i -> if i % 17 = 0 then '\000' else 'a') in
        ok (D.Statement.bind p 1 (D.Codec.Values.string) text);
        D.Statement.fold_chunks p ~init:() ~f:(fun chunk () ->
          assert (String.equal text (ok (D.Statement.column chunk ~column:0 ~row:0 (D.Codec.Values.string))));
          Ok (D.Stop ()))))) () in
      Exn.protect ~finally:(fun () -> release (); join worker; arm 0) ~f:(fun () ->
        wait (fun () -> entered () = point);
        busy (D.execute c "select 1"); busy (D.Owned.close_connection c);
        for _ = 1 to 20 do let _ = String.make 100000 'g' in Stdlib.Gc.compact () done);
      Ok ()));
  clean (); Stdlib.print_endline "query: native-owned dynamic SQL/string lengths survive unlocked concurrent compaction=ok"

(* [revalidate]: unrelated DDL first advances the schema epoch, so execution
   re-prepares (points 3/5 pause inside that). Otherwise validation is skipped
   and the post-execution check in the same snapshot must catch the race. *)
let () =
  List.iter [true, 3; true, 5; true, 1; true, 6; false, 1; false, 6] ~f:(fun (revalidate, point) ->
    List.iter [false; true] ~f:(fun explicit ->
      with_owned (fun db -> owned_connection db (fun c -> owned_connection db (fun ddl ->
          ok (D.execute c "CREATE TABLE t(x BIGINT)");
          (* The statement is local to its scope, so the worker thread owns the
             whole scope; [prepared]/[go] order the main thread's DDL between
             preparation and execution. *)
          let prepared = Stdlib.Atomic.make false and go = Stdlib.Atomic.make false in
          let worker = start (fun () ->
            let executed = ref None in
            let run prepare = prepare ~f:(fun p ->
              ok (D.Statement.bind p 1 (D.Codec.Values.int64) 9007199254740993L);
              Stdlib.Atomic.set prepared true;
              wait (fun () -> Stdlib.Atomic.get go);
              executed := Some (D.Statement.execute p);
              Ok ()) in
            let scope = if explicit then D.with_transaction c ~f:(fun tx ->
              run (D.Statement.with_prepared tx "INSERT INTO t VALUES (?)") [@nontail])
              else run (D.Statement.with_prepared c "INSERT INTO t VALUES (?)") in
            !executed, scope) () in
          Exn.protect ~finally:(fun () -> Stdlib.Atomic.set go true; release ()) ~f:(fun () ->
            wait (fun () -> Stdlib.Atomic.get prepared);
            if revalidate then ok (D.execute ddl "CREATE TABLE unrelated(y BIGINT)");
            arm point;
            Stdlib.Atomic.set go true;
            wait (fun () -> entered () = point);
            (* Disarm only the DDL's passage through the same wrapped symbol. *)
            arm 0;
            ok (D.execute ddl "ALTER TABLE t ALTER x TYPE DOUBLE"));
          let executed, result = join worker in
          (match point, explicit, Option.value_exn executed with
           | (1 | 3), false, Error { cause = Parameter_schema_changed; _ } when point = 3 || not revalidate -> ()
           | 6, true, Ok () -> ()
           | 6, false, Error { cause = Rollback_failed { primary = { cause = Native primary; _ }; rollback = { cause = Native _; _ } }; _ } ->
             assert (String.is_substring primary ~substring:"Failed to commit: Transaction conflict")
           | _, _, Error { cause = Native message; _ } ->
             assert (String.is_substring message ~substring:"Transaction conflict")
           | _ -> failwith "schema race did not reject at the intended boundary");
          if point = 6 && explicit then (
            match result with
            | Error { cause = Rollback_failed { primary = { cause = Native primary; _ }; rollback = { cause = Native _; _ } }; _ } ->
              assert (String.is_substring primary ~substring:"Failed to commit: Transaction conflict")
            | _ -> failwith "expected outer commit conflict and rollback failure")
          else ok result;
          if point = 6 then (
            match D.execute c "SELECT 1" with Error { cause = Closed; _ } -> () | _ -> failwith "failed settlement did not discard")
          else ok (D.execute c "SELECT 1");
          ok (D.execute ddl "SELECT CASE WHEN count(*)=0 THEN 1 ELSE error('rounded insert') END FROM t");
          ok (D.execute ddl "INSERT INTO t VALUES (42)"))));
      clean ();
      Stdlib.Printf.printf "query: schema race point=%d explicit=%b revalidate=%b snapshot/conflict/no-insert/cleanup=ok\n%!"
        point explicit revalidate))

(* A cached typed request lent to an explicit transaction skips validation; when
   DDL becomes visible during its execution, the post-execution check fails and
   poisons the transaction, so nothing it wrote can commit. *)
let () =
  List.iter [false, false; false, true; true, false] ~f:(fun (revalidate, ignore_error) ->
    with_owned (fun db -> owned_connection db (fun c -> owned_connection db (fun ddl ->
        let module R = D.Request in
        let request_ok = function Ok x -> x | Error _ -> failwith "unexpected request error" in
        let insert = R.exec D.Fields.[int64] "INSERT INTO t VALUES (?)" in
        ok (D.execute c "CREATE TABLE t(x BIGINT)");
        request_ok (R.Session.exec c insert D.Args.[1L]);
        if revalidate then ok (D.execute ddl "CREATE TABLE unrelated(y BIGINT)");
        ok (D.execute c "DELETE FROM t");
        arm 1;
        let worker = start (fun () -> R.Session.with_transaction c ~f:(fun tx ->
          let outcome = R.Session.exec tx insert D.Args.[9007199254740993L] in
          (* Ignoring the error must still not commit: the transaction is poisoned. *)
          if ignore_error then Ok () else outcome)) () in
        Exn.protect ~finally:(fun () -> release ()) ~f:(fun () ->
          wait (fun () -> entered () = 1);
          arm 0;
          ok (D.execute ddl "ALTER TABLE t ALTER x TYPE DOUBLE"));
        (match join worker, revalidate with
         | Error { D.Error.cause = Parameter_schema_changed; _ }, false -> ()
         | Error { cause = Native message; _ }, true ->
           (* Re-validated in the transaction's own snapshot: the DDL conflicts instead. *)
           assert (String.is_substring message ~substring:"onflict")
         | Ok (), _ -> failwith "lent typed request committed across a schema change"
         | Error _, _ -> failwith "lent typed request: unexpected outcome");
        ok (D.execute ddl "SELECT CASE WHEN count(*)=0 THEN 1 ELSE error('rounded insert') END FROM t"))));
    clean ();
    Stdlib.Printf.printf "query: lent typed request schema race revalidate=%b ignore_error=%b poisons/rejects without insert=ok\n%!"
      revalidate ignore_error)
