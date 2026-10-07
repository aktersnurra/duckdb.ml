open! Base

type row = private Row_kind
type grouped = private Grouped_kind

(* Expressions are untyped nodes; the phantom indices live in the interface.
   Columns and parameters carry the scope (one [from] or [query] call) that
   bound them, so an expression smuggled into another query is rejected
   instead of binding that query's same-named column or same-numbered
   parameter. *)
type node =
  | Column of { scope : int; name : string }
  | Param of { scope : int; index : int; sql_type : string }
  (* [constant]: the value as a quoted SQL string constant, which DuckDB casts
     to a column's type; used where only constants are accepted. *)
  | Literal of { sql : string; constant : string }
  | Apply of string * node list
  | Infix of string * node * node
  | Prefix of string * node
  | Postfix of node * string
  | Cast of node * string
  | Count_star

let next_scope = Stdlib.Atomic.make 0
let fresh_scope () = Stdlib.Atomic.fetch_and_add next_scope 1
let foreign () = invalid_arg "Duckdb.Sql: an expression from another query"
(* [qualifier] prefixes column names: ["t0."] in queries, [""] in a table's
   own CHECK and DEFAULT clauses. *)
let rec render ?(qualifier = "t0.") ~columns ~params node =
  let render = render ~qualifier ~columns ~params in
  match node with
  | Column { scope; name } -> if scope <> columns then foreign () else qualifier ^ Request.quote name
  | Param { scope; index; sql_type } ->
    if scope <> params then foreign () else Printf.sprintf "CAST($%d AS %s)" index sql_type
  | Literal { sql; _ } -> sql
  | Apply (name, args) -> name ^ "(" ^ String.concat ~sep:", " (List.map args ~f:render) ^ ")"
  | Infix (op, a, b) -> "(" ^ render a ^ " " ^ op ^ " " ^ render b ^ ")"
  | Prefix (op, a) -> "(" ^ op ^ " " ^ render a ^ ")"
  | Postfix (a, op) -> "(" ^ render a ^ " " ^ op ^ ")"
  | Cast (a, sql_type) -> "CAST(" ^ render a ^ " AS " ^ sql_type ^ ")"
  | Count_star -> "count(*)"
(* The column names a node mentions, without duplicates. *)
let mentioned node =
  let rec go acc = function
    | Column { name; _ } -> if List.mem acc name ~equal:String.equal then acc else name :: acc
    | Param _ | Literal _ | Count_star -> acc
    | Apply (_, args) -> List.fold args ~init:acc ~f:go
    | Infix (_, a, b) -> go (go acc a) b
    | Prefix (_, a) | Postfix (a, _) | Cast (a, _) -> go acc a in
  List.rev (go [] node)

(* The SQL type a codec crosses the native boundary as. *)
let sql_type : type a n. (a, n) Codec.t -> string = fun codec ->
  let (Codec.Packed_scalar scalar) = match codec with
    | Codec.Non_null plan -> Codec.plan_scalar plan
    | Codec.Nullable plan -> Codec.plan_scalar plan in
  Scalar.name scalar

type ('a, 'n, 'k) expr = { node : node; codec : ('a, 'n) Codec.t }
(* A declared table column, as table constraints bind it. *)
type ('a, 'n) column = { scope : int; name : string; codec : ('a, 'n) Codec.t }
let column (c : (_, _) column) = { node = Column { scope = c.scope; name = c.name }; codec = c.codec }
type ('a, 'n) param = { scope : int; index : int; codec : ('a, 'n) Codec.t }
type 'k order = { key : node; descending : bool }

module Params = struct
  include Codec.Values
  type ('list, 'shape) t =
    | [] : (unit, unit) t
    | (::) : ('a, 'n) Codec.t * ('list, 'shape) t -> ('a * 'list, ('a, 'n) Codec.slot * 'shape) t
end
module Bound = struct
  type 'shape t =
    | [] : unit t
    | (::) : ('a, 'n) param * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
end
module Binders = struct
  type ('shape, 'k) t =
    | [] : (unit, 'k) t
    | (::) : ('a, 'n, 'k) expr * ('shape, 'k) t -> (('a, 'n) Codec.slot * 'shape, 'k) t
end
module Keys = struct
  type 'shape t =
    | [] : unit t
    | (::) : ('a, 'n, row) expr * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
end
module Exprs = struct
  type ('list, 'fn, 'result, 'k) t =
    | [] : (unit, 'result, 'result, 'k) t
    | (::) : ('a, _, 'k) expr * ('list, 'fn, 'result, 'k) t -> ('a * 'list, 'a -> 'fn, 'result, 'k) t
end

type ('row, 'k, 'm) body =
  Body : { columns : (_, 'fn, 'row) Fields.t; row : 'fn; list : node list; where : node option;
           group_by : node list; having : node option; order_by : 'k order list;
           limit : int option; offset : int option } -> ('row, 'k, 'm) body
type ('row, 'm) source = { target : string; scope : int; body : ('row, row, 'm) body }

let rec fields_of_exprs : type l f r k. (l, f, r, k) Exprs.t -> (l, f, r) Fields.t = function
  | Exprs.[] -> Fields.[]
  | Exprs.(e :: rest) -> Fields.(e.codec :: fields_of_exprs rest)
let rec nodes_of_exprs : type l f r k. (l, f, r, k) Exprs.t -> node list = function
  | Exprs.[] -> []
  | Exprs.(e :: rest) -> e.node :: nodes_of_exprs rest
let body exprs ~row ~where ~group_by ~having ~order_by ~limit ~offset =
  Body { columns = fields_of_exprs exprs; row; list = nodes_of_exprs exprs;
         where = Option.map where ~f:(fun (e : _ expr) -> e.node); group_by;
         having = Option.map having ~f:(fun (e : _ expr) -> e.node); order_by; limit; offset }

let select ?where ?having ?(order_by = []) ?limit ?offset exprs ~row =
  body exprs ~row ~where ~group_by:[] ~having ~order_by ~limit ~offset
(* Whether a node computes an aggregate. A select list of only literals and
   parameters has no GROUP BY and no aggregate, so it would return a row per
   table row. *)
let rec aggregates = function
  | Count_star -> true
  | Apply (("count" | "sum" | "min" | "max" | "avg"), _) -> true
  | Apply (_, args) -> List.exists args ~f:aggregates
  | Infix (_, a, b) -> aggregates a || aggregates b
  | Prefix (_, a) | Postfix (a, _) | Cast (a, _) -> aggregates a
  | Column _ | Param _ | Literal _ -> false
let aggregate ?where exprs ~row =
  if not (List.exists (nodes_of_exprs exprs) ~f:aggregates) then
    invalid_arg "Duckdb.Sql.aggregate: the select list needs an aggregate";
  body exprs ~row ~where ~group_by:[] ~having:None ~order_by:[] ~limit:None ~offset:None
let rec key_nodes : type s. s Keys.t -> node list = function
  | Keys.[] -> []
  | Keys.(k :: rest) -> k.node :: key_nodes rest
let rec rebind : type s. s Keys.t -> (s, grouped) Binders.t = function
  | Keys.[] -> Binders.[]
  | Keys.(k :: rest) -> Binders.({ node = k.node; codec = k.codec } :: rebind rest)
let group_by keys f =
  let (Body b) = f (rebind keys) in
  Body { columns = b.columns; row = b.row; list = b.list; where = b.where; group_by = key_nodes keys;
         having = b.having; order_by = List.map b.order_by ~f:(fun o -> { key = o.key; descending = o.descending });
         limit = b.limit; offset = b.offset }

let rec binders : type l f r s. (l, f, r, s) Columns.t -> scope:int -> (s, row) Binders.t = fun columns ~scope ->
  match columns with
  | Columns.[] -> Binders.[]
  | Columns.((name, codec) :: rest) ->
    Binders.({ node = Column { scope; name }; codec } :: binders rest ~scope)
let from (Request.Table_def t : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  { target = Request.quote t.schema ^ "." ^ Request.quote t.name; scope; body = f (binders t.columns ~scope) }

type 'l packed_fields = Packed_fields : ('l, _, _) Fields.t -> 'l packed_fields
let rec fields_of_params : type l s. (l, s) Params.t -> l packed_fields = function
  | Params.[] -> Packed_fields Fields.[]
  | Params.(codec :: rest) ->
    let (Packed_fields fields) = fields_of_params rest in
    Packed_fields Fields.(codec :: fields)
let rec bound : type l s. (l, s) Params.t -> scope:int -> index:int -> s Bound.t = fun params ~scope ~index ->
  match params with
  | Params.[] -> Bound.[]
  | Params.(codec :: rest) -> Bound.({ scope; index; codec } :: bound rest ~scope ~index:(index + 1))

let render_select ~target ~columns ~params (Body b) =
  let render = render ~columns ~params in
  let clause keyword = function None -> "" | Some node -> " " ^ keyword ^ " " ^ render node in
  let listed nodes = String.concat ~sep:", " (List.map nodes ~f:render) in
  let group_by = match b.group_by with [] -> "" | keys -> " GROUP BY " ^ listed keys in
  let order_by = match b.order_by with
    | [] -> ""
    | orders -> " ORDER BY " ^ String.concat ~sep:", " (List.map orders ~f:(fun o ->
        render o.key ^ if o.descending then " DESC" else " ASC")) in
  let number keyword = function None -> "" | Some n -> " " ^ keyword ^ " " ^ Int.to_string n in
  "SELECT " ^ listed b.list ^ " FROM " ^ target ^ " AS t0" ^ clause "WHERE" b.where ^ group_by
  ^ clause "HAVING" b.having ^ order_by ^ number "LIMIT" b.limit ^ number "OFFSET" b.offset

let query params f =
  let (Packed_fields fields) = fields_of_params params in
  let scope = fresh_scope () in
  let { target; scope = columns; body = Body b as body } = f (bound params ~scope ~index:1) in
  Request.generated fields b.columns ~row:b.row (render_select ~target ~columns ~params:scope body)

(* Expressions. *)
let param (p : (_, _) param) =
  { node = Param { scope = p.scope; index = p.index; sql_type = sql_type p.codec }; codec = p.codec }
let asc (e : _ expr) = { key = e.node; descending = false }
let desc (e : _ expr) = { key = e.node; descending = true }

let literal codec ~sql ~constant = { node = Literal { sql; constant }; codec }
let quote_string s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"
(* [text] is a SQL numeric literal or a quoted string; the constant spelling
   quotes it. *)
let typed codec scalar text =
  let constant = if String.is_prefix text ~prefix:"'" then text else quote_string text in
  literal codec ~sql:(Printf.sprintf "CAST(%s AS %s)" text (Scalar.name scalar)) ~constant
(* Doubles print with enough digits to round-trip; DuckDB parses the
   non-finite spellings from strings. *)
let float_text f =
  if Float.is_nan f then "'nan'"
  else if Float.is_inf f then if Float.(f > 0.) then "'inf'" else "'-inf'"
  else "'" ^ Printf.sprintf "%.17g" f ^ "'"
let bool b = literal Codec.Values.bool ~sql:(if b then "TRUE" else "FALSE") ~constant:(if b then "'true'" else "'false'")
let int8 v = typed Codec.Values.int8 Scalar.Int8 (Int.to_string (Stdlib_stable.Int8.to_int v))
let int16 v = typed Codec.Values.int16 Scalar.Int16 (Int.to_string (Stdlib_stable.Int16.to_int v))
let int32 v = typed Codec.Values.int32 Scalar.Int32 (Int32.to_string v)
let int64 v = typed Codec.Values.int64 Scalar.Int64 (Int64.to_string v)
let float32 v = typed Codec.Values.float32 Scalar.Float32 (float_text (Stdlib_stable.Float32.to_float v))
let float64 v = typed Codec.Values.float64 Scalar.Float64 (float_text v)
let string s = let q = quote_string s in literal Codec.Values.string ~sql:q ~constant:q

(* The operands of one operator must cross the boundary the same way: the
   same base scalar, and the same conversion. Their OCaml types cannot tell a
   BLOB from a VARCHAR, or a custom codec's column from a plain literal of its
   OCaml type; DuckDB would compare them after an implicit cast (a string
   literal against a BLOB has its \xHH escapes decoded) or unencoded. A
   custom codec matches only itself (the same codec value). *)
let compatible : type a n. (a, n) Codec.t -> (a, n) Codec.t -> bool = fun a b ->
  let same : type x. x Codec.plan -> x Codec.plan -> bool = fun p q ->
    match p, q with
    | Codec.Identity s, Codec.Identity t -> String.equal (Scalar.name s) (Scalar.name t)
    | Codec.Plan _, Codec.Plan _ -> phys_equal p q
    | _ -> false in
  match a, b with
  | Codec.Non_null p, Codec.Non_null q -> same p q
  | Codec.Nullable p, Codec.Nullable q -> same p q
let checked (a : _ expr) (b : _ expr) =
  if not (compatible a.codec b.codec) then
    invalid_arg "Duckdb.Sql: operands of different codecs (base types, or a custom codec and a plain value)"

let nullable (e : (_, Codec.non_null, _) expr) = { node = e.node; codec = Codec.Values.nullable e.codec }
let coalesce (e : _ expr) ~(default : _ expr) =
  if not (compatible e.codec (Codec.Values.nullable default.codec)) then
    invalid_arg "Duckdb.Sql: operands of different codecs (base types, or a custom codec and a plain value)";
  { node = Apply ("coalesce", [e.node; default.node]); codec = default.codec }
let is_null (e : _ expr) = { node = Postfix (e.node, "IS NULL"); codec = Codec.Values.bool }
let is_true (e : _ expr) = { node = Postfix (e.node, "IS TRUE"); codec = Codec.Values.bool }
let like (a : _ expr) (b : _ expr) = checked a b; { node = Infix ("LIKE", a.node, b.node); codec = Codec.Values.bool }

let count_star = { node = Count_star; codec = Codec.Values.int64 }
let count (e : _ expr) = { node = Apply ("count", [e.node]); codec = Codec.Values.int64 }
let extreme name (e : (_, Codec.non_null, _) expr) = { node = Apply (name, [e.node]); codec = Codec.Values.nullable e.codec }
let null_extreme name (e : (_, Codec.nullable, _) expr) = { node = Apply (name, [e.node]); codec = e.codec }

(* Arithmetic keeps the operand type: results are cast back to it. *)
let arith op (a : _ expr) (b : _ expr) = checked a b; { node = Cast (Infix (op, a.node, b.node), sql_type a.codec); codec = a.codec }
let null_division op (a : (_, Codec.non_null, _) expr) (b : _ expr) =
  checked a b; { node = Cast (Infix (op, a.node, b.node), sql_type a.codec); codec = Codec.Values.nullable a.codec }
let sum (e : (_, Codec.non_null, _) expr) =
  { node = Cast (Apply ("sum", [e.node]), sql_type e.codec); codec = Codec.Values.nullable e.codec }
let null_sum (e : (_, Codec.nullable, _) expr) = { node = Cast (Apply ("sum", [e.node]), sql_type e.codec); codec = e.codec }
let avg (e : _ expr) = { node = Cast (Apply ("avg", [e.node]), "DOUBLE"); codec = Codec.Values.(nullable float64) }

(* Arithmetic signatures, constrained per type by [I64] … [F32]. *)
module type INTEGRAL = sig
  type t
  val ( + ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( - ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( * ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( / ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t option, Codec.nullable, 'k) expr
  val sum : (t, Codec.non_null, row) expr -> (t option, Codec.nullable, grouped) expr
  val avg : (t, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
  module Null : sig
    val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
  end
end

(** As [INTEGRAL], but [/] is IEEE division (a zero divisor gives an infinity or NaN). *)
module type FRACTIONAL = sig
  type t
  val ( + ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( - ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( * ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( / ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val sum : (t, Codec.non_null, row) expr -> (t option, Codec.nullable, grouped) expr
  val avg : (t, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
  module Null : sig
    val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
  end
end
module Integral = struct
  let ( + ) a b = arith "+" a b
  let ( - ) a b = arith "-" a b
  let ( * ) a b = arith "*" a b
  (* DuckDB's integer division; a zero divisor yields NULL. *)
  let ( / ) a b = null_division "//" a b
  let sum = sum
  let avg = avg
  module Null = struct
    let ( + ) a b = arith "+" a b
    let ( - ) a b = arith "-" a b
    let ( * ) a b = arith "*" a b
    let ( / ) a b = arith "//" a b
    let sum = null_sum
    let avg = avg
  end
end
module Fractional = struct
  let ( + ) a b = arith "+" a b
  let ( - ) a b = arith "-" a b
  let ( * ) a b = arith "*" a b
  let ( / ) a b = arith "/" a b
  let sum = sum
  let avg = avg
  module Null = struct
    let ( + ) a b = arith "+" a b
    let ( - ) a b = arith "-" a b
    let ( * ) a b = arith "*" a b
    let ( / ) a b = arith "/" a b
    let sum = null_sum
    let avg = avg
  end
end
module I64 = Integral
module I32 = Integral
module I16 = Integral
module I8 = Integral
module F64 = Fractional
module F32 = Fractional

(* Defined last: these shadow Base's operators. *)
let compare op (a : _ expr) (b : _ expr) = checked a b; { node = Infix (op, a.node, b.node); codec = Codec.Values.bool }
let null_compare op (a : _ expr) (b : _ expr) =
  checked a b;
  { node = Infix (op, a.node, b.node); codec = Codec.Values.(nullable bool) }
let ( = ) a b = compare "=" a b
let ( <> ) a b = compare "<>" a b
let ( < ) a b = compare "<" a b
let ( <= ) a b = compare "<=" a b
let ( > ) a b = compare ">" a b
let ( >= ) a b = compare ">=" a b
let ( && ) a b = compare "AND" a b
let ( || ) a b = compare "OR" a b
let not (e : _ expr) = { node = Prefix ("NOT", e.node); codec = e.codec }
let min e = extreme "min" e
let max e = extreme "max" e
let ( + ) = I64.( + )
let ( - ) = I64.( - )
let ( * ) = I64.( * )
let ( / ) = I64.( / )
let sum = I64.sum
let avg = I64.avg
let ( +. ) = F64.( + )
let ( -. ) = F64.( - )
let ( *. ) = F64.( * )
let ( /. ) = F64.( / )
module Null = struct
  let ( = ) a b = null_compare "=" a b
  let ( <> ) a b = null_compare "<>" a b
  let ( < ) a b = null_compare "<" a b
  let ( <= ) a b = null_compare "<=" a b
  let ( > ) a b = null_compare ">" a b
  let ( >= ) a b = null_compare ">=" a b
  let ( && ) a b = null_compare "AND" a b
  let ( || ) a b = null_compare "OR" a b
  let not (e : _ expr) = { node = Prefix ("NOT", e.node); codec = e.codec }
  let min e = null_extreme "min" e
  let max e = null_extreme "max" e
  let ( + ) = I64.Null.( + )
  let ( - ) = I64.Null.( - )
  let ( * ) = I64.Null.( * )
  let ( / ) = I64.Null.( / )
  let sum = I64.Null.sum
  let avg = I64.Null.avg
  let ( +. ) = F64.Null.( + )
  let ( -. ) = F64.Null.( - )
  let ( *. ) = F64.Null.( * )
  let ( /. ) = F64.Null.( / )
end
