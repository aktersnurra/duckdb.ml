(** Unsafe private native bridge. Not part of the scoped interface. *)
type owner
val create : unit -> owner
val prepare : owner -> string -> unit
val next : owner -> int
val status : owner -> int
val message : owner -> string
val close : owner -> unit
val length : owner @ local -> int
val valid : owner @ local -> int -> bool
val value : owner @ local -> int -> int64#
val box : int64# -> int64
val live_resources : unit -> int
val fallback_reclaims : unit -> int
