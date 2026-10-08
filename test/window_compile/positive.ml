(* Every accepted window form compiles. *)
module D = Duckdb
module S = D.Sql
let sales = D.Table.(declare "sales" Columns.["k", string; "d", int32; "v", int64; "n", nullable int64]
  ~row:(fun k d v n -> (k, d, v, n)))
let ranked : (unit, string * int64 * int64 option, D.Request.many) D.Request.t = S.(query Params.[] (fun [] ->
  from sales (fun [k; d; v; _] ->
    let w = window ~partition_by:[part k] ~order_by:[asc d] ~frame:(rows ~start:Unbounded_preceding ~end_:Current_row) () in
    select_over Exprs.[lift k; row_number w; Over.sum v w] ~row:(fun k r s -> (k, r, s))
      ~qualify:(row_number w <= int64 3L) ~order_by:[desc (row_number w)])))
let grouped = S.(query Params.[] (fun [] -> from sales (fun [k; _; v; _] ->
  group_by Keys.[k] (fun [k] ->
    select_over Exprs.[lift k; rank (window ~order_by:[desc (sum v)] ())] ~row:(fun k r -> (k, r))))))
let offsets = S.(query Params.[] (fun [] -> from sales (fun [_; d; v; n] ->
  let w = window ~order_by:[asc d] () in
  select_over Exprs.[lag v w; lead_or ~default:(int64 0L) v w; Null.lag n w; nth_value 2 v w] ~row:(fun a b c e -> (a, b, c, e)))))
