open! Base
open Duckdb
external arm : int -> int -> unit = "signal_arm" [@@noalloc]
external injections : unit -> int = "signal_injections" [@@noalloc]
external live_at_signal : unit -> int = "signal_live" [@@noalloc]
external fail_control : int -> unit = "schema_fail_control" [@@noalloc]
let handled = Stdlib.Atomic.make 0
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let closed = function Error { Error.cause = Closed; _ } -> () | _ -> failwith "unclean connection was not discarded"
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let config = ok (Config.create Memory)
let count c expected = ok (execute c (Stdlib.Printf.sprintf
  "SELECT CASE WHEN count(*)=%d THEN 1 ELSE error('snapshot settlement') END FROM t" expected))
let signal_case ~revalidate operation boundary ordinal expected_live =
  Stdlib.Atomic.set handled 0;
  ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
    with_connection db ~f:(fun observer ->
      ok (execute c "CREATE TABLE t(x BIGINT)");
      Statement.with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
        ok (Statement.bind p 1 (Codec.Values.int64) 9007199254740993L);
        let rollback = String.equal operation "rollback" in
        let rejection_close = String.equal operation "rejection-close" in
        if rollback || rejection_close then ok (execute c "ALTER TABLE t ALTER x TYPE DOUBLE");
        (* Unrelated DDL advances the schema epoch, so execution re-validates. *)
        if revalidate then ok (execute observer "CREATE TABLE unrelated(y BIGINT)");
        if String.equal boundary "enter" then arm ordinal 0 else arm 0 ordinal;
        let outcome = try Ok (Statement.execute p) with exn -> Error exn in
        let discarded = rollback ||
          (String.equal operation "begin" && String.equal boundary "enter") ||
          (String.equal operation "commit" && String.equal boundary "leave") in
        (match rollback || rejection_close, discarded, outcome with
         | true, _, Error (Cleanup_exception ({ cause = Parameter_schema_changed; _ }, Stdlib.Sys.Break)) -> ()
         | false, true, Error (Cleanup_exception ({ cause = Native _; _ }, Stdlib.Sys.Break)) -> ()
         | false, false, Error Stdlib.Sys.Break -> ()
         | _ -> failwith "snapshot signal lost primary/rollback outcome");
        if discarded then (closed (execute c "SELECT 1"); closed (Statement.parameter_count p))
        else (ok (execute c "SELECT 1"); ok (Statement.reset p));
        count observer (if String.equal operation "commit" && String.equal boundary "leave" then 1 else 0);
        Stdlib.Printf.printf "snapshot-%s-%s revalidate=%b: live=%d expected=%d\n%!" operation boundary revalidate
          (live_at_signal ()) expected_live;
        assert (live_at_signal () = expected_live);
        assert (injections () = 1); assert (Stdlib.Atomic.get handled = 1);
        Ok ())))));
  clean ()
let () =
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1
    (Stdlib.Sys.Signal_handle (fun _ -> Stdlib.Atomic.incr handled; raise Stdlib.Sys.Break)) in
  Exn.protect ~finally:(fun () -> arm 0 0; fail_control 0; Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous)
    ~f:(fun () ->
      (* Observer adds two resources. Fixed named control SQL removes only
         the old transient SQL copy at control entry; returns are unchanged. *)
      List.iter ["begin", 1, 8, 8; "validate", 2, 10, 10;
        "validation-close", 3, 10, 9; "execute", 4, 8, 9;
        "commit", 5, 9, 9; "rollback", 4, 8, 8; "rejection-close", 3, 10, 9]
        ~f:(fun (operation, ordinal, enter_live, leave_live) ->
          signal_case ~revalidate:true operation "enter" ordinal enter_live;
          signal_case ~revalidate:true operation "leave" ordinal leave_live);
      (* Unchanged epoch: BEGIN, the original execute, COMMIT; no re-prepare. *)
      List.iter ["begin", 1, 8, 8; "execute", 2, 8, 9; "commit", 3, 9, 9]
        ~f:(fun (operation, ordinal, enter_live, leave_live) ->
          signal_case ~revalidate:false operation "enter" ordinal enter_live;
          signal_case ~revalidate:false operation "leave" ordinal leave_live));
  Stdlib.print_endline "schema signals: 14 re-validating and 6 skipped-validation boundaries; primary/rollback/commit, visibility, discard/reuse, zero fallback=ok"

let () =
  List.iter [1; 2; 3; 4] ~f:(fun fault ->
    ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
      with_connection db ~f:(fun observer ->
        ok (execute c "CREATE TABLE t(x BIGINT)");
        let sql = if fault = 4 then "SELECT error('primary snapshot query')" else "INSERT INTO t VALUES (?)" in
        Statement.with_prepared c sql ~f:(fun p ->
          if fault <> 4 then ok (Statement.bind p 1 (Codec.Values.int64) 9007199254740993L);
          if fault = 2 then ok (execute c "ALTER TABLE t ALTER x TYPE DOUBLE");
          fail_control (if fault = 4 then 2 else fault);
          let result = Statement.execute p in
          (match fault, result with
           | 1, Error { cause = Native message; _ } ->
             assert (String.is_substring message ~substring:"injected snapshot control failure");
             ok (execute c "SELECT 1")
           | 2, Error { cause = Rollback_failed { primary = { cause = Parameter_schema_changed; _ }; rollback = { cause = Native _; _ } }; _ } ->
             closed (execute c "SELECT 1"); closed (Statement.parameter_count p)
           | 4, Error { cause = Rollback_failed { primary = { cause = Native primary; _ }; rollback = { cause = Native secondary; _ } }; _ } ->
             assert (String.is_substring primary ~substring:"primary snapshot query");
             Stdlib.Printf.printf "failed rollback after native error: %s\n%!" secondary;
             assert (String.is_substring secondary ~substring:"aborted");
             closed (execute c "SELECT 1"); closed (Statement.parameter_count p)
           | 3, Error { cause = Rollback_failed { primary = { cause = Native _; _ }; rollback = { cause = Native _; _ } }; _ } ->
             closed (execute c "SELECT 1"); closed (Statement.parameter_count p)
           | _ -> failwith "snapshot control fault lost outcome/discard");
          count observer 0;
          Ok ())))));
    clean ());
  Stdlib.print_endline "schema faults: BEGIN/COMMIT/ROLLBACK failures preserve outcomes and discard only unclean connections=ok"
