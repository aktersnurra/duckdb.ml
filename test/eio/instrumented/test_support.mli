exception Dispatch_fault
exception Requested
val reset : unit -> unit
val await_then_cancel : (unit -> unit) -> unit
val await_then_hold : (unit -> unit) -> unit
val before_completion_await : (unit -> 'a) -> unit
val raise_dispatch_once : unit -> unit
val before_offload_dispatch : int -> unit
val operation_worker_entry : int -> unit
val operation_workers : unit -> int
val fault_phase : unit -> int option
val completion_observed : unit -> int
val dispatch_attempts : unit -> int
