module System_thread = Thread
open! Base

let () =
  Eio_main.run (fun environment ->
    let running = Stdlib.Atomic.make false in
    Eio.Fiber.both
      (fun () ->
        let value = Eio_unix.run_in_systhread (fun () ->
          Stdlib.Atomic.set running true;
          System_thread.delay 0.2;
          Stdlib.Atomic.set running false;
          42) in
        assert (Int.equal value 42))
      (fun () ->
        Eio.Time.sleep (Eio.Stdenv.clock environment) 0.02;
        assert (Stdlib.Atomic.get running));
    Stdlib.print_endline "eio: worker=42 heartbeat=ok")
