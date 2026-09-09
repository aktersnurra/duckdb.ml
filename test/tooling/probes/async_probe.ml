module System_thread = Thread
open! Core
open! Async

let () =
  let start_allowed = Stdlib.Atomic.make
    (not (Option.is_some (Stdlib.Sys.getenv_opt "STAGE1_DEFER_WORKER_START"))) in
  let running = Stdlib.Atomic.make false in
  let heartbeat = Stdlib.Atomic.make false in
  let cancelled = Stdlib.Atomic.make false in
  (* Budgets bound failure, not the scheduling window in which success occurs.
     The cram test also has an outer process timeout. *)
  let rec worker_wait flag remaining =
    if Stdlib.Atomic.get flag then true
    else if remaining = 0 || Stdlib.Atomic.get cancelled then false
    else (System_thread.delay 0.001; worker_wait flag (remaining - 1))
  in
  let worker = In_thread.run (fun () ->
    if not (worker_wait start_allowed 5000) then -1
    else (
      Stdlib.Atomic.set running true;
      let acknowledged = worker_wait heartbeat 5000 in
      Stdlib.Atomic.set running false;
      if acknowledged then 42 else -1)) in
  let rec await_start remaining =
    if Stdlib.Atomic.get running then return ()
    else if remaining = 0 || Deferred.is_determined worker then
      failwith "async worker did not start"
    else Clock_ns.after (Time_ns.Span.of_ms 1.) >>= fun () -> await_start (remaining - 1)
  in
  don't_wait_for
    (Monitor.try_with (fun () ->
       Clock_ns.after (Time_ns.Span.of_ms 1.)
       >>= fun () ->
       Stdlib.Atomic.set start_allowed true;
       await_start 5000
       >>= fun () ->
       assert (not (Deferred.is_determined worker));
       if Option.is_some (Stdlib.Sys.getenv_opt "STAGE1_FAIL_HEARTBEAT") then
         failwith "injected heartbeat failure";
       (* Worker cannot finish successfully until this scheduler heartbeat. *)
       Stdlib.Atomic.set heartbeat true;
       worker >>| fun value -> assert (Int.equal value 42))
     >>= fun outcome ->
     (* Release any waiting worker before joining it, including failure paths. *)
     Stdlib.Atomic.set cancelled true;
     worker
     >>= fun _ ->
     match outcome with
     | Ok () ->
       Stdio.print_endline "async: worker=42 heartbeat=ok";
       Shutdown.exit 0
     | Error error ->
       Stdlib.prerr_endline (Exn.to_string error);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
