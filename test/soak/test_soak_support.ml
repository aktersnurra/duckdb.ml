open! Base
let run () =
  let config = { Soak_support.seed = 104729; episodes = 24 } in
  let first = Soak_support.schedule config in
  let second = Soak_support.schedule config in
  assert (Array.equal Poly.equal first second);
  List.iter
    [ Soak_support.Queued_cancel; Soak_support.Running_callback_cancel
    ; Soak_support.Terminal_race; Soak_support.Repeated_cancel
    ; Soak_support.Stale_reuse; Soak_support.Shutdown_active
    ; Soak_support.Shutdown_shared; Soak_support.Typed_then_shutdown ]
    ~f:(fun scenario -> assert (Array.count first ~f:(Poly.equal scenario) = 3));
  assert (Result.is_error (Soak_support.parse_config [|"soak"; "--episodes"; "23"|]));
  assert (Result.is_error (Soak_support.parse_config [|"soak"; "--unknown"|]));
  Stdlib.print_endline "soak_support: PASS"
let () = run ()
