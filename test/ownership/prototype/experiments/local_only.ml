(* Compiles: locality alone does not stop an aliased owner's invalidation. *)
module Unsafe : sig
  type owner
  type view
  val close : owner -> unit
  val with_view : owner -> (view @ local -> unit) -> unit
  val read : view @ local -> int
end = struct
  type owner = unit
  type view = unit
  let close _ = ()
  let with_view _ f = f ()
  let read _ = 0
end
let counterexample owner =
  Unsafe.with_view owner (fun view -> Unsafe.close owner; ignore (Unsafe.read view))
