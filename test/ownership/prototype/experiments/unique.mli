type owner
val create : unit -> owner @ unique
val use : owner @ local -> unit
val close : owner @ unique -> unit
