(** One heterogeneous list structure, indexed by the element values'
    types ['list], a curried constructor ['fn] and its result ['result]. *)
module Make (E : sig type ('a, 'n) t end) : sig
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) E.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  type 'b fold = { g : 'a 'n. ('a, 'n) E.t -> 'b -> 'b }
  val fold : ('l, 'f, 'r) t -> init:'b -> 'b fold -> 'b
  val length : ('l, 'f, 'r) t -> int
end
