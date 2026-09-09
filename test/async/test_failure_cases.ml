open! Core
open! Async
open Test_support
module A = Duckdb_async
let limits n = ok (A.Limits.create ~connections:n ~queue_capacity:1)
let config () = ok (Duckdb.Config.create Memory)
let complete r = ok (A.completion r)
let rec raised = function
  | A.Raised info -> [info]
  | A.Expected _ -> []
  | A.During_cancellation failure -> raised failure
  | A.During_cleanup {primary;cleanup} -> raised primary @ raised cleanup
let monitor () =
  let notifications = ref [] in
  let monitor = Monitor.create () in
  Monitor.detach_and_iter_errors monitor ~f:(fun e -> notifications := Monitor.extract_exn e :: !notifications);
  monitor, notifications
let in_monitor monitor f = Option.value_exn (Scheduler.within_v ~monitor f)
let shutdown monitor p = in_monitor monitor (fun () -> ok (A.shutdown p))
exception Primary_failure
let primary_failure_frame () = raise (Sys.opaque_identity Primary_failure)
let initialize_close_composite () =
  reset 1; register_cleanup_failure (); fail_close true;
  Monitor.protect ~finally:(fun () -> fail_close false; return ()) (fun () ->
    A.create (limits 3) (config ()) >>| fun outcome ->
    match outcome with
    | Error (A.During_cleanup {primary = A.Expected (A.Core _); cleanup = A.Raised info}) ->
      require "init close exception identity" (phys_equal info.exception_ Cleanup_failure);
      require "init original plus cleanup" (connects () = 2 && disconnects () = 1)
    | _ -> failwith "initial acquisition and cleanup composite retained")
let multi_close_failure () =
  reset (-1); register_cleanup_failure ();
  A.create (limits 3) (config ()) >>= fun result ->
  let p = ok result in
  let observer, notifications = monitor () in
  fail_close true;
  let d = shutdown observer p in
  Monitor.protect ~finally:(fun () -> fail_close false; d >>| fun _ -> ()) (fun () ->
    d >>= fun result ->
    let failures = match result with Error failure -> raised failure | Ok () -> failwith "close failures retained" in
    require "all independent close attempts" (disconnects () = 3 && List.length failures = 3);
    require "close exception identities" (List.for_all failures ~f:(fun info -> phys_equal info.exception_ Cleanup_failure));
    require "shutdown physical shared failure" (phys_equal d (shutdown observer p));
    wait_scheduler (fun () -> List.length !notifications = 1))
let primary_cleanup_cancel () =
  reset (-1); register_cleanup_failure ();
  A.create (limits 1) (config ()) >>= fun result ->
  let p = ok result in
  let observer, notifications = monitor () in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let r = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ ->
    Stdlib.Atomic.set entered true; wait_worker release; primary_failure_frame ()))) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; native_release_all (); fail_close false;
    complete r >>= fun _ -> shutdown observer p >>| fun _ -> ()) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    native_hold Disconnect;
    fail_close true; ignore (ok (A.cancel r)); Stdlib.Atomic.set release true;
    wait_scheduler (fun () -> native_entered Disconnect = 1) >>= fun () ->
    require "composite notification waits actual native cleanup" (List.is_empty !notifications && not (Deferred.is_determined (complete r)));
    native_release Disconnect;
    complete r >>= fun result ->
    (match result with
     | Error (A.During_cancellation (A.During_cleanup {primary = A.Raised first; cleanup = A.Raised second})) ->
       require "primary cleanup exception identities" (phys_equal first.exception_ Primary_failure && phys_equal second.exception_ Cleanup_failure);
       require "primary source trace retained" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string first.backtrace) ~substring:"primary_failure_frame");
       let cleanup_trace = Stdlib.Printexc.raw_backtrace_to_string second.backtrace in
       Stdlib.Printf.printf "cleanup trace: %s\n%!" cleanup_trace;
       require "cleanup source trace retained" (String.is_substring cleanup_trace ~substring:"native_close_connection")
     | _ -> failwith "primary cleanup cancellation full tree");
    fail_close false;
    wait_scheduler (fun () -> List.length !notifications = 1) >>= fun () ->
    let d = shutdown observer p in
    d >>= fun result -> require "maintenance failure also in shutdown" (Result.is_error result);
    wait_scheduler (fun () -> List.length !notifications = 2))
let rollback_failed ~exceptional ~swallow () =
  reset (-1); register_cleanup_failure ();
  A.create (limits 1) (config ()) >>= fun result ->
  let p = ok result in
  let observer, notifications = monitor () in
  fail_rollback (if exceptional then 2 else 1);
  let r = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ -> Error (Duckdb.Native_error "primary expected")))) in
  Monitor.protect ~finally:(fun () -> fail_rollback 0; native_release_all (); complete r >>= fun _ -> shutdown observer p >>| fun _ -> ()) (fun () ->
    complete r >>= fun result ->
    (if exceptional then (
       require "rollback cleanup exception retained" (match result with Error (A.Raised {exception_ = Duckdb.Cleanup_exception (Duckdb.Native_error _, Cleanup_failure); _}) -> true | _ -> false))
     else require "rollback expected composite retained" (match result with Error (A.Expected (A.Core (Duckdb.Rollback_failed (Duckdb.Native_error _, Duckdb.Native_error _)))) -> true | _ -> false));
    fail_rollback 0;
    require "rollback failure retires not health probes" (disconnects () = 1 && connects () = 2);
    if swallow then (
      let next = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ -> Ok ()))) in
      complete next >>= fun result -> ok result;
      require "successful callback also retires" (disconnects () = 2 && connects () = 3);
      return ()) else return ()) >>= fun () ->
  require "expected errors never notify" (exceptional || List.is_empty !notifications);
  return ()
let shutdown_ordinary_rollback () =
  reset (-1); register_cleanup_failure ();
  A.create (limits 1) (config ()) >>= fun result ->
  let p = ok result in
  let observer, notifications = monitor () in
  native_hold Rollback;
  let r = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ -> primary_failure_frame ()))) in
  Monitor.protect ~finally:(fun () -> native_release_all (); complete r >>= fun _ -> shutdown observer p >>| fun _ -> ()) (fun () ->
    wait_scheduler (fun () -> native_entered Rollback = 1) >>= fun () ->
    require "ordinary rollback retains ineligible controller" (joins () = 0 && interrupts () = 0);
    let d = shutdown observer p in
    require "shutdown waits ordinary rollback" (not (Deferred.is_determined d));
    native_release Rollback;
    d >>= fun result -> ok result;
    complete r >>= fun result ->
    require "ordinary rollback primary plus cancellation" (match result with Error (A.During_cancellation (A.Raised _)) -> true | _ -> false);
    wait_scheduler (fun () -> List.length !notifications = 1))
let close_failure_slot_order () =
  reset (-1); register_cleanup_failure ();
  A.create (limits 2) (config ()) >>= fun result ->
  let p = ok result in
  let observer, _ = monitor () in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let first = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ ->
    Stdlib.Atomic.set entered true; wait_worker release; Ok ()))) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; native_release_all ();
    complete first >>= fun _ -> shutdown observer p >>| fun _ -> fail_close false; indexed_close_failure false) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    fail_close true; indexed_close_failure true;
    let second = in_monitor observer (fun () -> ok (A.transaction p ~f:(fun _ -> Ok ()))) in
    complete second >>= fun result ->
    require "slot1 close failed while slot0 still occupied" (Result.is_error result && disconnects () = 1 && not (Deferred.is_determined (complete first)));
    Stdlib.Atomic.set release true;
    shutdown observer p >>= fun result ->
    let indices = match result with
      | Error failure -> List.map (raised failure) ~f:(fun info -> match info.exception_ with Cleanup_failure_index i -> i | _ -> -1)
      | Ok () -> [] in
    require "independent close failures ordered by acquisition slot" (List.equal Int.equal indices [0;1]);
    return ())
let cases = ["close_failure_slot_order", close_failure_slot_order;
 "initialize_close_composite", initialize_close_composite; "multi_close_failure", multi_close_failure;
 "primary_cleanup_cancel", primary_cleanup_cancel; "rollback_failed", rollback_failed ~exceptional:false ~swallow:false;
 "cleanup_raised", rollback_failed ~exceptional:true ~swallow:false;
 "transaction_retire_after_failure", rollback_failed ~exceptional:false ~swallow:true;
 "shutdown_ordinary_rollback", shutdown_ordinary_rollback]
