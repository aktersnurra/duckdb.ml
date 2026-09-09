open! Base
module R = Adapter_bridge_responsiveness
module S = Evidence_support
module B = Duckdb.Bridge
exception Requested
exception Cancelled_with_worker_failure of exn * S.failure
let check label value = if not value then failwith label
let ok = function Ok x -> x | Error _ -> failwith "cancel acknowledgement"
let wait clock label predicate =
  let start = Mtime_clock.counter () in
  while not (predicate ()) do
    if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.) then failwith label;
    Eio.Time.sleep clock 0.001
  done
(* Test database admission only; the Eio runtime pool itself is not bounded by
   this evidence. All database offloads below must acquire this semaphore. *)
let submit slots work =
  match S.capture (fun () -> Eio.Cancel.protect (fun () ->
    Eio.Semaphore.acquire slots;
    Exn.protect ~finally:(fun () -> Eio.Semaphore.release slots)
      ~f:(fun () -> Eio_unix.run_in_systhread (fun () -> S.capture work)))) with
  | S.Returned outcome -> outcome
  | S.Raised failure -> S.Raised failure
let heartbeat clock completion seam =
  Eio.Time.sleep clock 0.001;
  check "ordinary cleanup no locked engine calls" (R.locked_engine_calls () = 0);
  check "actual native seam during heartbeat" (R.entered seam > 0);
  check "native worker not settled before release" (not (Eio.Promise.is_resolved completion))
let scenario clock slots seam =
  R.reset (); R.hold seam;
  if R.is_interrupted seam then R.hold Execute;
  let request = B.create () in
  let completion, publish = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve publish (submit slots (fun () -> R.work seam request)));
    Exn.protect ~finally:(fun () ->
      R.release_all ();
      Eio.Cancel.protect (fun () -> ignore (S.restore (Eio.Promise.await completion))))
      ~f:(fun () ->
        let first = if R.is_interrupted seam then R.Execute else seam in
        wait clock "native first entry" (fun () -> R.entered first > 0);
        heartbeat clock completion first;
        ok (B.cancel request);
        if R.is_interrupted seam then (
          wait clock "independent controller before reset" (fun () -> R.interrupts () > 0);
          R.release Execute);
        if not (phys_equal seam R.Execute) then (
          wait clock "actual cleanup/file seam" (fun () -> R.entered seam > 0);
          heartbeat clock completion seam);
        (match B.settlement request with
         | Pending -> ok (B.cancel request)
         | Settled -> check "only execute or enclosing database close can follow settlement" (phys_equal seam R.Execute || phys_equal seam R.Database_close); R.check_settled request);
        if List.mem [R.Rollback; R.Disconnect; R.Database_close; R.Appender_clear; R.Appender_destroy; R.Chunk] seam ~equal:phys_equal
        then check "terminal cleanup joins before actual native seam" (R.joins () = 1);
        R.release_all ();
        R.check_outcome seam (S.restore (Eio.Promise.await completion));
        R.check_settled request;
        if R.is_interrupted seam then check "real native interrupted completion" (R.native_errors () = 1);
        R.check_inventory ();
        Stdlib.Printf.printf "eio bridge: seam=%s native-heartbeat=ack interrupts=%d native-errors=%d joins=%d finish=%d locked-engine=%d\n%!"
          (R.name seam) (R.interrupts ()) (R.native_errors ()) (R.joins ()) (R.finish_calls ()) (R.locked_engine_calls ())))
let dispatched clock slots =
  R.reset ();
  let request = B.create () in
  let started = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let completion, publish = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve publish (submit slots (fun () ->
      Stdlib.Atomic.set started true;
      S.await ~label:"dispatched worker release" (fun () -> Stdlib.Atomic.get release);
      R.suppressed_work request)));
    Exn.protect ~finally:(fun () ->
      Stdlib.Atomic.set release true;
      Eio.Cancel.protect (fun () -> ignore (S.restore (Eio.Promise.await completion))))
      ~f:(fun () ->
        wait clock "actual dispatched worker" (fun () -> Stdlib.Atomic.get started);
        ok (B.cancel request); ok (B.cancel request);
        check "dispatched Pending until actual Bridge.run" (match B.settlement request with Pending -> true | Settled -> false);
        Stdlib.Atomic.set release true;
        (match S.restore (Eio.Promise.await completion) with Error Duckdb.Cancelled -> () | _ -> failwith "dispatched suppression");
        check "dispatched zero native calls and controllers" (R.executions () = 0 && R.interrupts () = 0 && R.joins () = 0);
        R.check_settled request; R.check_inventory ();
        Stdlib.print_endline "eio bridge: actual-dispatched cancelled-before-Bridge native-execute=0 controller-join=0"))
let saturation clock slots =
  R.reset (); R.hold Execute;
  let requests = [B.create (); B.create ()] in
  let extra = B.create () in ok (B.cancel extra);
  let extra_submitted = ref false and extra_started = Stdlib.Atomic.make false in
  Eio.Switch.run (fun sw ->
    let start request extra =
      let completion, publish = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        if extra then extra_submitted := true;
        let result = submit slots (fun () ->
          if extra then Stdlib.Atomic.set extra_started true;
          if extra then R.suppressed_work request else R.work Execute request) in
        Eio.Promise.resolve publish result);
      completion in
    let workers = List.map requests ~f:(fun r -> start r false) in
    let queued = start extra true in
    let all = queued :: workers in
    Exn.protect ~finally:(fun () ->
      R.release_all ();
      Eio.Cancel.protect (fun () -> List.iter all ~f:(fun p -> ignore (S.restore (Eio.Promise.await p)))))
      ~f:(fun () ->
        wait clock "two real native workers plus queued submission" (fun () -> R.entered Execute = 2 && !extra_submitted);
        check "additional database job queued at occupied quota" (not (Stdlib.Atomic.get extra_started));
        List.iter requests ~f:(fun r -> ok (B.cancel r));
        wait clock "independent control under occupied database slots" (fun () -> R.interrupted_connections () = 2);
        check "controller bypasses database quota" (not (Stdlib.Atomic.get extra_started));
        R.release Execute;
        List.iter2_exn (extra :: requests) all ~f:(fun r completion ->
          let outcome = S.restore (Eio.Promise.await completion) in
          if phys_equal r extra then (match outcome with Error Duckdb.Cancelled -> () | _ -> failwith "queued suppression")
          else R.check_outcome Execute outcome;
          R.check_settled r);
        check "two actual interrupted returns and joins" (R.native_errors () = 2 && R.executions () = 2 && R.joins () = 2);
        R.check_inventory ();
        Stdlib.Printf.printf "eio bridge: database-quota=2 occupied=2 queued=1 distinct-interrupted=2 native-errors=%d joins=%d independent-controller=ok\n%!" (R.native_errors ()) (R.joins ())))
let protected clock slots ~fail_cleanup =
  R.reset (); R.hold Rollback;
  let request = B.create () in
  let completion, publish = Eio.Promise.create () in
  let context, publish_context = Eio.Promise.create () in
  let noticed, publish_noticed = Eio.Promise.create () in
  let observed = ref None and original = ref None in
  Eio.Switch.run (fun sw ->
    (* Producer lifetime is the outer switch, never the cancelled waiter. *)
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve publish
      (submit slots (fun () -> R.exceptional_work ~fail_cleanup request)));
    Eio.Fiber.fork ~sw (fun () ->
      observed := Some (S.capture (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve publish_context cc;
          try
            Eio.Fiber.check ();
            ignore (Eio.Promise.await completion);
            Eio.Fiber.check ();
            failwith "waiter not cancelled"
          with Eio.Cancel.Cancelled _ as cancellation ->
            original := Some cancellation;
            ok (B.cancel request);
            Eio.Promise.resolve publish_noticed ();
            let outcome = Eio.Cancel.protect (fun () -> Eio.Promise.await completion) in
            match outcome with
            | S.Raised failure -> raise (Cancelled_with_worker_failure (cancellation, failure))
            | S.Returned () -> raise cancellation))));
    Exn.protect ~finally:(fun () -> R.release_all ()) ~f:(fun () ->
      let cc = Eio.Promise.await context in
      wait clock "real exceptional rollback entry" (fun () -> R.entered Rollback = 1);
      check "already-admitted ordinary rollback retains ineligible controller" (R.joins () = 0 && R.interrupts () = 0);
      Eio.Cancel.cancel cc Requested;
      Eio.Promise.await noticed;
      heartbeat clock completion Rollback;
      Eio.Cancel.cancel cc Requested; ok (B.cancel request);
      check "protected settlement did not reraise early" (Option.is_none !observed);
      R.release Rollback));
  (match Option.value_exn !observed with
   | S.Raised { exception_ = Cancelled_with_worker_failure (cancellation, failure); _ } ->
     check "original Eio cancellation identity" (phys_equal cancellation (Option.value_exn !original));
     check "original Eio cancellation reason" (match cancellation with Eio.Cancel.Cancelled Requested -> true | _ -> false);
     R.check_exception ~fail_cleanup (S.Raised failure)
   | _ -> failwith "lost cancellation plus worker/cleanup outcome");
  R.check_settled request; R.check_inventory ();
  Stdlib.Printf.printf "eio bridge: repeated-cancel protected-settlement=joined real-rollback-heartbeat=ack cleanup-failure=%b original-cancellation+source-trace=ok\n%!" fail_cleanup
let stale_after_reuse clock slots =
  R.reset (); R.hold Execute;
  let previous = B.create () and current = B.create () in
  let completion, publish = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve publish (submit slots (fun () -> R.reused_work previous current)));
    Exn.protect ~finally:(fun () ->
      R.release_all ();
      Eio.Cancel.protect (fun () -> ignore (S.restore (Eio.Promise.await completion))))
      ~f:(fun () ->
        wait clock "B actual native entry on reused A owner" (fun () -> R.entered Execute = 1);
        heartbeat clock completion Execute;
        R.check_settled previous; R.check_settled previous;
        check "B still pending after delayed A cancel" (match B.settlement current with Pending -> true | Settled -> false);
        check "no stale A native delivery to B" (R.interrupts () = 0);
        R.release Execute;
        ok (S.restore (Eio.Promise.await completion)); R.check_settled current;
        check "reused B native success without interrupt" (R.executions () = 1 && R.native_errors () = 0 && R.interrupts () = 0);
        R.check_inventory ();
        Stdlib.print_endline "eio bridge: same-owner-reuse A=Settled B=native-held delayed-A-cancel=Closed B=Ok interrupts=0"))
let run () =
  Stdlib.Printexc.record_backtrace true;
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let slots = Eio.Semaphore.make 2 in
    List.iter R.seams ~f:(scenario clock slots);
    dispatched clock slots;
    saturation clock slots;
    stale_after_reuse clock slots;
    protected clock slots ~fail_cleanup:false;
    protected clock slots ~fail_cleanup:true)
let () = run ()
