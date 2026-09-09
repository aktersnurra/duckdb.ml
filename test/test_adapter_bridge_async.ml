open! Core
open! Async
module R = Adapter_bridge_responsiveness
module S = Evidence_support
module B = Duckdb.Bridge
let check label value = if not value then failwith label
let ok = function Ok x -> x | Error _ -> failwith "cancel acknowledgement"
let wait label predicate =
  let start = Mtime_clock.counter () in
  let rec loop () =
    if predicate () then return ()
    else if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.) then failwith label
    else Clock_ns.after (Time_ns.Span.of_ms 1.) >>= loop in
  loop ()
(* Every database offload in this executable goes through this test-owned quota.
   This does not configure or claim saturation of Async's global thread pool. *)
let submit slots work =
  match S.capture (fun () -> Throttle.enqueue slots (fun () ->
    match S.capture (fun () -> In_thread.run (fun () -> S.capture work)) with
    | S.Returned deferred -> deferred
    | S.Raised failure -> return (S.Raised failure))) with
  | S.Returned deferred -> deferred
  | S.Raised failure -> return (S.Raised failure)
let heartbeat worker seam =
  Clock_ns.after (Time_ns.Span.of_ms 1.) >>| fun () ->
  check "ordinary cleanup no locked engine calls" (R.locked_engine_calls () = 0);
  check "native gate still entered during scheduler heartbeat" (R.entered seam > 0);
  check "worker remains in actual native gate" (not (Deferred.is_determined worker))
let scenario slots seam =
  R.reset (); R.hold seam;
  if R.is_interrupted seam then R.hold Execute;
  let request = B.create () in
  let worker = submit slots (fun () -> R.work seam request) in
  Monitor.protect ~finally:(fun () -> R.release_all (); worker >>| fun result -> ignore (S.restore result))
    (fun () ->
      let first = if R.is_interrupted seam then R.Execute else seam in
      wait "native first entry" (fun () -> R.entered first > 0) >>= fun () ->
      heartbeat worker first >>= fun () ->
      ok (B.cancel request);
      (if R.is_interrupted seam then
        wait "independent controller before reset" (fun () -> R.interrupts () > 0)
       else return ()) >>= fun () ->
      if R.is_interrupted seam then R.release Execute;
      (if not (phys_equal seam R.Execute) then
        wait "actual cleanup/file seam" (fun () -> R.entered seam > 0) >>= fun () -> heartbeat worker seam
       else return ()) >>= fun () ->
      (match B.settlement request with
       | Pending -> ok (B.cancel request)
       | Settled -> check "only execute or enclosing database close can follow settlement" (phys_equal seam R.Execute || phys_equal seam R.Database_close); R.check_settled request);
      if List.mem [R.Rollback; R.Disconnect; R.Database_close; R.Appender_clear; R.Appender_destroy; R.Chunk] seam ~equal:phys_equal
      then check "terminal cleanup joins before native seam" (R.joins () = 1);
      R.release_all ();
      worker >>| fun result ->
      R.check_outcome seam (S.restore result); R.check_settled request;
      if R.is_interrupted seam then check "native interrupted completion" (R.native_errors () = 1);
      R.check_inventory ();
      printf "async bridge: seam=%s native-heartbeat=ack interrupts=%d native-errors=%d joins=%d finish=%d locked-engine=%d\n%!"
        (R.name seam) (R.interrupts ()) (R.native_errors ()) (R.joins ()) (R.finish_calls ()) (R.locked_engine_calls ()))
let dispatched slots =
  R.reset ();
  let request = B.create () in
  let started = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let worker = submit slots (fun () ->
    Stdlib.Atomic.set started true;
    S.await ~label:"dispatched worker release" (fun () -> Stdlib.Atomic.get release);
    R.suppressed_work request) in
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; worker >>| fun outcome -> ignore (S.restore outcome))
    (fun () ->
      wait "actual dispatched worker" (fun () -> Stdlib.Atomic.get started) >>= fun () ->
      ok (B.cancel request); ok (B.cancel request);
      check "dispatched request pending until worker enters" (match B.settlement request with Pending -> true | Settled -> false);
      Stdlib.Atomic.set release true;
      worker >>| fun outcome ->
      (match S.restore outcome with Error Duckdb.Cancelled -> () | _ -> failwith "dispatched suppression");
      check "dispatched zero native calls and controllers" (R.executions () = 0 && R.interrupts () = 0 && R.joins () = 0);
      R.check_settled request; R.check_inventory ();
      printf "async bridge: actual-dispatched cancelled-before-Bridge native-execute=0 controller-join=0\n%!")
let saturation slots =
  R.reset (); R.hold Execute;
  let requests = [B.create (); B.create ()] in
  let workers = List.map requests ~f:(fun request -> submit slots (fun () -> R.work Execute request)) in
  let queued = B.create () in ok (B.cancel queued);
  let extra_started = Stdlib.Atomic.make false in
  let extra = submit slots (fun () -> Stdlib.Atomic.set extra_started true; R.suppressed_work queued) in
  let joined = Deferred.all (extra :: workers) in
  Monitor.protect ~finally:(fun () -> R.release_all (); joined >>| fun results -> List.iter results ~f:(fun r -> ignore (S.restore r)))
    (fun () ->
      wait "two actual native database workers" (fun () -> R.entered Execute = 2) >>= fun () ->
      check "all database slots occupied" (Throttle.num_jobs_running slots = 2);
      check "additional database offload remains queued" (Throttle.num_jobs_waiting_to_start slots = 1 && not (Stdlib.Atomic.get extra_started));
      List.iter requests ~f:(fun r -> ok (B.cancel r));
      wait "independent control under occupied database slots" (fun () -> R.interrupted_connections () = 2) >>= fun () ->
      check "control did not consume database slot" (not (Stdlib.Atomic.get extra_started));
      R.release Execute;
      joined >>| fun results ->
      List.iter2_exn (queued :: requests) results ~f:(fun r outcome ->
        if phys_equal r queued then (match S.restore outcome with Error Duckdb.Cancelled -> () | _ -> failwith "queued suppression")
        else R.check_outcome Execute (S.restore outcome);
        R.check_settled r);
      check "both real native interrupted completions" (R.native_errors () = 2 && R.executions () = 2 && R.joins () = 2);
      R.check_inventory ();
      printf "async bridge: database-quota=2 occupied=2 queued=1 distinct-interrupted=2 native-errors=%d joins=%d independent-controller=ok global-pool=unchanged\n%!" (R.native_errors ()) (R.joins ()))
exception Abandoned
let abandoned slots ~fail_cleanup =
  R.reset (); R.hold Rollback;
  let request = B.create () in
  let completion = Ivar.create () and routed = Ivar.create () and failed = Ivar.create () in
  let caller = Monitor.create () in
  let deliveries = ref 0 in
  Monitor.detach_and_iter_errors caller ~f:(fun exn ->
    match Monitor.extract_exn exn with
    | Abandoned -> Ivar.fill_exn failed ()
    | other -> Ivar.fill_exn routed (other, Ivar.is_full completion, !deliveries));
  ignore (Scheduler.within_v ~monitor:caller (fun () -> Deferred.never ()));
  let worker = submit slots (fun () -> R.exceptional_work ~fail_cleanup request) in
  let producer = worker >>| fun outcome ->
    incr deliveries; Ivar.fill_exn completion outcome;
    match outcome with
    | S.Raised failure -> Monitor.send_exn caller ~backtrace:(`This failure.backtrace) failure.exception_
    | S.Returned () -> Ivar.fill_exn routed (Failure "exception lost", true, !deliveries) in
  Monitor.protect ~finally:(fun () -> R.release_all (); producer)
    (fun () ->
      wait "abandoned actual rollback" (fun () -> R.entered Rollback = 1) >>= fun () ->
      ignore (Scheduler.within_v ~monitor:caller (fun () -> raise Abandoned));
      Ivar.read failed >>= fun () ->
      heartbeat worker Rollback >>= fun () ->
      check "already-admitted ordinary rollback retains ineligible controller" (R.joins () = 0 && R.interrupts () = 0);
      ok (B.cancel request); ok (B.cancel request);
      check "completion remains owned and pending" (not (Ivar.is_full completion));
      R.release Rollback;
      producer >>= fun () -> Ivar.read routed >>| fun (exception_, completed, count) ->
      check "owned completion before monitor after abandoned caller" (completed && count = 1);
      let outcome = Option.value_exn (Ivar.peek completion) in
      R.check_exception ~fail_cleanup outcome;
      (match outcome with S.Raised failure -> check "monitor exception identity" (phys_equal exception_ failure.exception_) | _ -> assert false);
      R.check_settled request; R.check_inventory ();
      printf "async bridge: abandoned-caller completion=once real-rollback-heartbeat=ack cleanup-failure=%b original-source-trace=ok\n%!" fail_cleanup)
let stale_after_reuse slots =
  R.reset (); R.hold Execute;
  let previous = B.create () and current = B.create () in
  let worker = submit slots (fun () -> R.reused_work previous current) in
  Monitor.protect ~finally:(fun () -> R.release_all (); worker >>| fun outcome -> ignore (S.restore outcome))
    (fun () ->
      wait "B actual native entry on reused A owner" (fun () -> R.entered Execute = 1) >>= fun () ->
      heartbeat worker Execute >>= fun () ->
      R.check_settled previous; R.check_settled previous;
      check "B still pending after delayed A cancel" (match B.settlement current with Pending -> true | Settled -> false);
      check "no stale A native delivery to B" (R.interrupts () = 0);
      R.release Execute;
      worker >>| fun outcome ->
      ok (S.restore outcome); R.check_settled current;
      check "reused B completed native query without interrupt" (R.executions () = 1 && R.native_errors () = 0 && R.interrupts () = 0);
      R.check_inventory ();
      printf "async bridge: same-owner-reuse A=Settled B=native-held delayed-A-cancel=Closed B=Ok interrupts=0\n%!")
let cases () =
  let slots = Throttle.create ~continue_on_error:true ~max_concurrent_jobs:2 in
  Deferred.List.iter R.seams ~how:`Sequential ~f:(scenario slots) >>= fun () ->
  dispatched slots >>= fun () -> saturation slots >>= fun () -> stale_after_reuse slots >>= fun () ->
  abandoned slots ~fail_cleanup:false >>= fun () -> abandoned slots ~fail_cleanup:true
let run () =
  Stdlib.Printexc.record_backtrace true;
  don't_wait_for (Monitor.try_with cases >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> Stdlib.prerr_endline (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
let () = run ()
