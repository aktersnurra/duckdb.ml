include Codec.Values
(* Indexed like [Fields], plus ['shape]: each column's value type and
   nullability, which typed SQL binds columns from. *)
type ('list, 'fn, 'result, 'shape) t =
  | [] : (unit, 'result, 'result, unit) t
  | (::) : (string * ('a, 'n) Codec.t) * ('list, 'fn, 'result, 'shape) t ->
    ('a * 'list, 'a -> 'fn, 'result, ('a, 'n) Codec.slot * 'shape) t
let rec names : type l f r s. (l, f, r, s) t -> string list = function
  | [] -> []
  | (name, _) :: columns -> name :: names columns
