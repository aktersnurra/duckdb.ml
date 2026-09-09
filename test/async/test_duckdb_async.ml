open! Core
open! Async
open Test_support
module A = Duckdb_async
let config () = ok (Duckdb.Config.create Memory)
let limits n q = ok (A.Limits.create ~connections:n ~queue_capacity:q)
let complete r = ok (A.completion r)
let close p = ok (A.shutdown p) >>| ok
let invalid_limits () =
  List.iter [0; -1] ~f:(fun n -> require "invalid connections" (match A.Limits.create ~connections:n ~queue_capacity:0 with Error (A.Invalid_connections _) -> true | _ -> false));
  require "invalid queue" (match A.Limits.create ~connections:1 ~queue_capacity:(-1) with Error (A.Invalid_queue_capacity _) -> true | _ -> false);
  ignore (limits 1 0); ignore (limits Int.max_value Int.max_value);
  return ()
let reserve_real_capacity_failure () =
  reset (-1);
  let held = ref [] in
  let rec exhaust () = match In_thread.Helper_thread.create_now () with Error _ -> () | Ok h -> held := h :: !held; exhaust () in
  exhaust ();
  Monitor.protect ~finally:(fun () -> List.iter !held ~f:In_thread.Helper_thread.finished_with; return ()) (fun () ->
    A.create (limits 1 0) (config ()) >>| fun result ->
    require "real reservation failure" (Result.is_error result);
    require "reservation failure native_open=0" (opens () = 0))
  >>= fun () -> A.create (limits 1 0) (config ()) >>= fun p -> close (ok p)
let initialize_connect_failure () =
  Deferred.List.iter ~how:`Sequential [0;1;2] ~f:(fun at ->
    reset at;
    A.create (limits 3 0) (config ()) >>| fun result ->
    require "connect failure reported" (Result.is_error result);
    require "acquired prefix closed" (disconnects () = at);
    require "initialization resources zero" (Duckdb_ffi.live_resources () = 0))
let initialize_open_failure () =
  reset (-1);
  let path = Stdlib.Filename.concat (Stdlib.Sys.getcwd ()) "__stage4c_absent_database__/db" in
  require "open failure fixture absent" (not (Stdlib.Sys.file_exists path));
  let config = ok (Duckdb.Config.create ~access:Read_only (File path)) in
  A.create (limits 1 0) config >>| fun result ->
  require "native open error preserved" (match result with Error (A.Expected (A.Core (Duckdb.Native_error _))) -> true | _ -> false);
  require "failed open never connects" (opens () = 1 && connects () = 0)
let shutdown_idle () =
  reset (-1);
  A.create (limits 2 0) (config ()) >>= fun result ->
  let p = ok result in
  let d = ok (A.shutdown p) in
  require "shutdown shared deferred" (phys_equal d (ok (A.shutdown p)));
  d >>| fun result -> ok result;
  require "idle slots closed" (disconnects () = 2);
  require "shutdown no admission" (match A.execute p "select 1" with Error A.Pool_shutdown -> true | _ -> false)
let fifo_survivors () =
  reset (-1);
  A.create (limits 1 2) (config ()) >>= fun pool ->
  let p = ok pool in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let a = ok (A.transaction p ~f:(fun _ -> Stdlib.Atomic.set entered true; wait_worker release; Ok ())) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; close p) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let order = ref [] in
    let offloads_before_queue = dispatch_count () in
    let b = ok (A.transaction p ~f:(fun _ -> order := 2 :: !order; Ok ())) in
    let c = ok (A.transaction p ~f:(fun _ -> order := 3 :: !order; Ok ())) in
    require "overflow no admission" (match A.execute p "select 4" with Error A.Queue_full -> true | _ -> false);
    require "waiting and overflow create zero offloads" (dispatch_count () = offloads_before_queue);
    require "queued cancel requested" (match A.cancel b with Ok A.Requested -> true | _ -> false);
    complete b >>= fun result ->
    require "queued cancelled" (match result with Error (A.Expected A.Cancelled) -> true | _ -> false);
    require "finished cancel" (match A.cancel b with Ok A.Already_finished -> true | _ -> false);
    let d = ok (A.transaction p ~f:(fun _ -> order := 4 :: !order; Ok ())) in
    Stdlib.Atomic.set release true;
    complete a >>= fun result -> ok result;
    complete c >>= fun result -> ok result;
    complete d >>| fun result -> ok result;
    require "FIFO surviving nodes" (List.equal Int.equal (List.rev !order) [3;4]))
let zero_queue () =
  reset (-1);
  A.create (limits 1 0) (config ()) >>= fun pool ->
  let p = ok pool in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let a = ok (A.transaction p ~f:(fun _ -> Stdlib.Atomic.set entered true; wait_worker release; Ok ())) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; close p) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    require "zero queue rejects one waiting" (match A.execute p "select 1" with Error A.Queue_full -> true | _ -> false);
    Stdlib.Atomic.set release true; complete a >>| ok)
let callback_guard () =
  reset (-1);
  A.create (limits 1 1) (config ()) >>= fun pool ->
  let p = ok pool in
  A.create (limits 1 0) (config ()) >>= fun other ->
  let q = ok other in
  let previous = ok (A.execute p "select 1") in
  complete previous >>= fun result -> ok result;
  Monitor.protect ~finally:(fun () -> close p >>= fun () -> close q) (fun () ->
    let r = ok (A.transaction p ~f:(fun _ ->
      let rejected = function Error A.Reentrant_call -> true | _ -> false in
      List.iter [p;q] ~f:(fun target ->
        require "callback execute guard" (rejected (A.execute target "select 2"));
        require "callback transaction guard" (rejected (A.transaction target ~f:(fun _ -> Ok ())));
        require "callback shutdown guard" (rejected (A.shutdown target)));
      require "callback completion guard" (rejected (A.completion previous));
      require "callback cancel guard" (rejected (A.cancel previous));
      Ok ())) in
    complete r >>= fun result -> ok result;
    let next = ok (A.execute p "select 3") in complete next >>| ok)
exception Callback_failure
exception Abandoned
let callback_failure_frame () = raise (Sys.opaque_identity Callback_failure)
let worker_exception_monitor () =
  reset (-1);
  A.create (limits 1 1) (config ()) >>= fun pool ->
  let p = ok pool in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let notifications = ref [] and reference = ref None in
  let observer = Monitor.create () in
  Monitor.detach_and_iter_errors observer ~f:(fun exn ->
    let exn = Monitor.extract_exn exn in
    if not (phys_equal exn Abandoned) then (
      let r = Option.value_exn !reference in
      require "completion before exceptional monitor" (Deferred.is_determined (complete r));
      require "replacement accounting before monitor" (connects () = 2);
      notifications := exn :: !notifications));
  native_hold Rollback;
  let r = Option.value_exn (Scheduler.within_v ~monitor:observer (fun () ->
    ok (A.transaction p ~f:(fun _ -> Stdlib.Atomic.set entered true; wait_worker release; callback_failure_frame ())))) in
  reference := Some r;
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; native_release_all (); close p) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    ignore (Scheduler.within_v ~monitor:observer (fun () -> raise Abandoned));
    Stdlib.Atomic.set release true;
    wait_scheduler (fun () -> native_entered Rollback = 1) >>= fun () ->
    require "failed observer cannot abandon held native rollback" (not (Deferred.is_determined (complete r)) && List.is_empty !notifications && joins () = 0);
    native_release Rollback;
    complete r >>= fun result ->
    (match result with Error (A.Raised info) ->
      require "callback exception identity" (phys_equal info.exception_ Callback_failure);
      require "callback source trace" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string info.backtrace) ~substring:"callback_failure_frame")
     | _ -> failwith "callback exception preserved");
    wait_scheduler (fun () -> List.length !notifications = 1) >>= fun () ->
    require "one original monitor notification" (phys_equal (List.hd_exn !notifications) Callback_failure);
    complete (ok (A.execute p "select 1")) >>| ok)
let shutdown_running () =
  reset (-1);
  A.create (limits 1 1) (config ()) >>= fun pool ->
  let p = ok pool in
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let r = ok (A.transaction p ~f:(fun _ -> Stdlib.Atomic.set entered true; wait_worker release; Ok ())) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; close p) (fun () ->
    wait_scheduler (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let q = ok (A.execute p "select 2") in
    let s = ok (A.shutdown p) in
    require "concurrent shutdown same" (phys_equal s (ok (A.shutdown p)));
    require "shutdown waits active worker" (not (Deferred.is_determined s));
    require "no disconnect before return" (disconnects () = 0);
    complete q >>= fun result ->
    require "queued shutdown named" (match result with Error (A.Expected A.Pool_shutdown) -> true | _ -> false);
    Stdlib.Atomic.set release true;
    s >>= fun result -> ok result;
    complete r >>| fun result ->
    require "active shutdown cancelled" (match result with Error (A.Expected A.Cancelled) -> true | _ -> false);
    require "stop no replacement" (connects () = 1))
let cases = ["zero_queue", zero_queue; "callback_guard", callback_guard;
 "worker_exception_monitor", worker_exception_monitor; "shutdown_running", shutdown_running;
 "invalid_limits", invalid_limits; "reserve_real_capacity_failure", reserve_real_capacity_failure;
 "initialize_open_failure", initialize_open_failure;
 "initialize_connect_failure", initialize_connect_failure; "shutdown_idle", shutdown_idle; "fifo_survivors", fifo_survivors]
type _ Stdlib.Effect.t += Callback_pause : unit Stdlib.Effect.t
let callback_effect_denied () =
  reset (-1);
  A.create (limits 1 0) (config ()) >>= fun result ->
  let p = ok result in
  Monitor.protect ~finally:(fun () -> close p) (fun () ->
    let r = ok (A.transaction p ~f:(fun _ -> Stdlib.Effect.perform Callback_pause; Ok ())) in
    complete r >>| fun result ->
    require "core outward effect barrier preserved" (match result with Error (A.Expected (A.Core Duckdb.Effects_not_allowed)) -> true | _ -> false))
let cases = cases @ ["callback_effect_denied", callback_effect_denied] @ Test_native_cases.cases @ Test_failure_cases.cases
let run () =
  Stdlib.Printexc.record_backtrace true;
  let negative = Array.exists (Sys.get_argv ()) ~f:(fun x -> String.equal x "--fail-heartbeat" || String.equal x "--held-lock-negative") in
  if Array.mem (Sys.get_argv ()) "--held-lock-negative" ~equal:String.equal then force_locked_destructor true;
  don't_wait_for (Monitor.try_with (fun () ->
    let instrumented = Array.mem (Sys.get_argv ()) "--instrumented" ~equal:String.equal in
    let cases = if instrumented then cases @ Test_instrumented_cases.cases else cases in
    let selected = Array.to_list (Sys.get_argv ()) |> List.tl_exn |> List.filter ~f:(fun x -> not (String.equal x "--" || String.equal x "--instrumented" || String.equal x "--fail-heartbeat" || String.equal x "--held-lock-negative")) in
    List.iter selected ~f:(fun name -> require ("unknown async test selector: " ^ name) (List.exists cases ~f:(fun (known, _) -> String.equal known name)));
    Deferred.List.iter ~how:`Sequential cases ~f:(fun (name, f) ->
      if List.is_empty selected || List.mem selected name ~equal:String.equal then
        f () >>| fun () -> require "live=0" (Duckdb_ffi.live_resources () = 0);
          require "fallback=0" (Duckdb_ffi.fallback_reclaims () = 0);
          require "ordinary cleanup no locked engine calls" (locked_calls () = 0);
          Stdlib.Printf.printf "PASS %s live=0 fallback=0 opens=%d connects=%d disconnects=%d executions=%d interrupts=%d distinct=%d joins=%d commits=%d locked=%d\n%!"
            name (opens ()) (connects ()) (disconnects ()) (executions ()) (interrupts ()) (distinct_interrupted ()) (joins ()) (commits ()) (locked_calls ())
      else return ())) >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn ->
      Stdlib.prerr_endline (Exn.to_string exn);
      if negative then (
        Stdlib.Printf.printf "negative cleanup joined: live=%d fallback=%d joins=%d\n%!" (Duckdb_ffi.live_resources ()) (Duckdb_ffi.fallback_reclaims ()) (joins ());
        if Duckdb_ffi.live_resources () <> 0 || Duckdb_ffi.fallback_reclaims () <> 0 then Shutdown.exit 2 else Shutdown.exit 1)
      else Shutdown.exit 1);
  never_returns (Scheduler.go ())
let () = run ()
