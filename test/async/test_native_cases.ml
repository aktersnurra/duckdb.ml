open! Core
open! Async
open Test_support
module A = Duckdb_async
let limits n q = ok (A.Limits.create ~connections:n ~queue_capacity:q)
let config () = ok (Duckdb.Config.create Memory)
let complete r = ok (A.completion r)
let close p = ok (A.shutdown p) >>| ok
let long_query = "SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)"
let cancelled = function Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false
let interrupted = function
  | Error (A.During_cancellation (A.Expected (A.Core (Duckdb.Native_error text)))) ->
    String.is_substring (String.lowercase text) ~substring:"interrupt"
  | _ -> false
let heartbeat deferred seam =
  wait_scheduler (fun () -> native_entered seam > 0) >>= fun () ->
  if Array.mem (Sys.get_argv ()) "--fail-heartbeat" ~equal:String.equal then
    failwith "injected heartbeat failure after true native entry";
  Scheduler.yield () >>| fun () ->
  require "ordinary cleanup no locked engine calls" (locked_calls () = 0);
  require "completion after actual native heartbeat" (not (Deferred.is_determined deferred))
let with_pool ?(n=1) ?(q=1) f =
  reset (-1);
  A.create (limits n q) (config ()) >>= fun result ->
  let p = ok result in
  Monitor.protect ~finally:(fun () -> native_release_all (); release_workers (); close p) (fun () -> f p)
let running_reset () = with_pool (fun p ->
  native_hold Execute;
  let r = ok (A.execute p long_query) in
  heartbeat (complete r) Execute >>= fun () ->
  ignore (ok (A.cancel r)); ignore (ok (A.cancel r));
  wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
  native_release Execute;
  complete r >>| fun result ->
  require "real interrupted diagnostic after reset" (interrupted result);
  require "native return and controller join" (native_errors () = 1 && joins () = 1);
  require "retire then replace" (disconnects () = 1 && connects () = 2))
let all_slots_cancel () = with_pool ~n:2 (fun p ->
  native_hold Execute;
  let requests = [ok (A.execute p long_query); ok (A.execute p long_query)] in
  let pending = ok (A.execute p "select 3") in
  wait_scheduler (fun () -> native_entered Execute = 2) >>= fun () ->
  List.iter requests ~f:(fun r -> ignore (ok (A.cancel r)));
  ignore (ok (A.cancel pending));
  wait_scheduler (fun () -> distinct_interrupted () = 2) >>= fun () ->
  require "occupied slots queue not offloaded" (executions () = 2);
  native_release Execute;
  Deferred.all (List.map requests ~f:complete) >>| fun results ->
  require "both occupied native queries interrupted" (List.for_all results ~f:interrupted && native_errors () = 2 && joins () = 2))
let cancel_at_return () = with_pool (fun p ->
  native_hold Execute_return;
  let r = ok (A.execute p "select 42") in
  heartbeat (complete r) Execute_return >>= fun () ->
  require "first terminal cancellation requested" (match A.cancel r with Ok A.Requested -> true | _ -> false);
  require "repeated terminal cancellation acknowledged" (match A.cancel r with Ok A.Requested -> true | _ -> false);
  native_release Execute_return;
  complete r >>| fun result ->
  require "foreign return cancellation wins" (cancelled result);
  require "terminal cancel cannot change result" (match A.cancel r with Ok A.Already_finished -> true | _ -> false))
let stale ~replace () = with_pool (fun p ->
  let a = if replace then ok (A.transaction p ~f:(fun _ -> Ok ())) else ok (A.execute p "select 1") in
  complete a >>= fun result -> ok result;
  let expected = if replace then 2 else 1 in
  require "correct A owner disposition" (connects () = expected);
  native_hold Execute;
  let b = ok (A.execute p "select 2") in
  heartbeat (complete b) Execute >>= fun () ->
  List.iter [();()] ~f:(fun () -> require "late A already finished" (match A.cancel a with Ok A.Already_finished -> true | _ -> false));
  require "late A causes zero B interrupt" (interrupts () = 0);
  native_release Execute;
  complete b >>| fun result ->
  require "late A causes zero B interrupt" (Result.is_ok result && interrupts () = 0);
  require "B successful same candidate" (connects () = expected))
let selected_retirement () = with_pool (fun p ->
  native_hold Execute; native_hold Execute_return; hold_selected true;
  let r = ok (A.execute p "select 1") in
  heartbeat (complete r) Execute >>= fun () ->
  ignore (ok (A.cancel r));
  wait_scheduler selected_seen >>= fun () ->
  native_release Execute;
  heartbeat (complete r) Execute_return >>= fun () ->
  native_release Execute_return;
  require "selected ticket prevents close and join" (disconnects () = 0 && joins () = 0);
  require "selected ticket prevents completion" (not (Deferred.is_determined (complete r)));
  hold_selected false;
  complete r >>| fun result ->
  require "selected request cancelled" (cancelled result);
  require "selected retirement joined before replacement" (joins () = 1 && disconnects () = 1))
let heartbeat_lifecycle seam () =
  reset (-1); native_hold seam;
  let created = A.create (limits 1 0) (config ()) in
  Monitor.protect ~finally:(fun () -> native_release_all (); created >>= fun result -> close (ok result)) (fun () ->
    heartbeat created seam >>= fun () -> native_release seam; created >>| fun result -> ignore (ok result))
let heartbeat_sql seam () = with_pool (fun p ->
  native_hold seam;
  let r = ok (A.execute p "select 42") in
  heartbeat (complete r) seam >>= fun () -> native_release seam;
  complete r >>| ok)
let heartbeat_close seam () = with_pool (fun p ->
  native_hold seam;
  let d = ok (A.shutdown p) in
  heartbeat d seam >>= fun () -> native_release seam; d >>| ok)
let heartbeat_cancel seam () = with_pool (fun p ->
  native_hold Execute;
  let r = ok (A.transaction p ~f:(fun tx -> Duckdb.execute_transaction tx long_query)) in
  heartbeat (complete r) Execute >>= fun () ->
  native_hold seam;
  ignore (ok (A.cancel r));
  wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
  native_release Execute;
  heartbeat (complete r) seam >>= fun () ->
  if phys_equal seam Rollback || phys_equal seam Disconnect then require "terminal join before native cleanup" (joins () = 1);
  native_release seam;
  complete r >>| fun result -> require "cleanup retains cancellation" (cancelled result))
let ordinary_error () = with_pool (fun p ->
  complete (ok (A.execute p "select missing_column")) >>= fun result ->
  require "core native error preserved" (match result with Error (A.Expected (A.Core (Duckdb.Native_error _))) -> true | _ -> false);
  require "error retires uncertain owner" (connects () = 2 && disconnects () = 1);
  complete (ok (A.execute p "select 1")) >>| ok)
let replacement_failed () =
  reset 1;
  A.create (limits 1 1) (config ()) >>= fun result ->
  let p = ok result in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let r = ok (A.transaction p ~f:(fun _ -> Stdlib.Atomic.set entered true; wait_worker release; Ok ())) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; ok (A.shutdown p) >>| fun _ -> ()) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let queued = ok (A.execute p "select 2") in
    Stdlib.Atomic.set release true;
    complete r >>= fun outcome -> require "replacement failure retained" (Result.is_error outcome);
    complete queued >>= fun outcome ->
    require "replacement failure stops queue" (match outcome with Error (A.Expected A.Pool_shutdown) -> true | _ -> false);
    ok (A.shutdown p) >>| fun outcome ->
    require "shutdown retains lifecycle failure" (Result.is_error outcome);
    require "replacement attempted exactly once" (connects () = 2))
let replacement_stop () = with_pool (fun p ->
  native_hold Connect;
  let r = ok (A.transaction p ~f:(fun _ -> Ok ())) in
  heartbeat (complete r) Connect >>= fun () ->
  let stopped = ok (A.shutdown p) in
  require "stop during replacement remains pending" (not (Deferred.is_determined stopped));
  native_release Connect;
  complete r >>= fun result ->
  require "replacement candidate closed before stopped request completion" (connects () = 2 && disconnects () = 2 && cancelled result);
  stopped >>| ok)
let count_rows tx =
  Duckdb.with_prepared_transaction tx "select count(*)::BIGINT from t" ~f:(fun prepared ->
    Result.bind (Duckdb.execute_prepared prepared) ~f:(fun result ->
      Duckdb.fold_rows result Duckdb.Row.(Column (Required Int64, Empty)) ~init:0L
        ~f:(fun (count, ()) _ -> Ok (Duckdb.Stop count))))
let transaction_exclusion () = with_pool (fun p ->
  complete (ok (A.execute p "create table t(i integer)")) >>= fun result -> ok result;
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let escaped = ref None in
  let a = ok (A.transaction p ~f:(fun tx ->
    escaped := Some tx;
    ok (Duckdb.execute_transaction tx "insert into t values (1)");
    Stdlib.Atomic.set entered true; wait_worker release;
    Duckdb.execute_transaction tx "insert into t values (2)")) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; complete a >>| fun _ -> ()) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let b = ok (A.transaction p ~f:count_rows) in
    require "competing transaction cannot interleave" (not (Deferred.is_determined (complete b)));
    Stdlib.Atomic.set release true;
    complete a >>= fun result -> ok result;
    complete b >>| fun result ->
    require "whole transaction visible to next borrower" (Int64.equal (ok result) 2L);
    require "escaped transaction revoked" (match Duckdb.execute_transaction (Option.value_exn !escaped) "select 1" with Error Duckdb.Closed -> true | _ -> false)))
let commit_cancel ~after () = with_pool (fun p ->
  complete (ok (A.execute p "create table t(i integer)")) >>= fun result -> ok result;
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  if after then native_hold Commit_return;
  let r = ok (A.transaction p ~f:(fun tx ->
    ok (Duckdb.execute_transaction tx "insert into t values (1)");
    if not after then (
      Stdlib.Atomic.set entered true; wait_worker release;
      ignore (Duckdb.execute_transaction tx "insert into t values (2)"));
    Ok ())) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; native_release_all (); complete r >>| fun _ -> ()) (fun () ->
    (if after then heartbeat (complete r) Commit_return else wait_scheduler (fun () -> Stdlib.Atomic.get entered)) >>= fun () ->
    ignore (ok (A.cancel r));
    Stdlib.Atomic.set release true; native_release Commit_return;
    complete r >>= fun result -> require "commit race cancellation classified" (cancelled result);
    require "precommit latch blocks decision" (commits () = if after then 1 else 0);
    complete (ok (A.transaction p ~f:count_rows)) >>| fun result ->
    require "independent durable row observation" (Int64.equal (ok result) (if after then 1L else 0L))))
let heartbeat_typed seam ~cancel () = with_pool (fun p ->
  complete (ok (A.execute p "create table t(i bigint)")) >>= fun result -> ok result;
  let r = ok (A.transaction p ~f:(fun tx ->
    match seam with
    | Fetch | Chunk ->
      Duckdb.with_prepared_transaction tx "select 42::BIGINT" ~f:(fun prepared ->
        let result = ok (Duckdb.execute_prepared prepared) in
        if phys_equal seam Fetch then native_hold Fetch;
        Duckdb.fold_chunks result ~init:() ~f:(fun _chunk () ->
          if phys_equal seam Chunk then native_hold Chunk;
          Ok (Duckdb.Stop ())))
    | Appender_clear | Appender_destroy ->
      Duckdb.with_appender_transaction tx "t" ~f:(fun appender ->
        ok (Duckdb.append_rows appender [[Duckdb.Cell (Required Int64, 42L)]]);
        native_hold seam;
        if cancel then Error (Duckdb.Native_error "intentional rollback") else Ok ())
    | _ -> assert false)) in
  heartbeat (complete r) seam >>= fun () ->
  if cancel then ignore (ok (A.cancel r));
  native_release seam;
  complete r >>| fun result ->
  if cancel then require "typed cleanup cancellation preserved" (cancelled result) else ok result)
let maintenance_progress () = with_pool ~n:2 (fun p ->
  native_hold Execute;
  let running = ok (A.execute p long_query) in
  heartbeat (complete running) Execute >>= fun () ->
  native_hold Connect;
  let returning = ok (A.transaction p ~f:(fun _ -> Ok ())) in
  heartbeat (complete returning) Connect >>= fun () ->
  require "maintenance progresses while other database slot occupied" (not (Deferred.is_determined (complete running)) && disconnects () = 1);
  ignore (ok (A.cancel running));
  wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
  native_release_all ();
  complete returning >>= fun result -> ok result;
  complete running >>| fun result -> require "independent controller plus maintenance progress" (interrupted result))
let shutdown_native seam () = with_pool (fun p ->
  native_hold Execute;
  let r = ok (A.execute p long_query) in
  heartbeat (complete r) Execute >>= fun () ->
  native_hold seam;
  let queued = ok (A.execute p "select 2") in
  let d = ok (A.shutdown p) in
  wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
  native_release Execute;
  heartbeat d seam >>= fun () ->
  complete queued >>= fun result ->
  require "shutdown queue settled without work" (match result with Error (A.Expected A.Pool_shutdown) -> true | _ -> false);
  require "shutdown retained active settlement" (not (Deferred.is_determined (complete r)));
  native_release_all ();
  d >>= fun result -> ok result;
  complete r >>| fun result -> require "shutdown drains real native error" (interrupted result))
let shutdown_abandoned () = with_pool (fun p ->
  native_hold Disconnect;
  let observer = Monitor.create () in
  let failed = Ivar.create () in
  Monitor.detach_and_iter_errors observer ~f:(fun _ -> Ivar.fill_if_empty failed ());
  ignore (Scheduler.within_v ~monitor:observer (fun () -> ignore (A.shutdown p); raise Exit));
  Ivar.read failed >>= fun () ->
  let d = ok (A.shutdown p) in
  heartbeat d Disconnect >>= fun () ->
  native_release Disconnect;
  d >>| fun result -> ok result;
  require "abandoned failed shutdown caller still closes once" (disconnects () = 1))
let result_error () = with_pool (fun p ->
  let r = ok (A.transaction p ~f:(fun tx ->
    Duckdb.with_prepared_transaction tx "select 'text'::VARCHAR" ~f:(fun prepared ->
      Result.bind (Duckdb.execute_prepared prepared) ~f:(fun result ->
        Duckdb.fold_rows result Duckdb.Row.(Column (Required Int64, Empty)) ~init:()
          ~f:(fun _ () -> Ok (Duckdb.Stop ())))))) in
  complete r >>| fun result ->
  require "typed result error retained" (match result with Error (A.Expected (A.Core (Duckdb.Data_error _))) -> true | _ -> false);
  require "typed result failed lease retired" (connects () = 2))
let heartbeat_copy () =
  let path = Stdlib.Filename.temp_file "stage4c-copy-" ".parquet" in
  Stdlib.Sys.remove path;
  Monitor.protect ~finally:(fun () -> if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path; return ()) (fun () ->
    with_pool (fun p ->
      native_hold Execute;
      let r = ok (A.execute p ("COPY (SELECT 42::BIGINT AS value) TO '" ^ path ^ "' (FORMAT PARQUET)")) in
      heartbeat (complete r) Execute >>= fun () -> native_release Execute;
      complete r >>| fun result -> ok result;
      require "raw COPY actual file output after native heartbeat" (Stdlib.Sys.file_exists path)))
let swallowed_statement_error () = with_pool (fun p ->
  let swallowed = Stdlib.Atomic.make false in
  let r = ok (A.transaction p ~f:(fun tx ->
    Stdlib.Atomic.set swallowed (Result.is_error (Duckdb.execute_transaction tx "select __stage4c_absent_column__"));
    require "manual transaction SQL rejected on token" (match Duckdb.execute_transaction tx "ROLLBACK" with Error Duckdb.Unsupported_statement -> true | _ -> false);
    Ok 42)) in
  complete r >>| fun result ->
  require "callback actually swallowed a statement error" (Stdlib.Atomic.get swallowed);
  (match result with Ok value -> Stdlib.Printf.printf "swallowed statement final=Ok(%d)\n%!" value
   | Error _ -> Stdlib.print_endline "swallowed statement final=Error (retained in completion)");
  require "callback retirement independent of swallowed statement outcome" (connects () = 2 && disconnects () = 1))
let cases =
  [ "swallowed_statement_error", swallowed_statement_error
  ; "shutdown_settling", shutdown_native Result; "shutdown_closing", shutdown_native Disconnect
  ; "shutdown_abandoned", shutdown_abandoned; "result_error", result_error; "heartbeat_copy", heartbeat_copy
  ; "transaction_exclusion", transaction_exclusion
  ; "pre_commit_cancel", commit_cancel ~after:false; "post_commit_cancel", commit_cancel ~after:true
  ; "heartbeat_fetch", heartbeat_typed Fetch ~cancel:false; "heartbeat_chunk", heartbeat_typed Chunk ~cancel:false
  ; "heartbeat_appender_clear", heartbeat_typed Appender_clear ~cancel:false
  ; "heartbeat_appender_destroy", heartbeat_typed Appender_destroy ~cancel:false
  ; "heartbeat_cancel_chunk", heartbeat_typed Chunk ~cancel:true
  ; "heartbeat_cancel_appender_clear", heartbeat_typed Appender_clear ~cancel:true
  ; "heartbeat_cancel_appender_destroy", heartbeat_typed Appender_destroy ~cancel:true
  ; "maintenance_progress", maintenance_progress
  ; "running_reset", running_reset; "all_slots_cancel", all_slots_cancel
  ; "cancel_at_return", cancel_at_return; "stale_reuse", stale ~replace:false
  ; "stale_replacement", stale ~replace:true; "selected_retirement", selected_retirement
  ; "ordinary_error", ordinary_error; "replacement_failed", replacement_failed; "replacement_stop", replacement_stop
  ; "heartbeat_open", heartbeat_lifecycle Open; "heartbeat_connect", heartbeat_lifecycle Connect
  ; "heartbeat_execute", heartbeat_sql Execute; "heartbeat_result", heartbeat_sql Result
  ; "heartbeat_prepared", heartbeat_sql Prepared; "heartbeat_extracted", heartbeat_sql Extracted
  ; "heartbeat_disconnect", heartbeat_close Disconnect; "heartbeat_database_close", heartbeat_close Database_close
  ; "heartbeat_cancel_rollback", heartbeat_cancel Rollback; "heartbeat_cancel_result", heartbeat_cancel Result
  ; "heartbeat_cancel_prepared", heartbeat_cancel Prepared; "heartbeat_cancel_disconnect", heartbeat_cancel Disconnect ]
