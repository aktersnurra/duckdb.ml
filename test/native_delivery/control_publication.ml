open! Base
module D = Duckdb
module B = D.Bridge
module E = Evidence_support
external reset_hooks : unit -> unit = "delivery_reset"
external query_mode : unit -> unit = "delivery_query_mode"
external gate : int -> bool -> unit = "delivery_gate"
external entered : int -> int = "delivery_entered"
external count : int -> int = "delivery_count"
external selected_gate : bool -> unit = "delivery_selected_gate"
external selected_entered : unit -> bool = "delivery_selected_entered"
external snapshot_exception : bool -> unit = "delivery_snapshot_exception"
external control_failure : int -> unit = "delivery_control_failure"
external unlink_failure : bool -> unit = "delivery_unlink_failure"
let check name condition = if not condition then failwith name
let ok = function Ok x -> x | Error _ -> failwith "control-publication expected Ok"
let cancelled = function Error D.Cancelled -> () | _ -> failwith "control-publication expected Cancelled"
let reset () = reset_hooks (); query_mode ()
let release () = for i = 1 to 95 do gate i false done; selected_gate false
let wait id = E.await ~label:("control-publication boundary " ^ Int.to_string id) (fun () -> entered id > 0)
let one_controller () = check "control-publication sole controller joined" (count 10 = 1 && count 12 = 1)
let scalar c sql = ok (D.with_prepared c sql ~f:(fun p ->
  Result.bind (D.execute_prepared p) ~f:(fun r ->
    D.fold_rows r D.Row.(Column (Required Int64, Empty)) ~init:0L
      ~f:(fun (n, ()) _ -> Ok (D.Stop n)))))
let with_pair f = ok (D.with_database (ok (D.Config.create Memory)) ~f:(fun db ->
  D.with_connection db ~f:(fun owner -> D.with_connection db ~f:(fun observer ->
    ok (D.execute owner "CREATE TABLE cp(x BIGINT)"); f owner observer; Ok ()))))
let commit_case ~snapshot point _ = with_pair (fun owner observer ->
  reset (); gate point true;
  if point = 67 || point = 68 then selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let result = if snapshot then D.with_prepared c "INSERT INTO cp VALUES(1) RETURNING x" ~f:(fun p ->
      Result.bind (D.execute_prepared p) ~f:D.close_result)
    else D.with_transaction c ~f:(fun tx -> D.execute_transaction tx "INSERT INTO cp VALUES(1)") in
    cancelled (D.execute c "INSERT INTO cp VALUES(2)"); result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if point = 67 || point = 68 then E.await ~label:"COMMIT actually selected" selected_entered;
      gate point false;
      if point = 67 || point = 68 then (
        E.await ~label:"COMMIT retirement join" (fun () -> count 11 > 0);
        check "COMMIT selected cannot detach/reuse" (count 12 = 0 && count 13 = 0);
        selected_gate false);
      cancelled (join ());
      check "COMMIT native decision count" (count 7 = (if point = 65 then 0 else 1));
      check "known COMMIT success has no rollback obligation" (count 8 = (if point = 65 then 1 else 0));
      one_controller ();
      check "independent committed row observer" (Int64.equal (scalar observer "SELECT count(*) FROM cp") (if point = 65 then 0L else 1L)))))
let begin_case point _ = with_pair (fun owner observer ->
  reset (); gate point true; if point = 66 then selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c -> D.with_transaction c ~f:(fun _ -> failwith "cancelled BEGIN callback")))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if point = 66 then E.await ~label:"BEGIN selected" selected_entered;
      gate point false; selected_gate false; cancelled (join ());
      check "BEGIN native decision suppresses SQL and rollback" (count 6 = (if point = 64 then 0 else 1) && count 8 = (if point = 64 then 0 else 1));
      one_controller (); check "BEGIN observer empty" (Int64.equal (scalar observer "SELECT count(*) FROM cp") 0L))))
let with_directory f =
  let dir = Stdlib.Filename.temp_file "control-publication-" "" in
  Stdlib.Sys.remove dir; Unix.mkdir dir 0o700;
  Exn.protect ~finally:(fun () ->
    Array.iter (Stdlib.Sys.readdir dir) ~f:(fun n -> Stdlib.Sys.remove (Stdlib.Filename.concat dir n)); Unix.rmdir dir)
    ~f:(fun () -> f dir)
let read_file file =
  let channel = Stdlib.open_in_bin file in
  Exn.protect ~finally:(fun () -> Stdlib.close_in channel)
    ~f:(fun () -> Stdlib.really_input_string channel (Stdlib.in_channel_length channel))
let publication point owner = with_directory (fun dir ->
  let file = Stdlib.Filename.concat dir "out.parquet" in
  let destination = ok (D.Parquet.path file) in
  reset (); gate point true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let result = D.Parquet.export c ~query:"SELECT 42::BIGINT AS x" destination in
    cancelled (D.Parquet.export c ~query:"SELECT 1" destination); result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point;
      if point = 72 then check "actual linked file reader before cancel" (String.is_prefix (read_file file) ~prefix:"PAR1");
      ok (B.cancel request);
      let attempts = count 50 in
      E.await ~label:"controller completed reserve decision while file held" (fun () -> count 50 > attempts);
      check "filesystem publication never eligible for delivery" (count 51 = 0 && count 4 = 0);
      gate point false; cancelled (join ());
      check "publication decision count" (count 41 = (if point = 70 then 0 else 1));
      check "publication precedes suppressed COMMIT" (count 7 = 0 && count 8 = 1);
      check "only owned temp removed" (count 42 = 1);
      check "cancelled unlink follows controller join at actual entry" (count 49 = (if point = 65 then 0 else 1));
      check "final file survives cancellation and rollback" (Bool.equal (Stdlib.Sys.file_exists file) (point <> 70));
      check "no temporary survives" (Array.length (Stdlib.Sys.readdir dir) = (if point = 70 then 0 else 1));
      one_controller ())))
let reservation_or_copy point owner = with_directory (fun dir ->
  let file = Stdlib.Filename.concat dir "out.parquet" in
  let destination = ok (D.Parquet.path file) in
  reset (); gate point true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let result = D.Parquet.export c ~query:"SELECT 42::BIGINT AS x" destination in
    cancelled (D.Parquet.export c ~query:"SELECT 2" destination); result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point;
      check "reservation retains exclusive facade admission" (match D.execute owner "SELECT 1" with Error D.Busy -> true | _ -> false);
      ok (B.cancel request); gate point false; cancelled (join ());
      check "one or suppressed native reservation decision" (count 43 = (if point = 74 then 0 else 1));
      check "exact owned temp syscall count" (count 44 = (if point = 74 then 0 else 1));
      check "COPY next extraction suppressed" (count 45 = (if point <= 77 then 0 else if point = 80 then 2 else 1));
      check "COPY execute and publication suppressed" (count 47 = 0 && count 41 = 0 && count 7 = 0);
      if point = 78 then check "COPY bind suppressed" (count 48 = 0);
      check "only reserved temp cleaned" (count 42 = (if point = 74 then 0 else 1));
      check "reservation cleanup leaves no file" (Array.length (Stdlib.Sys.readdir dir) = 0);
      one_controller ())))
let next_file owner = with_directory (fun dir ->
  let file = ok (D.Parquet.path (Stdlib.Filename.concat dir "one.parquet")) in
  let missing = ok (D.Parquet.path (Stdlib.Filename.concat dir "missing.parquet")) in
  ok (D.Parquet.export owner ~query:"SELECT 1::BIGINT" file);
  reset ();
  let request = B.create () in
  cancelled (B.run request owner ~f:(fun c ->
    D.Parquet.fold_rows c [file;missing] D.Row.(Column (Required Int64,Empty)) ~init:()
      ~f:(fun _ () -> ok (B.cancel request); Ok (D.Continue ()))));
  check "next file has no extraction/execute" (count 0 = 2 && count 2 = 1);
  one_controller ())
exception Primary_failure
exception Rollback_failure
exception Snapshot_failure
exception Commit_return_failure
let () = Stdlib.Callback.Safe.register_exception "control_snapshot_failure" Snapshot_failure;
  Stdlib.Callback.Safe.register_exception "control_rollback_failure" Rollback_failure;
  Stdlib.Callback.Safe.register_exception "control_commit_return_failure" Commit_return_failure
let[@inline never] raise_control_primary () = raise Primary_failure
let capture f = try Ok (f ()) with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())
let has_trace trace name = String.is_substring (Stdlib.Printexc.raw_backtrace_to_string trace) ~substring:name
let native_message = function D.Native_error message -> not (String.is_empty message) | _ -> false
let rollback_matrix primary mode owner =
  reset (); control_failure mode;
  let request = B.create () in
  let outcome = capture (fun () -> B.run request owner ~f:(fun c -> D.with_transaction c ~f:(fun tx ->
    ok (D.execute_transaction tx "SELECT 1");
    let error = if String.equal primary "native" then (
      match D.execute_transaction tx "SELECT no_such_column" with Error e -> e | Ok () -> failwith "expected SQL failure")
      else D.Cancelled in
    ok (B.cancel request);
    if String.equal primary "exception" then raise_control_primary () else Error error))) in
  let primary_matches = if String.equal primary "native" then native_message else function D.Cancelled -> true | _ -> false in
  (match outcome, mode, primary with
   | Ok (Error (D.Rollback_failed (p, secondary))), 1, _ ->
     check "rollback retains primary/native diagnostic" (primary_matches p && native_message secondary)
   | Error (D.Rollback_exception (Primary_failure, secondary), trace), 1, "exception" ->
     check "rollback preserves callback backtrace" (native_message secondary && has_trace trace "raise_control_primary")
   | Error (D.Cleanup_exception (p, Rollback_failure), trace), 2, _ ->
     check "rollback exception retains primary and source" (primary_matches p && has_trace trace "raw_control")
   | Error (Exn.Finally (Primary_failure, Rollback_failure), trace), 2, "exception" ->
     check "two exceptions preserve original callback trace" (has_trace trace "raise_control_primary")
   | _ -> failwith "rollback matrix lost constituent outcome");
  control_failure 0;
  check "failed rollback discards owner" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false);
  one_controller ()
let commit_return_exception _ = with_pair (fun owner observer ->
  reset (); control_failure 3;
  let outcome = capture (fun () -> B.run (B.create ()) owner ~f:(fun c -> D.with_transaction c ~f:(fun tx ->
    D.execute_transaction tx "INSERT INTO cp VALUES(1)"))) in
  (match outcome with
   | Error (D.Rollback_exception (Commit_return_failure, secondary), trace) ->
     check "uncertain commit exception and rollback diagnostics retained" (native_message secondary && has_trace trace "raw_control")
   | _ -> failwith "uncertain commit transition exception lost");
  control_failure 0;
  check "uncertain commit discards rather than reuses" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false);
  check "actual commit precedes transition exception" (count 7 = 1 && count 8 = 1);
  one_controller ();
  check "commit transition exception cannot undo effects" (Int64.equal (scalar observer "SELECT count(*) FROM cp") 1L))
let file_outcome ~rollback ~exists ~cancel ~unlink owner = with_directory (fun dir ->
  let file = Stdlib.Filename.concat dir "out.parquet" in
  let destination = ok (D.Parquet.path file) in
  if exists then (let channel = Stdlib.open_out_bin file in Stdlib.output_string channel "original"; Stdlib.close_out channel);
  reset (); control_failure rollback; unlink_failure unlink; gate 72 true;
  let request = B.create () in
  E.with_worker (fun () -> capture (fun () -> B.run request owner ~f:(fun c ->
    D.Parquet.export c ~query:"SELECT 42::BIGINT" destination)))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 72; if cancel then ok (B.cancel request); gate 72 false;
      let primary_matches = if exists then (function D.Destination_exists -> true | _ -> false)
        else (function D.Cancelled -> cancel | _ -> false) in
      (match join () with
       | Error (D.Rollback_exception (D.Cleanup_exception (primary, Stdlib.Sys_error message), secondary), trace) ->
         check "file error unlink and rollback error retained" (rollback = 1 && primary_matches primary && native_message secondary && not (String.is_empty message) && has_trace trace "Parquet.remove")
       | Error (Exn.Finally (D.Cleanup_exception (primary, Stdlib.Sys_error message), Rollback_failure), trace) ->
         check "file error unlink and rollback exception retained" (rollback = 2 && primary_matches primary && not (String.is_empty message) && has_trace trace "Parquet.remove")
       | Ok (Error primary) -> check "file primary retained" (not unlink && primary_matches primary)
       | Error (D.Cleanup_exception (primary, Stdlib.Sys_error message), trace) ->
         check "file primary and owned unlink diagnostic retained" (unlink && primary_matches primary && not (String.is_empty message) && has_trace trace "Parquet.remove")
       | Error (Stdlib.Sys_error message, trace) ->
         check "successful publication unlink exception retained" (unlink && not cancel && not exists && not (String.is_empty message) && has_trace trace "Parquet.remove")
       | _ -> failwith "file outcome constituent lost");
      unlink_failure false; control_failure 0;
      check "final output never unlinked" (Stdlib.Sys.file_exists file);
      if exists then check "Destination_exists preserves bytes" (String.equal (read_file file) "original")
      else check "published bytes survive rollback" (String.is_prefix (read_file file) ~prefix:"PAR1");
      check "unlink failure leaves only owned temp plus final" (Array.length (Stdlib.Sys.readdir dir) = (if unlink then 2 else 1));
      check "file failure prevents COMMIT" (count 7 = 0 && count 8 = (if rollback = 2 then 0 else 1));
      one_controller ())))
let snapshot_rollback ~exception_ mode _ = with_pair (fun owner observer ->
  reset (); control_failure mode; snapshot_exception exception_; gate 6 true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> capture (fun () -> B.run request owner ~f:(fun c ->
    D.with_prepared c (if exception_ then "INSERT INTO cp VALUES(1) RETURNING x" else "SELECT CAST('invalid' AS BIGINT)") ~f:(fun p ->
      Result.bind (D.execute_prepared p) ~f:D.close_result))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 6; ok (B.cancel request); E.await ~label:"snapshot selected" selected_entered;
      gate 6 false; E.await ~label:"snapshot rollback joins" (fun () -> count 11 > 0);
      check "snapshot rollback cannot run before retirement" (count 8 = 0 && count 12 = 0 && count 13 = 0);
      selected_gate false;
      (match join (), exception_, mode with
       | Ok (Error (D.Rollback_failed (primary, secondary))), false, 1 ->
         check "snapshot both native diagnostics retained" (native_message primary && native_message secondary)
       | Error (D.Cleanup_exception (primary, Rollback_failure), trace), false, 2 ->
         check "snapshot rollback exception retains native primary/source" (native_message primary && has_trace trace "raw_control")
       | Error (D.Rollback_exception (Snapshot_failure, secondary), trace), true, 1 ->
         check "snapshot original exception/source retained" (native_message secondary && has_trace trace "Query.execute_prepared")
       | Error (Exn.Finally (Snapshot_failure, Rollback_failure), trace), true, 2 ->
         check "snapshot two exceptions/source retained" (has_trace trace "Query.execute_prepared")
       | _ -> failwith "snapshot rollback composite lost");
      snapshot_exception false; control_failure 0;
      check "snapshot rollback failure discards" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false);
      one_controller ();
      check "snapshot discard cannot commit" (Int64.equal (scalar observer "SELECT count(*) FROM cp") 0L))))
let unlink_ordinary owner = with_directory (fun dir ->
  let file = Stdlib.Filename.concat dir "out.parquet" in
  let destination = ok (D.Parquet.path file) in
  reset (); gate 73 true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c -> D.Parquet.export c ~query:"SELECT 42::BIGINT" destination))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 73; check "ordinary unlink retains controller" (count 49 = 0 && count 12 = 0);
      ok (B.cancel request); gate 73 false; cancelled (join ());
      check "ordinary unlink never interruptible and no later COMMIT" (count 4 = 0 && count 7 = 0 && count 8 = 1);
      check "ordinary admitted unlink removes only temp" (Array.length (Stdlib.Sys.readdir dir) = 1 && String.is_prefix (read_file file) ~prefix:"PAR1");
      one_controller ())))
let control_cleanup ~commit _ = with_pair (fun owner observer ->
  let point = if commit then 68 else 66 in
  reset (); gate point true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    D.with_transaction c ~f:(fun tx -> D.execute_transaction tx "INSERT INTO cp VALUES(1)")))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request); E.await ~label:"control cleanup selected" selected_entered;
      gate 7 true; gate point false; wait 7;
      check "control internal destruction before ML join" (count 11 = 0);
      selected_gate false; E.await ~label:"control cleanup selected retired" (fun () -> count 17 = 1);
      check "control result destructor excludes delivery" (count 4 = 0 && count 16 = 1);
      gate 7 false; cancelled (join ()); one_controller ();
      check "control cleanup durable observer" (Int64.equal (scalar observer "SELECT count(*) FROM cp") (if commit then 1L else 0L)))))
let tests = [
  "control-begin-result-cleanup", control_cleanup ~commit:false;
  "control-commit-result-cleanup", control_cleanup ~commit:true;
  "control-unlink-ordinary", unlink_ordinary;
  "control-publication-precommit", publication 65;
  "control-file-cancel-unlink-rollback-error", file_outcome ~rollback:1 ~exists:false ~cancel:true ~unlink:true;
  "control-file-exists-unlink-rollback-exception", file_outcome ~rollback:2 ~exists:true ~cancel:true ~unlink:true;
  "control-snapshot-error-rollback-error", snapshot_rollback ~exception_:false 1;
  "control-snapshot-error-rollback-exception", snapshot_rollback ~exception_:false 2;
  "control-snapshot-exception-rollback-error", snapshot_rollback ~exception_:true 1;
  "control-snapshot-exception-rollback-exception", snapshot_rollback ~exception_:true 2;
  "control-temp-before", reservation_or_copy 74;
  "control-temp-admitted", reservation_or_copy 75;
  "control-temp-reserved", reservation_or_copy 76;
  "control-copy-prepare", reservation_or_copy 77;
  "control-copy-bind", reservation_or_copy 78;
  "control-copy-execute", reservation_or_copy 80;
  "control-next-file", next_file;
  "control-commit-return-exception", commit_return_exception;
  "control-file-exists", file_outcome ~rollback:0 ~exists:true ~cancel:false ~unlink:false;
  "control-file-exists-cancel", file_outcome ~rollback:0 ~exists:true ~cancel:true ~unlink:false;
  "control-file-exists-unlink", file_outcome ~rollback:0 ~exists:true ~cancel:true ~unlink:true;
  "control-file-cancel-unlink", file_outcome ~rollback:0 ~exists:false ~cancel:true ~unlink:true;
  "control-file-success-unlink", file_outcome ~rollback:0 ~exists:false ~cancel:false ~unlink:true;
  "control-begin-before", begin_case 64;
  "control-begin-after", begin_case 66;
  "control-commit-entry", commit_case ~snapshot:false 67;
  "control-snapshot-entry", commit_case ~snapshot:true 67;
  "control-commit-before", commit_case ~snapshot:false 65;
  "control-commit-after", commit_case ~snapshot:false 68;
  "control-snapshot-before", commit_case ~snapshot:true 65;
  "control-snapshot-after", commit_case ~snapshot:true 68;
  "control-publication-before", publication 70;
  "control-publication-entry", publication 71;
  "control-publication-after", publication 72;
] @ List.concat_map ["cancel";"native";"exception"] ~f:(fun primary ->
  List.map [1;2] ~f:(fun mode -> "control-rollback-" ^ primary ^ "-" ^ Int.to_string mode, rollback_matrix primary mode))
