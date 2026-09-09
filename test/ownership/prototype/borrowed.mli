(** Private stage-2 experiment. Callbacks are synchronous, with no scheduler adapters.
    Views may alias inside a callback; no owner transition is exposed.
    Escaping effects are discontinued under an internal barrier, and force
    [Effects_not_allowed] even if the callback catches the discontinuation.
    Inner callback-owned handlers may handle effects that do not capture a view.
    See docs/architecture.md for the public ownership boundary;
    arbitrary asynchronous interruption is not a deterministic-close promise. *)
type view

type error = Embedded_nul | Native_error of string | Unsupported_schema | Effects_not_allowed

type access_error = Out_of_bounds of int

type 'a step = Continue of 'a | Stop of 'a

val fold : string -> init:'a -> f:(view @ local -> 'a -> 'a step) -> ('a, error) result
val length : view @ local -> int
val get : view @ local -> int -> (int64 option, access_error) result
val copy : view @ local -> int64 option list
