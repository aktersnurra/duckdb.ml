open! Base

let output path f =
  let channel = Stdlib.open_out path in
  Exn.protect
    ~f:(fun () ->
      let formatter = Stdlib.Format.formatter_of_out_channel channel in
      f formatter;
      Stdlib.Format.pp_print_flush formatter ())
    ~finally:(fun () -> Stdlib.close_out channel)

let () =
  output Stdlib.Sys.argv.(1) (fun formatter ->
    Stdlib.Format.fprintf formatter "#include \"native_probe.h\"@.";
    Cstubs.write_c ~concurrency:Cstubs.unlocked formatter ~prefix:"stage1_generated"
      (module Generated_bindings.Bindings));
  output Stdlib.Sys.argv.(2) (fun formatter ->
    (* Warnings-as-errors apply to authored code, not generated bindings. *)
    Stdlib.Format.fprintf formatter "[@@@@@@warning \"-a\"]@.";
    Cstubs.write_ml ~concurrency:Cstubs.unlocked formatter ~prefix:"stage1_generated"
      (module Generated_bindings.Bindings))
