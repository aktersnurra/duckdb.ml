let () =
  Stdlib.Printexc.record_backtrace true;
  Eio_main.run Typed_cases.run
