(** Test-only system-thread helpers; never call [await] on a scheduler thread. *)
val await : label:string -> (unit -> bool) -> unit

(** Idempotent join transports the original worker exception/backtrace. Always
    joins on exit. The body must release its gates in a finally BEFORE this join.
    A monotonic deadline detects failure, but the mandatory Thread.join may wait
    indefinitely for foreign work. Each executable has an external timeout: that
    is a process failure bound, not graceful cleanup or a bounded shutdown claim.
    Deadline failure never grants permission to reclaim a running resource. *)
val with_worker : (unit -> 'a) -> f:((unit -> 'a) -> 'b) -> 'b

type failure = { exception_ : exn; backtrace : Printexc.raw_backtrace }
exception Multiple_failures of failure * failure
type 'a outcome = Returned of 'a | Raised of failure
val capture : (unit -> 'a) -> 'a outcome
val restore : 'a outcome -> 'a

(** Cleanup runs even when work fails; neither failure replaces the other. *)
type 'a settlement = { primary : 'a outcome; cleanup : unit outcome }
val settle : (unit -> 'a) -> cleanup:(unit -> unit) -> 'a settlement
