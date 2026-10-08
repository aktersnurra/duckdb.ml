(* Query algebra against list operations over random tables. Results are
   compared sorted, or ordered by a unique key, never by DuckDB's row
   order. *)
open! Base
open Prop_support
module T = D.Table
module S = D.Sql

type item = { id : int64; k : int64; v : int64; n : int64 option }
let items = T.(declare "items" Columns.["id", int64; "k", int64; "v", int64; "n", nullable int64]
  ~row:(fun id k v n -> { id; k; v; n }))
type tag = { tid : int64; tk : int64; w : int64 }
let tags = T.(declare "tags" Columns.["tid", int64; "tk", int64; "w", int64] ~row:(fun tid tk w -> { tid; tk; w }))
let () =
  exec "CREATE TABLE items(id BIGINT NOT NULL, k BIGINT NOT NULL, v BIGINT NOT NULL, n BIGINT)";
  exec "CREATE TABLE tags(tid BIGINT NOT NULL, tk BIGINT NOT NULL, w BIGINT NOT NULL)"

let small tc label lo hi = Int64.of_int (Hegel.draw ~label tc (Hegel.integers ~min_value:lo ~max_value:hi ()))
let draw_items tc =
  List.init (Hegel.draw ~label:"items" tc (Hegel.integers ~min_value:0 ~max_value:8 ())) ~f:(fun i ->
    { id = Int64.of_int i; k = small tc "k" 0 3; v = small tc "v" (-5) 5;
      n = Option.map (Hegel.draw ~label:"n" tc (Hegel.optional (Hegel.integers ~min_value:(-5) ~max_value:5 ())))
            ~f:Int64.of_int })
let draw_tags tc =
  List.init (Hegel.draw ~label:"tags" tc (Hegel.integers ~min_value:0 ~max_value:6 ())) ~f:(fun i ->
    { tid = Int64.of_int i; tk = small tc "tk" 0 4; w = small tc "w" (-5) 5 })
let load c items_rows tags_rows =
  exec "DELETE FROM items";
  exec "DELETE FROM tags";
  ok (T.with_appender c items ~f:(fun a -> T.append a (List.map items_rows ~f:(fun r -> D.Args.[r.id; r.k; r.v; r.n]))));
  ok (T.with_appender c tags ~f:(fun a -> T.append a (List.map tags_rows ~f:(fun r -> D.Args.[r.tid; r.tk; r.w]))))
let expect name equal actual expected = if not (equal actual expected) then failwith (name ^ ": DuckDB and the lists differ")
let ints = List.equal Int64.equal
let sorted = List.sort ~compare:Poly.compare

(* Built once: their cached statements are reused across cases and data
   (DuckDB's stale-statistics bug showed why that path needs covering). *)
let distinct = S.(query Params.[] (fun [] -> from items (fun [_; k; _; _] -> select Exprs.[k] ~distinct:true ~row:Fn.id)))
let grouped = S.(query Params.[] (fun [] -> from items (fun [_; k; v; n] ->
  group_by Keys.[k] (fun [k] ->
    select Exprs.[k; count_star; count n; sum v; min v; max v; Null.max n; avg v]
      ~row:(fun k c cn s lo hi hn a -> (k, c, cn, s, lo, hi, hn, a)) ~order_by:[asc k]))))
let inner = S.(query Params.[] (fun [] -> from items (fun [id; k; _; _] ->
  join tags ~on:(fun [_; tk; _] -> tk = k) (fun [tid; _; _] -> select Exprs.[id; tid] ~row:(fun a b -> (a, b))))))
let left = S.(query Params.[] (fun [] -> from items (fun [id; k; _; _] ->
  left_join tags ~on:(fun [_; tk; _] -> tk = k) (fun [tid; _; _] ->
    select Exprs.[id; outer tid] ~row:(fun a b -> (a, b))))))
let values_of = S.(from items (fun [_; _; v; _] -> select Exprs.[v] ~row:Fn.id))
let weights_of = S.(from tags (fun [_; _; w] -> select Exprs.[w] ~row:Fn.id))
let set_queries = S.[ ("union all", query Params.[] (fun [] -> union_all values_of weights_of));
                      ("union", query Params.[] (fun [] -> union values_of weights_of));
                      ("intersect", query Params.[] (fun [] -> intersect values_of weights_of));
                      ("except", query Params.[] (fun [] -> except_ values_of weights_of)) ]

let ordered = S.(query Params.[] (fun [] -> from items (fun [id; _; v; _] ->
  select Exprs.[id; v] ~row:(fun a b -> (a, b)) ~order_by:[asc id])))

let () =
  let c = Lazy.force connection in
  (* One cached statement over data of any range: DuckDB's compressed
     materialization, if enabled, corrupts values outside the statistics
     seen when the statement was prepared. *)
  property "a cached ordered select over changing data" (fun tc ->
    let rows = List.init (Hegel.draw ~label:"items" tc (Hegel.integers ~min_value:0 ~max_value:8 ())) ~f:(fun i ->
      { id = Int64.of_int i; k = 0L; v = Hegel.draw ~label:"v" tc int64s; n = None }) in
    load c rows [];
    expect "ordered" (List.equal Poly.equal) (ok (R.Session.collect c ordered D.Args.[]))
      (List.map rows ~f:(fun r -> (r.id, r.v))));
  property "where, order by, limit, offset" (fun tc ->
    let rows = draw_items tc in
    load c rows [];
    let threshold = small tc "threshold" (-6) 6 in
    let limit = Hegel.draw ~label:"limit" tc (Hegel.integers ~min_value:0 ~max_value:9 ()) in
    let offset = Hegel.draw ~label:"offset" tc (Hegel.integers ~min_value:0 ~max_value:9 ()) in
    let q = S.(query Params.[int64] (fun [t] -> from items (fun [id; _; v; _] ->
      select Exprs.[id] ~row:Fn.id ~where:(v >= param t) ~order_by:[desc v; asc id] ~limit ~offset))) in
    let expected = rows
      |> List.filter ~f:(fun r -> Int64.(r.v >= threshold))
      |> List.sort ~compare:(fun a b -> match Int64.compare b.v a.v with 0 -> Int64.compare a.id b.id | c -> c)
      |> (fun l -> List.drop l offset) |> (fun l -> List.take l limit)
      |> List.map ~f:(fun r -> r.id) in
    expect "filtered" ints (ok (R.Session.collect c q D.Args.[threshold])) expected);
  property "distinct" (fun tc ->
    let rows = draw_items tc in
    load c rows [];
    expect "distinct" ints (sorted (ok (R.Session.collect c distinct D.Args.[])))
      (List.dedup_and_sort (List.map rows ~f:(fun r -> r.k)) ~compare:Int64.compare));
  property "group by with aggregates" (fun tc ->
    let rows = draw_items tc in
    load c rows [];
    let expected = rows
      |> List.map ~f:(fun r -> r.k) |> List.dedup_and_sort ~compare:Int64.compare
      |> List.map ~f:(fun k ->
        let group = List.filter rows ~f:(fun r -> Int64.equal r.k k) in
        let vs = List.map group ~f:(fun r -> r.v) and ns = List.filter_map group ~f:(fun r -> r.n) in
        (k, Int64.of_int (List.length group), Int64.of_int (List.length ns),
         Some (List.fold vs ~init:0L ~f:Int64.( + )), List.min_elt vs ~compare:Int64.compare,
         List.max_elt vs ~compare:Int64.compare, List.max_elt ns ~compare:Int64.compare,
         Some (Int64.to_float (List.fold vs ~init:0L ~f:Int64.( + )) /. Float.of_int (List.length vs)))) in
    let same (k, c, cn, s, lo, hi, hn, a) (k', c', cn', s', lo', hi', hn', a') =
      Int64.equal k k' && Int64.equal c c' && Int64.equal cn cn' && Poly.equal (s, lo, hi, hn) (s', lo', hi', hn')
      && Option.equal (fun x y -> Float.(abs (x - y) < 1e-9)) a a' in
    expect "grouped" (List.equal same) (ok (R.Session.collect c grouped D.Args.[])) expected);
  property "inner and left joins" (fun tc ->
    let rows = draw_items tc and tag_rows = draw_tags tc in
    load c rows tag_rows;
    let matches r = List.filter tag_rows ~f:(fun t -> Int64.equal t.tk r.k) in
    expect "inner" (List.equal Poly.equal) (sorted (ok (R.Session.collect c inner D.Args.[])))
      (sorted (List.concat_map rows ~f:(fun r -> List.map (matches r) ~f:(fun t -> (r.id, t.tid)))));
    expect "left" (List.equal Poly.equal) (sorted (ok (R.Session.collect c left D.Args.[])))
      (sorted (List.concat_map rows ~f:(fun r ->
         match matches r with
         | [] -> [ (r.id, None) ]
         | ts -> List.map ts ~f:(fun t -> (r.id, Some t.tid))))));
  property "union, union all, intersect, except" (fun tc ->
    let rows = draw_items tc and tag_rows = draw_tags tc in
    load c rows tag_rows;
    let vs = List.map rows ~f:(fun r -> r.v) and ws = List.map tag_rows ~f:(fun t -> t.w) in
    let run name = sorted (ok (R.Session.collect c (List.Assoc.find_exn set_queries name ~equal:String.equal) D.Args.[])) in
    let set l = List.dedup_and_sort l ~compare:Int64.compare in
    let mem l x = List.mem l x ~equal:Int64.equal in
    expect "union all" ints (run "union all") (sorted (vs @ ws));
    expect "union" ints (run "union") (set (vs @ ws));
    expect "intersect" ints (run "intersect") (set (List.filter vs ~f:(mem ws)));
    expect "except" ints (run "except") (set (List.filter vs ~f:(fun v -> not (mem ws v)))))
