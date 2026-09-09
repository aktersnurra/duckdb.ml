open! Core
open! Async
open Test_support
module A = Duckdb_async
let limits () = ok (A.Limits.create ~connections:1 ~queue_capacity:1)
let config () = ok (Duckdb.Config.create Memory)
let complete r = ok (A.completion r)
let close p = ok (A.shutdown p) >>| fun _ -> ()
let configure_idle () = fail_worker false; configure ~reserve_at:(-1) ~dispatch_at:(-1) ~entry:false ~returned:false
let reserve_partial_failure () =
  Deferred.List.iter ~how:`Sequential [0;1;2] ~f:(fun at ->
    reset (-1); configure ~reserve_at:at ~dispatch_at:(-1) ~entry:false ~returned:false;
    A.create (ok (A.Limits.create ~connections:2 ~queue_capacity:0)) (config ()) >>| fun result ->
    require "injected helper failure preserved" (match result with Error (A.Raised {exception_ = Injected_reservation; _}) -> true | _ -> false);
    require "partial reservations released exactly once" (reservation_count () = at && release_count () = at);
    require "partial reservations native_open=0" (opens () = 0))
  >>| fun () -> configure_idle ()
let with_pool f =
  reset (-1); configure_idle ();
  A.create (limits ()) (config ()) >>= fun result ->
  let p = ok result in
  Monitor.protect ~finally:(fun () -> release_workers (); native_release_all (); close p >>| configure_idle) (fun () -> f p)
let dispatched_cancel ~shutdown () = with_pool (fun p ->
  configure ~reserve_at:(-1) ~dispatch_at:(-1) ~entry:true ~returned:false;
  let r = ok (A.execute p "COPY (SELECT 1) TO '/tmp/stage4c-forbidden-dispatch.csv'") in
  wait_scheduler entry_seen >>= fun () ->
  let stopped = if shutdown then Some (ok (A.shutdown p)) else (ignore (ok (A.cancel r)); None) in
  require "dispatched capsule retained before acknowledgement" (not (Deferred.is_determined (complete r)) && disconnects () = 0);
  require "dispatched bounded offload" (dispatch_count () = 1);
  release_workers ();
  complete r >>= fun result ->
  require "dispatched cancellation zero SQL/filesystem entry" (executions () = 0);
  require "dispatched cancelled outcome" (match result with Error (A.Expected A.Cancelled) -> true | _ -> false);
  require "dispatched zero controller" (joins () = 0);
  match stopped with None -> return () | Some d -> d >>| ok)
let dispatch_exception () = with_pool (fun p ->
  configure ~reserve_at:(-1) ~dispatch_at:0 ~entry:false ~returned:false;
  let notifications = ref [] in
  let monitor = Monitor.create () in
  Monitor.detach_and_iter_errors monitor ~f:(fun e -> notifications := Monitor.extract_exn e :: !notifications);
  let r = Option.value_exn (Scheduler.within_v ~monitor (fun () -> ok (A.execute p "select 1"))) in
  complete r >>= fun result ->
  require "synchronous dispatch captured" (match result with Error (A.Raised {exception_ = Injected_dispatch; _}) -> true | _ -> false);
  require "dispatch failure no worker SQL" (executions () = 0 && not (entry_seen ()));
  require "dispatch failure replacement accounted" (disconnects () = 1 && connects () = 2);
  wait_scheduler (fun () -> List.length !notifications = 1))
let cancel_at_terminal () = with_pool (fun p ->
  configure ~reserve_at:(-1) ~dispatch_at:(-1) ~entry:false ~returned:true;
  let r = ok (A.execute p "select 1") in
  wait_scheduler return_seen >>= fun () ->
  require "Bridge returned before adapter terminal" (joins () = 1 && not (Deferred.is_determined (complete r)));
  ignore (ok (A.cancel r)); release_workers ();
  complete r >>= fun result ->
  require "preterminal cancellation wins" (match result with Error (A.Expected A.Cancelled) -> true | _ -> false);
  require "preterminal cancellation retires owner" (disconnects () = 1 && connects () = 2);
  require "postterminal cancellation finished" (match A.cancel r with Ok A.Already_finished -> true | _ -> false);
  require "completion physically shared" (phys_equal (complete r) (complete r));
  return ())
let shutdown_helpers () =
  reset (-1); configure_idle ();
  A.create (limits ()) (config ()) >>= fun result ->
  let p = ok result in
  native_hold Database_close;
  let observer = Monitor.create () in
  Monitor.detach_and_iter_errors observer ~f:(fun _ -> ());
  let d = Option.value_exn (Scheduler.within_v ~monitor:observer (fun () -> ok (A.shutdown p))) in
  Monitor.protect ~finally:(fun () -> native_release_all (); d >>| fun _ -> configure_idle ()) (fun () ->
    wait_scheduler (fun () -> native_entered Database_close > 0 || Deferred.is_determined d) >>= fun () ->
    require "helpers retained until last job acknowledges" (release_count () = 0 && not (Deferred.is_determined d));
    native_release Database_close;
    d >>| fun result -> ok result;
    require "helpers explicitly released exactly once" (release_count () = 2))
let worker_exception () = with_pool (fun p ->
  let observer = Monitor.create () in
  let notified = Ivar.create () in
  Monitor.detach_and_iter_errors observer ~f:(fun exn -> Ivar.fill_exn notified (Monitor.extract_exn exn));
  fail_worker true;
  let r = Option.value_exn (Scheduler.within_v ~monitor:observer (fun () -> ok (A.execute p "select 1"))) in
  complete r >>= fun result ->
  fail_worker false;
  (match result with
   | Error (A.Raised {exception_ = Injected_worker; backtrace}) ->
     require "worker source trace captured inside offload"
       (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace) ~substring:"worker_entry")
   | _ -> failwith "worker exception captured inside offload");
  require "worker failure has settled replacement" (executions () = 0 && connects () = 2 && disconnects () = 1);
  Ivar.read notified >>| fun exn -> require "worker original monitor notification" (phys_equal exn Injected_worker))
let initialize_dispatch_failure () =
  reset (-1); configure ~reserve_at:(-1) ~dispatch_at:0 ~entry:false ~returned:false;
  A.create (limits ()) (config ()) >>| fun result ->
  require "initialize dispatch exception retained" (match result with Error (A.Raised {exception_ = Injected_dispatch; _}) -> true | _ -> false);
  require "initialize dispatch releases before completion" (opens () = 0 && release_count () = 2);
  configure_idle ()
let cases = ["worker_exception", worker_exception; "initialize_dispatch_failure", initialize_dispatch_failure;
 "reserve_partial_failure", reserve_partial_failure;
 "dispatched_cancel", dispatched_cancel ~shutdown:false;
 "shutdown_dispatched", dispatched_cancel ~shutdown:true;
 "dispatch_exception", dispatch_exception; "cancel_at_terminal", cancel_at_terminal;
 "shutdown_helpers", shutdown_helpers]
