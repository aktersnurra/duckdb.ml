module Make (E : sig type ('a, 'n) t end) = struct
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) E.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  type 'b fold = { g : 'a 'n. ('a, 'n) E.t -> 'b -> 'b }
  let rec fold : type l f r. (l, f, r) t -> init:'b -> 'b fold -> 'b = fun l ~init folder ->
    match l with [] -> init | x :: rest -> fold rest ~init:(folder.g x init) folder
  let length l = fold l ~init:0 { g = (fun _ n -> n + 1) }
end
