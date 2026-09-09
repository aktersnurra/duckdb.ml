module System_thread = Thread
open! Base

let () =
  Eio_main.run (fun environment ->
    let start_allowed = Stdlib.Atomic.make
      (not (Option.is_some (Stdlib.Sys.getenv_opt "STAGE1_DEFER_WORKER_START"))) in
    let running = Stdlib.Atomic.make false in
    let heartbeat = Stdlib.Atomic.make false in
    let cancelled = Stdlib.Atomic.make false in
    (* Budgets bound failure, not a worker/timer success window. *)
    let rec worker_wait flag remaining =
      if Stdlib.Atomic.get flag then true
      else if remaining = 0 || Stdlib.Atomic.get cancelled then false
      else (System_thread.delay 0.001; worker_wait flag (remaining - 1))
    in
    let clock = Eio.Stdenv.clock environment in
    let rec await_start remaining =
      if Stdlib.Atomic.get running then ()
      else if remaining = 0 then failwith "eio worker did not start"
      else (Eio.Time.sleep clock 0.001; await_start (remaining - 1))
    in
    Eio.Fiber.both
      (fun () ->
        let value = Eio_unix.run_in_systhread (fun () ->
          if not (worker_wait start_allowed 5000) then -1
          else (
            Stdlib.Atomic.set running true;
            let acknowledged = worker_wait heartbeat 5000 in
            Stdlib.Atomic.set running false;
            if acknowledged then 42 else -1)) in
        assert (Int.equal value 42))
      (fun () ->
        Exn.protect
          ~f:(fun () ->
            Eio.Time.sleep clock 0.001;
            Stdlib.Atomic.set start_allowed true;
            await_start 5000;
            if Option.is_some (Stdlib.Sys.getenv_opt "STAGE1_FAIL_HEARTBEAT") then
              failwith "injected heartbeat failure";
            (* Worker stays in flight until this scheduler heartbeat. *)
            Stdlib.Atomic.set heartbeat true)
          (* Release the worker before Fiber.both waits for it on failure. *)
          ~finally:(fun () -> Stdlib.Atomic.set cancelled true));
    Stdlib.print_endline "eio: worker=42 heartbeat=ok")
