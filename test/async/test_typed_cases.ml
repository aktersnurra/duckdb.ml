open! Core
open! Async
open Test_support
module A = Duckdb_async
let config () = ok (Duckdb.Config.create Memory)
let limits () = ok (A.Limits.create ~connections:1 ~queue_capacity:2)
let complete request = ok (A.completion request)
let close pool = ok (A.shutdown pool) >>| ok
let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))
let equal_rows = List.equal (fun (left, ()) (right, ()) -> Int64.equal left right)
let typed_requests () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = match created with Ok pool -> pool | Error _ -> failwith "typed pool creation failed" in
  Monitor.protect ~finally:(fun () -> close pool) (fun () ->
    complete (ok (A.execute pool "CREATE TABLE typed(i BIGINT)")) >>= fun result -> ok result;
    let batches =
      [ [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L) ]
        ; [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 2L) ]
        ]
      ; [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 3L) ] ]
      ] in
    complete (ok (A.ingest pool ~schema:None ~table:"typed" ~batches ~flush:true)) >>= fun result -> ok result;
    complete (ok (A.query pool "SELECT i FROM typed ORDER BY i" rows)) >>= fun result ->
    let result = ok result in
    require "owned typed query" (equal_rows result [1L, (); 2L, (); 3L, ()]);
    complete (ok (A.fold_rows pool "SELECT i FROM typed ORDER BY i" rows ~init:0L
      ~f:(fun (value, ()) total -> Ok (if Int64.equal value 2L then Duckdb.Stop (Int64.(total + value)) else Duckdb.Continue Int64.(total + value)))))
    >>= fun result ->
    let result = ok result in
    require "owned typed fold Stop" (Int64.equal result 3L);
    let path = Stdlib.Filename.temp_file "duckdb_async_stage4d" ".parquet" in
    Stdlib.Sys.remove path;
    Monitor.protect ~finally:(fun () -> if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path; return ()) (fun () ->
      complete (ok (A.parquet_export pool ~query:"SELECT i FROM typed ORDER BY i" ~destination:path)) >>= fun result -> ok result;
      complete (ok (A.parquet_fold_rows pool [path] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values)))))
      >>| fun result ->
      require "worker-local Parquet read/export" (equal_rows (List.rev (ok result)) [1L, (); 2L, (); 3L, ()]))
    >>= fun () ->
    close pool >>= fun () ->
    require "typed post-shutdown admission rejected"
      (match A.query pool "SELECT 1::BIGINT" rows with Error A.Pool_shutdown -> true | _ -> false);
    return ())
let wide_rows =
  Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int8,
    Column (Duckdb.Scalar.Nullable Duckdb.Scalar.String,
      Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))))
let wide_and_multichunk () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> close pool) (fun () ->
    complete (ok (A.query pool "SELECT 127::TINYINT, NULL::VARCHAR, 9223372036854775807::BIGINT" wide_rows)) >>= fun result ->
    let result = ok result in
    require "NULL and width owned roundtrip" (match result with [127, (None, (value, ()))] -> Int64.equal value Int64.max_value | _ -> false);
    let admissions = dispatch_count () in
    complete (ok (A.query pool "SELECT i::BIGINT FROM range(3000) t(i)" rows)) >>| fun result ->
    require "multi-chunk ordered owned query" (List.equal (fun (value, ()) (expected, ()) -> Int64.equal value expected) (ok result) (List.init 3000 ~f:(fun i -> Int64.of_int i, ())));
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "multi-chunk query has one request offload plus close/replacement" (dispatch_count () = admissions + 3))
let fold_callbacks () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> close pool) (fun () ->
    let stopped = ok (A.fold_rows pool "SELECT i::BIGINT FROM range(4) t(i)" rows ~init:0L
      ~f:(fun (value, ()) total ->
        require "fold callback reentrancy rejected" (match A.execute pool "select 1" with Error A.Reentrant_call -> true | _ -> false);
        Ok (if Int64.equal value 2L then Duckdb.Stop Int64.(total + value) else Duckdb.Continue Int64.(total + value)))) in
    complete stopped >>= fun result ->
    require "fold Stop owned accumulator" (Int64.equal (ok result) 3L);
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "worker callback TLS clear after Stop" (callback_cleanup_observations () = 3 && callback_cleanup_is_clear ());
    let admissions = dispatch_count () in
    complete (ok (A.fold_rows pool "SELECT i::BIGINT FROM range(4) t(i)" rows ~init:[]
      ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>= fun result ->
    require "fold owned accumulation" (equal_rows (List.rev (ok result)) [0L, (); 1L, (); 2L, (); 3L, ()]);
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "fold has one whole-request offload plus bounded maintenance" (dispatch_count () = admissions + 3);
    let failed = ok (A.fold_rows pool "SELECT 1::BIGINT" rows ~init:()
      ~f:(fun _ () -> Error (Duckdb.Native_error "fold callback error"))) in
    complete failed >>= fun result ->
    require "fold callback error retained" (match result with Error (A.Expected (A.Core (Duckdb.Native_error _))) -> true | _ -> false);
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "worker callback TLS clear after error" (callback_cleanup_observations () = 8 && callback_cleanup_is_clear ());
    let observer = Monitor.create () in
    let notified = Ivar.create () in
    let settled_before_monitor = Stdlib.Atomic.make false in
    let raised_ref = ref None in
    Monitor.detach_and_iter_errors observer ~f:(fun error ->
      (match !raised_ref with
       | Some request -> Stdlib.Atomic.set settled_before_monitor (Deferred.is_determined (complete request))
       | None -> ());
      Ivar.fill_if_empty notified (Monitor.extract_exn error));
    let raised = Option.value_exn (Scheduler.within_v ~monitor:observer (fun () ->
      ok (A.fold_rows pool "SELECT 1::BIGINT" rows ~init:()
        ~f:(fun _ () -> raise Exit)))) in
    raised_ref := Some raised;
    complete raised >>= fun result ->
    require "fold callback exception retained" (match result with
      | Error (A.Raised { exception_ = Exit; backtrace }) ->
        String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace) ~substring:"fold_callbacks"
      | _ -> false);
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "worker callback TLS clear after exception" (callback_cleanup_observations () = 9 && callback_cleanup_is_clear ());
    Ivar.read notified >>| fun exception_ ->
    require "fold exception monitor transport" (phys_equal exception_ Exit);
    require "fold settles before monitor delivery" (Stdlib.Atomic.get settled_before_monitor))
let ingest_rollback_and_auto_flush () =
  reset (-1);
  let two_connections = ok (A.Limits.create ~connections:2 ~queue_capacity:2) in
  A.create two_connections (config ()) >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
    complete (ok (A.execute pool "CREATE TABLE batches(i BIGINT NOT NULL)")) >>= fun result -> ok result;
    let good = [ [ [Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L)] ] ] in
    let bad = good @ [[[]]] in
    complete (ok (A.ingest pool ~schema:None ~table:"batches" ~batches:bad ~flush:false)) >>= fun result ->
    require "later batch failure retained" (Result.is_error result);
    complete (ok (A.query pool "SELECT i FROM batches" rows)) >>= fun result ->
    require "failed later batch rolled back earlier append" (List.is_empty (ok result));
    (* This gate is the adapter's explicit D.flush_appender call, not close-time flush. *)
    native_hold Appender_flush;
    let commits_before_explicit = commits () in
    let explicit = ok (A.ingest pool ~schema:None ~table:"batches" ~batches:good ~flush:true) in
    wait_scheduler (fun () -> native_entered Appender_flush > 0) >>= fun () ->
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "explicit flush is adapter initiated before close" (Test_support.explicit_flush_observations () = 1);
    native_hold Appender_destroy;
    ignore (ok (A.cancel explicit)); native_release Appender_flush;
    wait_scheduler (fun () -> native_entered Appender_destroy > 0) >>= fun () ->
    require "owned appender destruction holds settlement" (not (Deferred.is_determined (complete explicit)));
    native_release Appender_destroy;
    complete explicit >>= fun result ->
    require "explicit flush cancellation settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
    require "explicit flush cancellation suppresses COMMIT" (commits () = commits_before_explicit);
    complete (ok (A.query pool "SELECT i FROM batches" rows)) >>= fun result ->
    require "explicit flush cancellation leaves no committed rows" (List.is_empty (ok result));
    (* Pinned appender.cpp:393-418,760-781 follows FlushChunk -> ShouldFlush ->
       FlushInternal. The duplicate-primary-key control independently observes
       its first automatic-flush error at end-row 204,800 before close-time
       cleanup. Select that observed boundary, not an inferred default threshold
       or the 2,048-row vector boundary. *)
    let automatic_flush_end_row = 100 * 2048 in
    let automatic_flush_control_rows = 220000 in
    complete (ok (A.execute pool "CREATE TABLE automatic_flush(i BIGINT PRIMARY KEY)")) >>= fun result -> ok result;
    let rows_of value =
      [List.init automatic_flush_control_rows ~f:(fun _ ->
        [Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, value)])] in
    let control_rows_before = appender_end_rows () in
    let control_errors_before = appender_end_row_errors () in
    let control_commits_before = commits () in
    complete (ok (A.ingest pool ~schema:None ~table:"automatic_flush" ~batches:(rows_of 0L) ~flush:false)) >>= fun result ->
    require "automatic flush constraint is reported by end-row" (Result.is_error result);
    let control_rows = appender_end_rows () - control_rows_before in
    let control_errors = appender_end_row_errors () - control_errors_before in
    printf "AUTO_CONTROL vector=2048 observed_end_row=%d end_row_errors=%d commits=%d\n%!"
      control_rows control_errors (commits () - control_commits_before);
    require "automatic flush first collection boundary" (control_rows = automatic_flush_end_row);
    require "automatic flush constraint returned from end-row" (control_errors = 1);
    require "automatic flush control suppresses COMMIT" (commits () = control_commits_before);
    complete (ok (A.query pool "SELECT i FROM automatic_flush" rows)) >>= fun result ->
    require "automatic flush control has no committed rows" (List.is_empty (ok result));
    let cancellation_rows_before = appender_end_rows () in
    let disconnects_before_automatic = disconnects () in
    let commits_before_automatic = commits () in
    select_appender_end_row (cancellation_rows_before + automatic_flush_end_row);
    native_hold Appender_end_row;
    let automatic_cancel = ok (A.ingest pool ~schema:None ~table:"automatic_flush"
      ~batches:[List.init automatic_flush_end_row ~f:(fun i ->
        [Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Int64.of_int i)])] ~flush:false) in
    wait_scheduler (fun () -> native_entered Appender_end_row > 0) >>= fun () ->
    ignore (ok (A.cancel automatic_cancel)); native_release Appender_end_row;
    complete automatic_cancel >>= fun result ->
    select_appender_end_row (-1);
    require "automatic flush cancellation settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
    require "automatic flush cancellation selected actual flush end-row" (appender_end_rows () = cancellation_rows_before + automatic_flush_end_row);
    require "automatic flush cancellation suppresses COMMIT" (commits () = commits_before_automatic);
    require "automatic flush cancellation retires owner" (disconnects () > disconnects_before_automatic);
    printf "AUTO_CANCEL selected_end_row=%d end_rows=%d commits=%d disconnect_delta=%d\n%!"
      automatic_flush_end_row (appender_end_rows () - cancellation_rows_before)
      (commits () - commits_before_automatic) (disconnects () - disconnects_before_automatic);
    complete (ok (A.query pool "SELECT i FROM automatic_flush" rows)) >>= fun result ->
    require "automatic flush cancellation leaves no committed rows" (List.is_empty (ok result));
    (* Independent pool slot changes metadata while the first transaction is paused
       before its end-row native call; the ingestion must roll back rather than commit. *)
    native_hold Appender_end_row;
    let commits_before_concurrent = commits () in
    let concurrent = ok (A.ingest pool ~schema:None ~table:"batches" ~batches:good ~flush:false) in
    wait_scheduler (fun () -> native_entered Appender_end_row > 1) >>= fun () ->
    let alter = ok (A.execute pool "ALTER TABLE batches ADD COLUMN changed BIGINT") in
    complete alter >>= fun result -> ok result;
    (* Completion on the second leased connection establishes the metadata-before-
       append order while the first is held at its real end-row boundary. *)
    native_release Appender_end_row;
    complete concurrent >>= fun result ->
    require "concurrent metadata invalidates appender transaction" (Result.is_error result);
    require "concurrent metadata ingestion suppresses COMMIT" (commits () = commits_before_concurrent);
    let commits_before_success = commits () in
    let many = List.init 2048 ~f:(fun i ->
      [[ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Int64.of_int i)
       ; Duckdb.Cell (Duckdb.Scalar.Nullable Duckdb.Scalar.Int64, None)
       ]]) in
    let admissions = dispatch_count () in
    complete (ok (A.ingest pool ~schema:None ~table:"batches" ~batches:many ~flush:false)) >>= fun result -> ok result;
    require "automatic end-row reached sufficient rows" (appender_end_rows () >= 2050);
    require "automatic-flush ingestion commits" (commits () = commits_before_success + 1);
    if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
      require "ingest has one whole-request offload plus bounded maintenance" (dispatch_count () = admissions + 3);
    complete (ok (A.query pool "SELECT count(*)::BIGINT FROM batches" rows)) >>| fun result ->
    require "automatic flush committed every row" (equal_rows (ok result) [2048L, ()]))
let heartbeat_and_cancel_query () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = ok created in
  native_hold Execute;
  let request = ok (A.query pool "SELECT sum(sin(i::DOUBLE))::BIGINT FROM range(10000000000) t(i)" rows) in
  Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
    wait_scheduler (fun () -> native_entered Execute > 0) >>= fun () ->
    Scheduler.yield () >>= fun () ->
    require "query scheduler heartbeat after native entry" (not (Deferred.is_determined (complete request)));
    ignore (ok (A.cancel request));
    wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
    native_release Execute;
    complete request >>| fun result ->
    require "query cancellation settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
    require "query cancellation retired slot" (disconnects () = 1 && connects () = 2))
let heartbeat_and_cancel_fold () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = ok created in
  native_hold Execute;
  let request = ok (A.fold_rows pool "SELECT sum(sin(i::DOUBLE))::BIGINT FROM range(10000000000) t(i)" rows ~init:0L
    ~f:(fun _ total -> Ok (Duckdb.Continue total))) in
  Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
    wait_scheduler (fun () -> native_entered Execute > 0) >>= fun () ->
    Scheduler.yield () >>= fun () ->
    require "fold scheduler heartbeat after actual native entry" (not (Deferred.is_determined (complete request)));
    ignore (ok (A.cancel request));
    wait_scheduler (fun () -> interrupts () > 0) >>= fun () ->
    native_release Execute;
    complete request >>| fun result ->
    require "fold cancellation settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
    require "fold cancellation retired slot" (disconnects () = 1 && connects () = 2))
let heartbeat_and_cancel_ingest () =
  reset (-1);
  A.create (limits ()) (config ()) >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
    complete (ok (A.execute pool "CREATE TABLE cancel_ingest(i BIGINT)")) >>= fun result -> ok result;
    native_hold Appender_clear;
    let batches = [[ [Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L)] ]] in
    let request = ok (A.ingest pool ~schema:None ~table:"cancel_ingest" ~batches ~flush:false) in
    wait_scheduler (fun () -> native_entered Appender_clear > 0) >>= fun () ->
    Scheduler.yield () >>= fun () ->
    require "ingest scheduler heartbeat after appender native entry" (not (Deferred.is_determined (complete request)));
    ignore (ok (A.cancel request));
    native_release Appender_clear;
    complete request >>| fun result ->
    require "ingest cancellation settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
    require "ingest cancellation retired slot" (disconnects () = 1 && connects () = 2))
let parquet_path suffix =
  let path = Stdlib.Filename.temp_file "duckdb_async_stage4d_group2" suffix in
  Stdlib.Sys.remove path;
  path
let remove_if_exists path = if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path

let parquet_callback_failure_frame _ () = raise Exit

(* This no-op is a test-only mutation seam.  The mutation control replaces it
   only for this isolated, post-publication cancellation fixture. *)
let published_final_side_effect_mutation _destination = ()

let parquet_directory () =
  let directory = Stdlib.Filename.temp_file "duckdb_async_stage4d_export" "" in
  Stdlib.Sys.remove directory;
  Core_unix.mkdir ~perm:0o700 directory;
  directory
let owned_temporaries directory =
  Stdlib.Sys.readdir directory |> Array.to_list
  |> List.filter ~f:(String.is_prefix ~prefix:".duckdb-parquet-")
  |> List.map ~f:(Stdlib.Filename.concat directory)
let remove_owned_temporaries directory = List.iter (owned_temporaries directory) ~f:remove_if_exists
let parquet_read_failures_and_callbacks () =
  reset (-1);
  let first = parquet_path ".parquet" and second = parquet_path ".parquet" in
  let corrupt = parquet_path ".parquet" in
  Monitor.protect ~finally:(fun () -> List.iter [first; second; corrupt] ~f:remove_if_exists; return ()) (fun () ->
    A.create (limits ()) (config ()) >>= fun created ->
    let pool = ok created in
    Monitor.protect ~finally:(fun () -> close pool) (fun () ->
      complete (ok (A.parquet_export pool ~query:"SELECT 1::BIGINT AS i" ~destination:first)) >>= fun result -> ok result;
      complete (ok (A.parquet_export pool ~query:"SELECT 'wrong'::VARCHAR AS i" ~destination:second)) >>= fun result -> ok result;
      complete (ok (A.parquet_fold_rows pool [first; second] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>= fun result ->
      require "later Parquet schema mismatch retained" (match result with Error (A.Expected (A.Core (Duckdb.Data_error _))) -> true | _ -> false);
      In_thread.run (fun () ->
        let channel = Stdlib.open_out_bin corrupt in
        Stdlib.output_string channel "not parquet";
        Stdlib.close_out channel) >>= fun () ->
      complete (ok (A.parquet_fold_rows pool [corrupt] rows ~init:() ~f:(fun _ () -> Ok (Duckdb.Continue ())))) >>= fun result ->
      require "corrupt Parquet retained" (Result.is_error result);
      complete (ok (A.parquet_fold_rows pool [first] rows ~init:0L
        ~f:(fun (value, ()) _ ->
          require "Parquet callback reentrancy rejected" (match A.execute pool "select 1" with Error A.Reentrant_call -> true | _ -> false);
          Ok (Duckdb.Stop value)))) >>= fun result ->
      require "Parquet fold Stop" (Int64.equal (ok result) 1L);
      let callback_error = ok (A.parquet_fold_rows pool [first] rows ~init:()
        ~f:(fun _ () -> Error (Duckdb.Native_error "Parquet callback error"))) in
      complete callback_error >>= fun result ->
      require "Parquet callback error retained" (match result with Error (A.Expected (A.Core (Duckdb.Native_error _))) -> true | _ -> false);
      let observer = Monitor.create () and notified = Ivar.create () in
      Monitor.detach_and_iter_errors observer ~f:(fun error -> Ivar.fill_if_empty notified (Monitor.extract_exn error));
      let callback_exception = Option.value_exn (Scheduler.within_v ~monitor:observer (fun () ->
        ok (A.parquet_fold_rows pool [first] rows ~init:() ~f:parquet_callback_failure_frame))) in
      complete callback_exception >>= fun result ->
      require "Parquet callback exception retained with raw callback backtrace" (match result with
        | Error (A.Raised { exception_ = Exit; backtrace }) ->
          String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace)
            ~substring:"parquet_callback_failure_frame"
        | _ -> false);
      Ivar.read notified >>| fun exception_ -> require "Parquet exception monitor transport" (phys_equal exception_ Exit)))
let parquet_cancel_between_files () =
  reset (-1);
  let first = parquet_path ".parquet" and second = parquet_path ".parquet" in
  Monitor.protect ~finally:(fun () -> List.iter [first; second] ~f:remove_if_exists; return ()) (fun () ->
    A.create (limits ()) (config ()) >>= fun created ->
    let pool = ok created in
    Monitor.protect ~finally:(fun () -> close pool) (fun () ->
      complete (ok (A.parquet_export pool ~query:"SELECT 1::BIGINT AS i" ~destination:first)) >>= fun result -> ok result;
      complete (ok (A.parquet_export pool ~query:"SELECT 2::BIGINT AS i" ~destination:second)) >>= fun result -> ok result;
      let callbacks = Stdlib.Atomic.make 0 in
      Monitor.protect ~finally:(fun () -> native_release Prepared_return; select_parquet_first false; return ()) (fun () ->
      select_parquet_first true;
      native_hold Prepared_return;
      let admissions = dispatch_count () in
      let request = ok (A.parquet_fold_rows pool [first; second] rows ~init:()
        ~f:(fun _ () -> Stdlib.Atomic.incr callbacks; Ok (Duckdb.Continue ()))) in
      wait_scheduler (fun () -> native_entered Prepared_return > 0) >>= fun () ->
      require "first Parquet file callback drained" (Stdlib.Atomic.get callbacks = 1);
      require "selected first result prepared destruction returned" (native_entered Prepared_return = 1);
      require "second Parquet file not prepared before cancellation" (parquet_second_exec () = 0);
      ignore (ok (A.cancel request));
      native_release Prepared_return;
      complete request >>= fun result ->
      require "cancellation between Parquet files settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
      require "second Parquet file never executed" (parquet_second_exec () = 0 && Stdlib.Atomic.get callbacks = 1);
      require "Parquet cancellation retired slot" (disconnects () = 3 && connects () = 4);
      complete (ok (A.parquet_fold_rows pool [first; second] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>| fun result ->
      require "successful multi-file Parquet control" (equal_rows (List.rev (ok result)) [1L, (); 2L, ()]);
      if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
        require "multi-file Parquet uses whole request offloads" (dispatch_count () = admissions + 6))))
let parquet_read_heartbeat () =
  reset (-1);
  let source = parquet_path ".parquet" in
  Monitor.protect ~finally:(fun () -> remove_if_exists source; return ()) (fun () ->
    A.create (limits ()) (config ()) >>= fun created ->
    let pool = ok created in
    Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
      complete (ok (A.parquet_export pool ~query:"SELECT 4::BIGINT AS i" ~destination:source)) >>= fun result -> ok result;
      native_hold Execute;
      let request = ok (A.parquet_fold_rows pool [source] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values)))) in
      wait_scheduler (fun () -> native_entered Execute > 0) >>= fun () ->
      Scheduler.yield () >>= fun () ->
      require "Parquet read scheduler heartbeat after native entry" (not (Deferred.is_determined (complete request)));
      native_release Execute;
      complete request >>| fun result -> require "Parquet read after heartbeat" (equal_rows (List.rev (ok result)) [4L, ()])))
let parquet_export_cancellation_and_publication () =
  reset (-1);
  let directory = parquet_directory () in
  let before_publication = Stdlib.Filename.concat directory "before-publication.parquet" in
  let destination = Stdlib.Filename.concat directory "published-while-active.parquet" in
  let failure = Stdlib.Filename.concat directory "publish-failure.parquet" in
  let terminal = Stdlib.Filename.concat directory "post-terminal.parquet" in
  let finals = [before_publication; destination; failure; terminal] in
  Monitor.protect ~finally:(fun () ->
    native_release_all (); remove_owned_temporaries directory;
    List.iter finals ~f:remove_if_exists; Core_unix.rmdir directory; return ()) (fun () ->
    A.create (limits ()) (config ()) >>= fun created ->
    let pool = ok created in
    Monitor.protect ~finally:(fun () -> native_release_all (); close pool) (fun () ->
      (* Preserve the original cancellation-before-publication case. *)
      native_hold Execute_return;
      let admissions = dispatch_count () in
      let pre_publication = ok (A.parquet_export pool ~query:"SELECT 6::BIGINT AS i" ~destination:before_publication) in
      wait_scheduler (fun () -> native_entered Execute_return > 0) >>= fun () ->
      Scheduler.yield () >>= fun () ->
      require "export heartbeat before publication" (not (Deferred.is_determined (complete pre_publication)));
      let unlinks_before_pre_publication = temporary_unlinks () in
      ignore (ok (A.cancel pre_publication));
      native_release Execute_return;
      complete pre_publication >>= fun result ->
      require "export cancellation before publication settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
      require "cancelled pre-publication export has no final" (not (Stdlib.Sys.file_exists before_publication));
      require "pre-publication cancellation removes its owned temporary" (temporary_unlinks () = unlinks_before_pre_publication + 1 && List.is_empty (owned_temporaries directory));
      if Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal then
        require "export uses one request offload plus maintenance" (dispatch_count () = admissions + 3);
      (* The link wrapper pauses only after this request's real link succeeds. *)
      hold_publication true;
      let published = ok (A.parquet_export pool ~query:"SELECT 7::BIGINT AS i" ~destination) in
      Monitor.protect ~finally:(fun () -> hold_publication false; return ()) (fun () ->
        wait_scheduler (fun () -> publication_entries () = 1) >>= fun () ->
        require "actual publication completed while request remains active" (Stdlib.Sys.file_exists destination && not (Deferred.is_determined (complete published)));
        let unlinks_before_cancel = temporary_unlinks () in
        ignore (ok (A.cancel published));
        require "cancelled published request is still held before release" (not (Deferred.is_determined (complete published)));
        published_final_side_effect_mutation destination;
        hold_publication false;
        complete published >>= fun result ->
        require "export cancellation after publication settled" (match result with Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true | _ -> false);
        require "published final from cancelled request survives" (Stdlib.Sys.file_exists destination);
        require "published cancellation removes only its owned temporary" (temporary_unlinks () = unlinks_before_cancel + 1 && List.is_empty (owned_temporaries directory));
        complete (ok (A.parquet_fold_rows pool [destination] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>= fun result ->
        require "cancelled request's published final contents survive" (equal_rows (List.rev (ok result)) [7L, ()]);
        (* A failed publication has a distinct owned temporary and keeps its preexisting final. *)
        complete (ok (A.parquet_export pool ~query:"SELECT 8::BIGINT AS i" ~destination:failure)) >>= fun result -> ok result;
        let unlinks_before_failure = temporary_unlinks () in
        complete (ok (A.parquet_export pool ~query:"SELECT 9::BIGINT AS i" ~destination:failure)) >>= fun result ->
        require "export publication failure retained" (Result.is_error result);
        require "export failure removes its owned temporary" (temporary_unlinks () = unlinks_before_failure + 1 && List.is_empty (owned_temporaries directory));
        complete (ok (A.parquet_fold_rows pool [failure] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>= fun result ->
        require "export failure preserves preexisting final" (equal_rows (List.rev (ok result)) [8L, ()]);
        let completed = ok (A.parquet_export pool ~query:"SELECT 10::BIGINT AS i" ~destination:terminal) in
        complete completed >>= fun result -> ok result;
        require "post-terminal export reports Already_finished" (match A.cancel completed with Ok A.Already_finished -> true | _ -> false);
        complete (ok (A.parquet_fold_rows pool [terminal] rows ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))) >>| fun result ->
        require "post-terminal control preserves its own output" (equal_rows (List.rev (ok result)) [10L, ()]))))
let cases =
  [ "typed_requests", typed_requests
  ; "wide_and_multichunk", wide_and_multichunk
  ; "fold_callbacks", fold_callbacks
  ; "ingest_rollback_and_auto_flush", ingest_rollback_and_auto_flush
  ; "heartbeat_and_cancel_query", heartbeat_and_cancel_query
  ; "heartbeat_and_cancel_fold", heartbeat_and_cancel_fold
  ; "heartbeat_and_cancel_ingest", heartbeat_and_cancel_ingest
  ; "parquet_read_failures_and_callbacks", parquet_read_failures_and_callbacks
  ; "parquet_cancel_between_files", parquet_cancel_between_files
  ; "parquet_read_heartbeat", parquet_read_heartbeat
  ; "parquet_export_cancellation_and_publication", parquet_export_cancellation_and_publication
  ]
