module System_thread = Thread
open! Core
open! Async

let () =
  let running = Stdlib.Atomic.make false in
  let worker = In_thread.run (fun () ->
    Stdlib.Atomic.set running true;
    System_thread.delay 0.2;
    Stdlib.Atomic.set running false;
    42) in
  don't_wait_for
    (Clock_ns.after (Time_ns.Span.of_ms 20.)
     >>= fun () ->
     assert (Stdlib.Atomic.get running);
     assert (not (Deferred.is_determined worker));
     worker
     >>= fun value ->
     assert (Int.equal value 42);
     Stdio.print_endline "async: worker=42 heartbeat=ok";
     Shutdown.exit 0);
  never_returns (Scheduler.go ())
