open! Base

type scenario =
  | Queued_cancel | Running_callback_cancel | Terminal_race | Repeated_cancel
  | Stale_reuse | Shutdown_active | Shutdown_shared | Typed_then_shutdown

type config = { seed : int; episodes : int }

let scenarios = [| Queued_cancel; Running_callback_cancel; Terminal_race; Repeated_cancel
                ; Stale_reuse; Shutdown_active; Shutdown_shared; Typed_then_shutdown |]
let scenario_name = function
  | Queued_cancel -> "queued_cancel" | Running_callback_cancel -> "running_callback_cancel"
  | Terminal_race -> "terminal_race" | Repeated_cancel -> "repeated_cancel"
  | Stale_reuse -> "stale_reuse" | Shutdown_active -> "shutdown_active"
  | Shutdown_shared -> "shutdown_shared" | Typed_then_shutdown -> "typed_then_shutdown"

let parse_config argv =
  if Array.length argv <> 5 || not (String.equal argv.(1) "--seed") || not (String.equal argv.(3) "--episodes") then
    Error "usage: --seed INT --episodes INT"
  else match Int.of_string_opt argv.(2), Int.of_string_opt argv.(4) with
    | Some seed, Some episodes when episodes > 0 && episodes % 8 = 0 -> Ok { seed; episodes }
    | _ -> Error "episodes must be positive and divisible by 8"

let schedule { seed; episodes } =
  let result = Array.init episodes ~f:(fun index -> scenarios.(index % Array.length scenarios)) in
  let random = Random.State.make [| seed |] in
  for index = Array.length result - 1 downto 1 do
    let other = Random.State.int random (index + 1) in
    let item = result.(index) in result.(index) <- result.(other); result.(other) <- item
  done;
  result

let report ~adapter config ~episode scenario ~detail =
  Stdlib.Printf.printf "SOAK adapter=%s seed=%d episode=%d scenario=%s %s\n%!"
    adapter config.seed episode (scenario_name scenario) detail
