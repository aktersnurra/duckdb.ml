(* SQL semantics against an OCaml model: random rows and random typed
   expression trees, evaluated by DuckDB and by a three-valued evaluator. *)
open! Base
open Prop_support
module T = D.Table
module S = D.Sql

(* Integer and boolean expressions over nullable columns a, b (BIGINT), s
   (VARCHAR) and p (BOOLEAN). Leaves are small and trees shallow, so no
   arithmetic overflows. *)
type int_expr =
  | A | B
  | Literal of int64
  | Add of int_expr * int_expr | Sub of int_expr * int_expr | Mul of int_expr * int_expr
  | Div of int_expr * int_expr
  | Coalesce of int_expr * int64
type bool_expr =
  | P
  | Compare of string * int_expr * int_expr
  | And of bool_expr * bool_expr | Or of bool_expr * bool_expr | Not of bool_expr
  | Is_null of int_expr
  | Is_true of bool_expr
  | Like of string
let rec show_int = function
  | A -> "a" | B -> "b" | Literal v -> Int64.to_string v
  | Add (x, y) -> "(" ^ show_int x ^ " + " ^ show_int y ^ ")"
  | Sub (x, y) -> "(" ^ show_int x ^ " - " ^ show_int y ^ ")"
  | Mul (x, y) -> "(" ^ show_int x ^ " * " ^ show_int y ^ ")"
  | Div (x, y) -> "(" ^ show_int x ^ " // " ^ show_int y ^ ")"
  | Coalesce (x, d) -> "coalesce(" ^ show_int x ^ ", " ^ Int64.to_string d ^ ")"
let rec show_bool = function
  | P -> "p"
  | Compare (op, x, y) -> "(" ^ show_int x ^ " " ^ op ^ " " ^ show_int y ^ ")"
  | And (x, y) -> "(" ^ show_bool x ^ " AND " ^ show_bool y ^ ")"
  | Or (x, y) -> "(" ^ show_bool x ^ " OR " ^ show_bool y ^ ")"
  | Not x -> "NOT " ^ show_bool x
  | Is_null x -> show_int x ^ " IS NULL"
  | Is_true x -> show_bool x ^ " IS TRUE"
  | Like pattern -> "coalesce(s, '') LIKE '" ^ pattern ^ "'"

let small tc = Int64.of_int (Hegel.draw ~label:"literal" tc (Hegel.integers ~min_value:(-30) ~max_value:30 ()))
let rec draw_int tc depth =
  let leaf = Hegel.draw ~label:"int node" tc (Hegel.integers ~min_value:0 ~max_value:(if depth = 0 then 2 else 7) ()) in
  match leaf with
  | 0 -> A | 1 -> B | 2 -> Literal (small tc)
  | 3 -> Add (draw_int tc (depth - 1), draw_int tc (depth - 1))
  | 4 -> Sub (draw_int tc (depth - 1), draw_int tc (depth - 1))
  | 5 -> Mul (draw_int tc (depth - 1), draw_int tc (depth - 1))
  | 6 -> Div (draw_int tc (depth - 1), draw_int tc (depth - 1))
  | _ -> Coalesce (draw_int tc (depth - 1), small tc)
let rec draw_bool tc depth =
  match Hegel.draw ~label:"bool node" tc (Hegel.integers ~min_value:0 ~max_value:(if depth = 0 then 2 else 7) ()) with
  | 0 -> P
  | 1 -> Is_null (draw_int tc 2)
  | 2 -> Like (Hegel.draw ~label:"pattern" tc (Hegel.text ~alphabet:"ab%_" ~max_size:4 ()))
  | 3 ->
    let op = Hegel.draw ~label:"operator" tc (Hegel.integers ~min_value:0 ~max_value:5 ()) in
    Compare (List.nth_exn [ "="; "<>"; "<"; "<="; ">"; ">=" ] op, draw_int tc 2, draw_int tc 2)
  | 4 -> And (draw_bool tc (depth - 1), draw_bool tc (depth - 1))
  | 5 -> Or (draw_bool tc (depth - 1), draw_bool tc (depth - 1))
  | 6 -> Not (draw_bool tc (depth - 1))
  | _ -> Is_true (draw_bool tc (depth - 1))

(* The model: NULL is None, three-valued AND/OR/NOT, // truncating toward
   zero with NULL for a zero divisor, LIKE with % and _. *)
type row = { a : int64 option; b : int64 option; s : string option; p : bool option }
let rec eval_int r = function
  | A -> r.a | B -> r.b | Literal v -> Some v
  | Add (x, y) -> Option.map2 (eval_int r x) (eval_int r y) ~f:Int64.( + )
  | Sub (x, y) -> Option.map2 (eval_int r x) (eval_int r y) ~f:Int64.( - )
  | Mul (x, y) -> Option.map2 (eval_int r x) (eval_int r y) ~f:Int64.( * )
  | Div (x, y) ->
    (match eval_int r x, eval_int r y with
     | Some _, Some 0L -> None
     | Some x, Some y -> Some (Int64.( / ) x y)
     | _ -> None)
  | Coalesce (x, d) -> Some (Option.value (eval_int r x) ~default:d)
let rec like s p =
  match String.to_list s, String.to_list p with
  | _, [] -> String.is_empty s
  | _, '%' :: rest -> like s (String.of_list rest) || (not (String.is_empty s) && like (String.drop_prefix s 1) p)
  | c :: cs, q :: qs when Char.equal q '_' || Char.equal q c -> like (String.of_list cs) (String.of_list qs)
  | _ -> false
let rec eval_bool r = function
  | P -> r.p
  | Compare (op, x, y) ->
    Option.map2 (eval_int r x) (eval_int r y) ~f:(fun x y ->
      let c = Int64.compare x y in
      match op with "=" -> c = 0 | "<>" -> c <> 0 | "<" -> c < 0 | "<=" -> c <= 0 | ">" -> c > 0 | _ -> c >= 0)
  | And (x, y) ->
    (match eval_bool r x, eval_bool r y with
     | Some false, _ | _, Some false -> Some false
     | Some true, Some true -> Some true
     | _ -> None)
  | Or (x, y) ->
    (match eval_bool r x, eval_bool r y with
     | Some true, _ | _, Some true -> Some true
     | Some false, Some false -> Some false
     | _ -> None)
  | Not x -> Option.map (eval_bool r x) ~f:not
  | Is_null x -> Some (Option.is_none (eval_int r x))
  | Is_true x -> Some (Option.equal Bool.equal (eval_bool r x) (Some true))
  | Like pattern -> Some (like (Option.value r.s ~default:"") pattern)

(* The same trees as typed expressions. *)
let rec typed_int a b = function
  | A -> a | B -> b | Literal v -> S.(nullable (int64 v))
  | Add (x, y) -> S.Null.(typed_int a b x + typed_int a b y)
  | Sub (x, y) -> S.Null.(typed_int a b x - typed_int a b y)
  | Mul (x, y) -> S.Null.(typed_int a b x * typed_int a b y)
  | Div (x, y) -> S.Null.(typed_int a b x / typed_int a b y)
  | Coalesce (x, d) -> S.(nullable (coalesce (typed_int a b x) ~default:(int64 d)))
let rec typed_bool ((a, b, s, p) as columns) = function
  | P -> p
  | Compare (op, x, y) ->
    let x = typed_int a b x and y = typed_int a b y in
    S.Null.(match op with "=" -> x = y | "<>" -> x <> y | "<" -> x < y | "<=" -> x <= y | ">" -> x > y | _ -> x >= y)
  | And (x, y) -> S.Null.(typed_bool columns x && typed_bool columns y)
  | Or (x, y) -> S.Null.(typed_bool columns x || typed_bool columns y)
  | Not x -> S.Null.not (typed_bool columns x)
  | Is_null x -> S.(nullable (is_null (typed_int a b x)))
  | Is_true x -> S.(nullable (is_true (typed_bool columns x)))
  | Like pattern -> S.(nullable (like (coalesce s ~default:(string "")) (string pattern)))

let cells = T.(declare "cells" Columns.["id", int64; "a", nullable int64; "b", nullable int64; "s", nullable string; "p", nullable bool]
  ~row:(fun id a b s p -> (id, a, b, s, p)))
let () = exec "CREATE TABLE cells(id BIGINT NOT NULL, a BIGINT, b BIGINT, s VARCHAR, p BOOLEAN)"

let draw_row tc =
  let value () = Hegel.draw ~label:"cell" tc (Hegel.optional (Hegel.integers ~min_value:(-30) ~max_value:30 ())) in
  let a = Option.map (value ()) ~f:Int64.of_int and b = Option.map (value ()) ~f:Int64.of_int in
  let s = Hegel.draw ~label:"s" tc (Hegel.optional (Hegel.text ~alphabet:"ab" ~max_size:3 ())) in
  let p = Hegel.draw ~label:"p" tc (Hegel.optional (Hegel.booleans ())) in
  { a; b; s; p }
let insert = R.exec D.Fields.[int64; nullable int64; nullable int64; nullable string; nullable bool]
  "INSERT INTO cells VALUES (?, ?, ?, ?, ?)"

let () =
  let c = Lazy.force connection in
  property "expressions match the three-valued model" (fun tc ->
    let rows = List.init (Hegel.draw ~label:"rows" tc (Hegel.integers ~min_value:0 ~max_value:6 ())) ~f:(fun _ -> draw_row tc) in
    let i = draw_int tc 3 and b = draw_bool tc 3 in
    Hegel.note tc ("int: " ^ show_int i);
    Hegel.note tc ("bool: " ^ show_bool b);
    exec "DELETE FROM cells";
    List.iteri rows ~f:(fun id r ->
      ok (R.Session.exec c insert D.Args.[Int64.of_int id; r.a; r.b; r.s; r.p]));
    let q = S.(query Params.[] (fun [] -> from cells (fun [id; a; bc; s; p] ->
      select Exprs.[typed_int a bc i; typed_bool (a, bc, s, p) b] ~row:(fun x y -> (x, y)) ~order_by:[asc id]))) in
    let actual = ok (R.Session.collect c q D.Args.[]) in
    let expected = List.map rows ~f:(fun r -> (eval_int r i, eval_bool r b)) in
    if not (List.equal (fun (x, y) (x', y') -> Option.equal Int64.equal x x' && Option.equal Bool.equal y y') actual expected)
    then failwith "DuckDB and the model differ")
