include Codec.Values
type ('list, 'fn, 'result) t =
  | [] : (unit, 'result, 'result) t
  | (::) : (string * ('a, _) Codec.t) * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
