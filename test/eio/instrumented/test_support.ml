open! Base
exception Dispatch_fault
exception Requested

type mode = Idle | Await_then_cancel of (unit -> unit) | Await_then_hold of (unit -> unit) | Raise_dispatch_once
let mode = ref Idle
let observed = ref 0
let dispatches = ref 0
let workers = Stdlib.Atomic.make 0
let phase = ref None
let reset () = mode := Idle; observed := 0; dispatches := 0; Stdlib.Atomic.set workers 0; phase := None
let await_then_cancel cancel = mode := Await_then_cancel cancel
let await_then_hold hold = mode := Await_then_hold hold
let raise_dispatch_once () = mode := Raise_dispatch_once
let completion_observed () = !observed
let dispatch_attempts () = !dispatches
let operation_workers () = Stdlib.Atomic.get workers
let fault_phase () = !phase
let operation_worker_entry = function
  | 0 -> ignore (Stdlib.Atomic.fetch_and_add workers 1)
  | _ -> ()
let before_completion_await await =
  match !mode with
  | Await_then_cancel cancel | Await_then_hold cancel ->
    (* Consume before yielding: only A waits here, never its successor B. *)
    mode := Idle;
    ignore (await ());
    observed := !observed + 1;
    cancel ()
  | Idle | Raise_dispatch_once -> ()
let[@inline never] dispatch_fault_source_frame () = raise Dispatch_fault
let before_offload_dispatch = function
  | 0 ->
    dispatches := !dispatches + 1;
    (match !mode with
     | Raise_dispatch_once -> mode := Idle; phase := Some 0; dispatch_fault_source_frame ()
     | Idle | Await_then_cancel _ | Await_then_hold _ -> ())
  | _ -> ()
