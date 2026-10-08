open! Base

type row = private Row_kind
type grouped = private Grouped_kind
(* Window results over base kind ['k]: only a windowed select list, its
   QUALIFY and its ORDER BY accept them. *)
type 'k windowed = private Windowed_kind

(* Expressions are untyped nodes; the phantom indices live in the interface.
   Columns and parameters carry the scope (one [from] or [query] call) that
   bound them, so an expression smuggled into another query is rejected
   instead of binding that query's same-named column or same-numbered
   parameter. *)
type join_kind = Inner | Left | Cross
type node =
  | Column of { scope : int; name : string }
  | Param of { scope : int; index : int; sql_type : string }
  (* [constant]: the value as a quoted SQL string constant, which DuckDB casts
     to a column's type; used where only constants are accepted. Dates and
     timestamps have none: they are built by functions. *)
  | Literal of { sql : string; constant : string option }
  | Apply of string * node list
  | Infix of string * node * node
  | Prefix of string * node
  | Postfix of node * string
  | Cast of node * string
  | Count_star
  | Exists of packed_source
  | In_subquery of node * packed_source
  | Scalar of packed_source
  | Over of node * window_spec
(* A window: PARTITION BY, ORDER BY (key, descending) and a rendered frame. *)
and window_spec = { partition : node list; order : (node * bool) list; frame : string option }
(* A joined table: [on] is absent for a CROSS JOIN. *)
and join = { kind : join_kind; target : string; scope : int; on : node option }
and 'k order = { key : node; descending : bool }
(* A select: ['list] is its column value types, ['row] what a row decodes
   to, ['k] the select list's kind, ['m] the multiplicity. *)
and ('list, 'row, 'k, 'm) body =
  Body : { columns : ('list, 'fn, 'row) Fields.t; row : 'fn; list : node list; distinct : bool;
           joins : join list; where : node option;
           group_by : node list; having : node option; qualify : node option; order_by : 'k order list;
           limit : int option; offset : int option } -> ('list, 'row, 'k, 'm) body
(* Rows decode with the left-most select's row function. *)
and ('list, 'row, 'm) source =
  | Select : { target : string; scope : int; body : ('list, 'row, row, 'm) body } -> ('list, 'row, 'm) source
  | Set : { op : string; left : ('list, 'row, _) source; right : ('list, 'row, _) source } -> ('list, 'row, 'm) source
and packed_source = Packed : (_, _, _) source -> packed_source

let next_scope = Stdlib.Atomic.make 0
let fresh_scope () = Stdlib.Atomic.fetch_and_add next_scope 1
let foreign () = invalid_arg "Duckdb.Sql: an expression from another query"
(* Rendering context: the alias of each table in scope (by binding scope),
   the parameters' scope, and the next free alias number. Aliases are
   numbered in order of appearance, so the text does not depend on scope
   ids. A table's own CHECK and DEFAULT clauses use the alias [""]: no
   qualifier. *)
type context = { aliases : (int * string) list; params : int; next : int ref }
let alias context =
  let n = !(context.next) in
  context.next := n + 1;
  "t" ^ Int.to_string n
(* The column names a node mentions, without duplicates. *)
let mentioned node =
  let rec go acc = function
    | Column { name; _ } -> if List.mem acc name ~equal:String.equal then acc else name :: acc
    (* A subquery's columns belong to its own tables. *)
    | Param _ | Literal _ | Count_star | Exists _ | In_subquery _ | Scalar _ -> acc
    | Over (f, w) -> List.fold (w.partition @ List.map w.order ~f:fst) ~init:(go acc f) ~f:go
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


let rec fields_of_exprs : type l f r k. (l, f, r, k) Exprs.t -> (l, f, r) Fields.t = function
  | Exprs.[] -> Fields.[]
  | Exprs.(e :: rest) -> Fields.(e.codec :: fields_of_exprs rest)
let rec nodes_of_exprs : type l f r k. (l, f, r, k) Exprs.t -> node list = function
  | Exprs.[] -> []
  | Exprs.(e :: rest) -> e.node :: nodes_of_exprs rest
let body ?(distinct = false) exprs ~row ~where ~group_by ~having ~order_by ~limit ~offset =
  Body { columns = fields_of_exprs exprs; row; list = nodes_of_exprs exprs; distinct; joins = [];
         where = Option.map where ~f:(fun (e : _ expr) -> e.node); group_by;
         having = Option.map having ~f:(fun (e : _ expr) -> e.node); qualify = None; order_by; limit; offset }

let select ?distinct ?where ?having ?(order_by = []) ?limit ?offset exprs ~row =
  let non_negative name = Option.iter ~f:(fun n ->
    if n < 0 then invalid_arg ("Duckdb.Sql.select: a negative " ^ name)) in
  non_negative "limit" limit;
  non_negative "offset" offset;
  body ?distinct exprs ~row ~where ~group_by:[] ~having ~order_by ~limit ~offset
(* Whether a node computes an aggregate. A select list of only literals and
   parameters has no GROUP BY and no aggregate, so it would return a row per
   table row. *)
let rec aggregates = function
  | Count_star -> true
  | Apply (("count" | "sum" | "min" | "max" | "avg"), _) -> true
  | Apply (_, args) -> List.exists args ~f:aggregates
  | Infix (_, a, b) -> aggregates a || aggregates b
  | Prefix (_, a) | Postfix (a, _) | Cast (a, _) -> aggregates a
  (* A window aggregate does not make the select an aggregate. *)
  | Column _ | Param _ | Literal _ | Exists _ | In_subquery _ | Scalar _ | Over _ -> false
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
  Body { columns = b.columns; row = b.row; list = b.list; distinct = b.distinct; joins = b.joins;
         where = b.where; group_by = key_nodes keys;
         having = b.having; qualify = b.qualify; order_by = List.map b.order_by ~f:(fun o -> { key = o.key; descending = o.descending });
         limit = b.limit; offset = b.offset }

let rec binders : type l f r s. (l, f, r, s) Columns.t -> scope:int -> (s, row) Binders.t = fun columns ~scope ->
  match columns with
  | Columns.[] -> Binders.[]
  | Columns.((name, codec) :: rest) ->
    Binders.({ node = Column { scope; name }; codec } :: binders rest ~scope)
let target_of (Request.Table_def t : (_, _, _) Request.table) = Request.quote t.schema ^ "." ^ Request.quote t.name
let from (Request.Table_def t as table : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  Select { target = target_of table; scope; body = f (binders t.columns ~scope) }

(* Joins prepend themselves to the body their callback builds; the joined
   rows multiply, so the result is [many]. *)
let joined kind table scope ~on (Body b : (_, _, _, _) body) : (_, _, _, _) body =
  Body { b with joins = { kind; target = target_of table; scope; on } :: b.joins }
let join (Request.Table_def t as table : (_, _, _) Request.table) ~on f =
  let scope = fresh_scope () in
  let condition = (on (binders t.columns ~scope)).node in
  joined Inner table scope ~on:(Some condition) (f (binders t.columns ~scope))
let cross_join (Request.Table_def t as table : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  joined Cross table scope ~on:None (f (binders t.columns ~scope))
(* A LEFT JOIN's right columns may be NULL-extended: its body sees them as
   [outer] values, which [outer]/[Null.outer] lift to nullable expressions. *)
type ('a, 'n) outer = Outer of ('a, 'n, row) expr [@@unboxed]
module Outer = struct
  type 'shape t =
    | [] : unit t
    | (::) : ('a, 'n) outer * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
end
let rec outer_binders : type l f r s. (l, f, r, s) Columns.t -> scope:int -> s Outer.t = fun columns ~scope ->
  match columns with
  | Columns.[] -> Outer.[]
  | Columns.((name, codec) :: rest) -> Outer.(Outer { node = Column { scope; name }; codec } :: outer_binders rest ~scope)
let left_join (Request.Table_def t as table : (_, _, _) Request.table) ~on f =
  let scope = fresh_scope () in
  let condition = (on (binders t.columns ~scope)).node in
  joined Left table scope ~on:(Some condition) (f (outer_binders t.columns ~scope))
let outer (Outer e : (_, Codec.non_null) outer) = { node = e.node; codec = Codec.Values.nullable e.codec }
let null_outer (Outer e : (_, Codec.nullable) outer) = e

(* A named column: a typed index into a table's shape. *)
type ('shape, 'a, 'n) field =
  | Here : (('a, 'n) Codec.slot * 'rest, 'a, 'n) field
  | Next : ('rest, 'a, 'n) field -> (_ * 'rest, 'a, 'n) field
module Named = struct
  type ('whole, 'rest) t =
    | [] : (_, unit) t
    | (::) : ('whole, 'a, 'n) field * ('whole, 'rest) t -> ('whole, ('a, 'n) Codec.slot * 'rest) t
end
let rec ( .%() ) : type s a n k. (s, k) Binders.t -> (s, a, n) field -> (a, n, k) expr = fun binders field ->
  match binders, field with
  | Binders.(e :: _), Here -> e
  | Binders.(_ :: rest), Next field -> rest.%(field)
  | Binders.[], _ -> .
let rec ( .%?() ) : type s a n. s Outer.t -> (s, a, n) field -> (a, n) outer = fun binders field ->
  match binders, field with
  | Outer.(e :: _), Here -> e
  | Outer.(_ :: rest), Next field -> rest.%?(field)
  | Outer.[], _ -> .

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

let join_keyword = function Inner -> "INNER JOIN" | Left -> "LEFT JOIN" | Cross -> "CROSS JOIN"
(* Pieces render in textual order (bound by [let]; [^] evaluates its right
   operand first), so subquery aliases number left to right. *)
let rec render context node =
  let render = render context in
  match node with
  | Column { scope; name } ->
    (match List.Assoc.find context.aliases scope ~equal:Int.equal with
     | None -> foreign ()
     | Some "" -> Request.quote name
     | Some alias -> alias ^ "." ^ Request.quote name)
  | Param { scope; index; sql_type } ->
    if scope <> context.params then foreign () else Printf.sprintf "CAST($%d AS %s)" index sql_type
  | Literal { sql; _ } -> sql
  | Apply (name, args) -> name ^ "(" ^ String.concat ~sep:", " (List.map args ~f:render) ^ ")"
  | Infix (op, a, b) -> let a = render a in let b = render b in "(" ^ a ^ " " ^ op ^ " " ^ b ^ ")"
  | Prefix (op, a) -> "(" ^ op ^ " " ^ render a ^ ")"
  | Postfix (a, op) -> "(" ^ render a ^ " " ^ op ^ ")"
  | Cast (a, sql_type) -> "CAST(" ^ render a ^ " AS " ^ sql_type ^ ")"
  | Count_star -> "count(*)"
  | Exists (Packed s) -> "EXISTS (" ^ render_source context s ^ ")"
  | In_subquery (a, Packed s) -> let a = render a in "(" ^ a ^ " IN (" ^ render_source context s ^ "))"
  | Scalar (Packed s) -> "(" ^ render_source context s ^ ")"
  | Over (f, w) ->
    let f = render f in
    let partition = match w.partition with
      | [] -> None
      | keys -> Some ("PARTITION BY " ^ String.concat ~sep:", " (List.map keys ~f:render)) in
    let order = match w.order with
      | [] -> None
      | keys -> Some ("ORDER BY " ^ String.concat ~sep:", " (List.map keys ~f:(fun (key, descending) ->
          render key ^ if descending then " DESC" else " ASC"))) in
    f ^ " OVER (" ^ String.concat ~sep:" " (List.filter_opt [ partition; order; w.frame ]) ^ ")"
(* Every table of the select is aliased before any expression renders, so
   subqueries continue the numbering after them. A subquery sees the
   enclosing tables' aliases (correlation). *)
and render_select : type l r k m. context -> target:string -> scope:int -> (l, r, k, m) body -> string =
  fun context ~target ~scope (Body b) ->
  let first = alias context in
  let joins = List.map b.joins ~f:(fun j -> (j, alias context)) in
  let context = { context with aliases = (scope, first) :: List.map joins ~f:(fun (j, a) -> (j.scope, a))
                                         @ context.aliases } in
  let render = render context in
  let clause keyword = function None -> "" | Some node -> " " ^ keyword ^ " " ^ render node in
  let listed nodes = String.concat ~sep:", " (List.map nodes ~f:render) in
  let number keyword = function None -> "" | Some n -> " " ^ keyword ^ " " ^ Int.to_string n in
  let list = listed b.list in
  let joined = String.concat (List.map joins ~f:(fun (j, a) ->
    " " ^ join_keyword j.kind ^ " " ^ j.target ^ " AS " ^ a ^ clause "ON" j.on)) in
  let where = clause "WHERE" b.where in
  let group_by = match b.group_by with [] -> "" | keys -> " GROUP BY " ^ listed keys in
  let having = clause "HAVING" b.having in
  let qualify = clause "QUALIFY" b.qualify in
  let order_by = match b.order_by with
    | [] -> ""
    | orders -> " ORDER BY " ^ String.concat ~sep:", " (List.map orders ~f:(fun o ->
        render o.key ^ if o.descending then " DESC" else " ASC")) in
  "SELECT " ^ (if b.distinct then "DISTINCT " else "") ^ list ^ " FROM " ^ target ^ " AS " ^ first
  ^ joined ^ where ^ group_by ^ having ^ qualify ^ order_by ^ number "LIMIT" b.limit ^ number "OFFSET" b.offset
and render_source : type l r m. context -> (l, r, m) source -> string = fun context -> function
  | Select { target; scope; body } -> render_select context ~target ~scope body
  | Set { op; left; right } ->
    let left = render_source context left in
    "(" ^ left ^ ") " ^ op ^ " (" ^ render_source context right ^ ")"
(* A table's CHECK or DEFAULT expression: its own columns, unqualified. *)
let render_bare ~scope node = render { aliases = [ (scope, "") ]; params = -1; next = ref 0 } node

type ('list, 'row) any_body = Any_body : ('list, 'row, row, _) body -> ('list, 'row) any_body
let rec leftmost : type l r m. (l, r, m) source -> (l, r) any_body = function
  | Select { body; _ } -> Any_body body
  | Set { left; _ } -> leftmost left
let query params f =
  let (Packed_fields fields) = fields_of_params params in
  let scope = fresh_scope () in
  let source = f (bound params ~scope ~index:1) in
  let (Any_body (Body b)) = leftmost source in
  let context = { aliases = []; params = scope; next = ref 0 } in
  Request.generated fields b.columns ~row:b.row (render_source context source)

(* Expressions. *)
let param (p : (_, _) param) =
  { node = Param { scope = p.scope; index = p.index; sql_type = sql_type p.codec }; codec = p.codec }
let asc (e : _ expr) = { key = e.node; descending = false }
let desc (e : _ expr) = { key = e.node; descending = true }

let quote_string s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"
(* [text] is a SQL numeric literal or a quoted string; the constant spelling
   quotes it. *)
let typed_node scalar text =
  let constant = if String.is_prefix text ~prefix:"'" then text else quote_string text in
  Literal { sql = Printf.sprintf "CAST(%s AS %s)" text (Scalar.name scalar); constant = Some constant }
let typed codec scalar text = { node = typed_node scalar text; codec }
(* Doubles print with enough digits to round-trip; DuckDB parses the
   non-finite spellings from strings. *)
let float_text f =
  if Float.is_nan f then "'nan'"
  else if Float.is_inf f then if Float.(f > 0.) then "'inf'" else "'-inf'"
  else "'" ^ Printf.sprintf "%.17g" f ^ "'"
let bool_node b = Literal { sql = (if b then "TRUE" else "FALSE"); constant = Some (if b then "'true'" else "'false'") }
let bool b = { node = bool_node b; codec = Codec.Values.bool }
let int8 v = typed Codec.Values.int8 Scalar.Int8 (Int.to_string (Stdlib_stable.Int8.to_int v))
let int16 v = typed Codec.Values.int16 Scalar.Int16 (Int.to_string (Stdlib_stable.Int16.to_int v))
let int32 v = typed Codec.Values.int32 Scalar.Int32 (Int32.to_string v)
let int64 v = typed Codec.Values.int64 Scalar.Int64 (Int64.to_string v)
let float32 v = typed Codec.Values.float32 Scalar.Float32 (float_text (Stdlib_stable.Float32.to_float v))
let float64 v = typed Codec.Values.float64 Scalar.Float64 (float_text v)
let string_node s = let q = quote_string s in Literal { sql = q; constant = Some q }
let string s = { node = string_node s; codec = Codec.Values.string }
(* Every byte escaped: DuckDB decodes \xNN in a string cast to BLOB. *)
let blob_node s =
  let q = "'" ^ String.concat_map s ~f:(fun c -> Printf.sprintf "\\x%02X" (Char.to_int c)) ^ "'" in
  Literal { sql = "CAST(" ^ q ^ " AS BLOB)"; constant = Some q }
(* Built from the epoch value; exact under any session time zone (casting a
   TIMESTAMP to TIMESTAMPTZ would read it as local time). *)
let function_node sql = Literal { sql; constant = None }
let scalar_node : type b. b Scalar.t -> b -> node = fun scalar v ->
  let int64 n = Printf.sprintf "CAST(%s AS BIGINT)" (Int64.to_string n) in
  match scalar with
  | Scalar.Bool -> bool_node v
  | Scalar.Int8 -> typed_node scalar (Int.to_string (Stdlib_stable.Int8.to_int v))
  | Scalar.Int16 -> typed_node scalar (Int.to_string (Stdlib_stable.Int16.to_int v))
  | Scalar.Int32 -> typed_node scalar (Int32.to_string v)
  | Scalar.Int64 -> typed_node scalar (Int64.to_string v)
  | Scalar.Float32 -> typed_node scalar (float_text (Stdlib_stable.Float32.to_float v))
  | Scalar.Float64 -> typed_node scalar (float_text v)
  | Scalar.String -> string_node v
  | Scalar.Blob -> blob_node v
  | Scalar.Date -> function_node (Printf.sprintf "CAST(DATE '1970-01-01' + CAST(%s AS INTEGER) AS DATE)" (Int32.to_string v))
  | Scalar.Timestamp_us -> function_node ("make_timestamp(" ^ int64 v ^ ")")
  | Scalar.Timestamp_ms -> function_node ("CAST(epoch_ms(" ^ int64 v ^ ") AS TIMESTAMP_MS)")
  | Scalar.Timestamp_s -> function_node ("CAST(make_timestamp(" ^ int64 v ^ " * 1000000) AS TIMESTAMP_S)")
  | Scalar.Timestamp_ns -> function_node ("make_timestamp_ns(" ^ int64 v ^ ")")
  | Scalar.Timestamp_tz -> function_node ("(to_timestamp(0) + to_microseconds(" ^ int64 v ^ "))")
let value (type a) (codec : (a, Codec.non_null) Codec.t) (v : a) =
  let (Codec.Non_null plan) = codec in
  let node = match plan with
    | Codec.Identity scalar -> scalar_node scalar v
    | Codec.Plan p ->
      match p.encode v with
      | Ok b -> scalar_node p.scalar b
      | Error e -> invalid_arg ("Duckdb.Sql.value: the codec rejected the value: " ^ Error.to_string_hum e) in
  { node; codec }

(* The operands of one operator must cross the boundary the same way: the
   same base scalar, and the same conversion. Their OCaml types cannot tell a
   BLOB from a VARCHAR, or a custom codec's column from a plain literal of its
   OCaml type; DuckDB would compare them after an implicit cast (a string
   literal against a BLOB has its \xHH escapes decoded) or unencoded. A
   custom codec matches only itself (the same codec value). *)
let compatible : type a n m. (a, n) Codec.t -> (a, m) Codec.t -> bool = fun a b ->
  let same : type x. x Codec.plan -> x Codec.plan -> bool = fun p q ->
    match p, q with
    | Codec.Identity s, Codec.Identity t -> String.equal (Scalar.name s) (Scalar.name t)
    | Codec.Plan _, Codec.Plan _ -> phys_equal p q
    | _ -> false in
  match a, b with
  | Codec.Non_null p, Codec.Non_null q -> same p q
  | Codec.Nullable p, Codec.Nullable q -> same p q
  | _ -> false
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

(* Window functions: [f(…) OVER (…)]. *)
type 'k window = window_spec
let over name args w codec = { node = Over (Apply (name, args), w); codec }
(* DuckDB sums to HUGEINT and averages to DOUBLE: cast back, as [sum]. *)
let sum_over (e : (_, Codec.non_null, _) expr) w =
  { node = Cast (Over (Apply ("sum", [ e.node ]), w), sql_type e.codec); codec = Codec.Values.nullable e.codec }
let null_sum_over (e : (_, Codec.nullable, _) expr) w =
  { node = Cast (Over (Apply ("sum", [ e.node ]), w), sql_type e.codec); codec = e.codec }
let avg_over (e : _ expr) w =
  { node = Cast (Over (Apply ("avg", [ e.node ]), w), "DOUBLE"); codec = Codec.Values.(nullable float64) }

(* Arithmetic signatures, constrained per type by [I64] … [F32]. *)
module type INTEGRAL = sig
  type t
  val ( + ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( - ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( * ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
  val ( / ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t option, Codec.nullable, 'k) expr
  val sum : (t, Codec.non_null, row) expr -> (t option, Codec.nullable, grouped) expr
  val avg : (t, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
  val sum_over : (t, Codec.non_null, 'k) expr -> 'k window -> (t option, Codec.nullable, 'k windowed) expr
  val avg_over : (t, Codec.non_null, 'k) expr -> 'k window -> (float option, Codec.nullable, 'k windowed) expr
  module Null : sig
    val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
    val sum_over : (t option, Codec.nullable, 'k) expr -> 'k window -> (t option, Codec.nullable, 'k windowed) expr
    val avg_over : (t option, Codec.nullable, 'k) expr -> 'k window -> (float option, Codec.nullable, 'k windowed) expr
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
  val sum_over : (t, Codec.non_null, 'k) expr -> 'k window -> (t option, Codec.nullable, 'k windowed) expr
  val avg_over : (t, Codec.non_null, 'k) expr -> 'k window -> (float option, Codec.nullable, 'k windowed) expr
  module Null : sig
    val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
    val sum_over : (t option, Codec.nullable, 'k) expr -> 'k window -> (t option, Codec.nullable, 'k windowed) expr
    val avg_over : (t option, Codec.nullable, 'k) expr -> 'k window -> (float option, Codec.nullable, 'k windowed) expr
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
  let sum_over = sum_over
  let avg_over = avg_over
  module Null = struct
    let ( + ) a b = arith "+" a b
    let ( - ) a b = arith "-" a b
    let ( * ) a b = arith "*" a b
    let ( / ) a b = arith "//" a b
    let sum = null_sum
    let avg = avg
    let sum_over = null_sum_over
    let avg_over = avg_over
  end
end
module Fractional = struct
  let ( + ) a b = arith "+" a b
  let ( - ) a b = arith "-" a b
  let ( * ) a b = arith "*" a b
  let ( / ) a b = arith "/" a b
  let sum = sum
  let avg = avg
  let sum_over = sum_over
  let avg_over = avg_over
  module Null = struct
    let ( + ) a b = arith "+" a b
    let ( - ) a b = arith "-" a b
    let ( * ) a b = arith "*" a b
    let ( / ) a b = arith "/" a b
    let sum = null_sum
    let avg = avg
    let sum_over = null_sum_over
    let avg_over = avg_over
  end
end
module I64 = Integral
module I32 = Integral
module I16 = Integral
module I8 = Integral
module F64 = Fractional
module F32 = Fractional

(* Windows. *)
type 'k part = node
type bound = Unbounded_preceding | Preceding of int | Current_row | Following of int | Unbounded_following
type frame = string
let render_bound = function
  | Unbounded_preceding -> "UNBOUNDED PRECEDING"
  | Preceding n -> if n < 0 then invalid_arg "Duckdb.Sql: a negative frame offset"; Int.to_string n ^ " PRECEDING"
  | Current_row -> "CURRENT ROW"
  | Following n -> if n < 0 then invalid_arg "Duckdb.Sql: a negative frame offset"; Int.to_string n ^ " FOLLOWING"
  | Unbounded_following -> "UNBOUNDED FOLLOWING"
let rows ~start ~end_ = "ROWS BETWEEN " ^ render_bound start ^ " AND " ^ render_bound end_
let range ~start ~end_ = "RANGE BETWEEN " ^ render_bound start ^ " AND " ^ render_bound end_
let part (e : _ expr) = e.node
let window ?(partition_by = []) ?(order_by = []) ?frame () : _ window =
  { partition = partition_by; order = List.map order_by ~f:(fun o -> (o.key, o.descending)); frame }
let lift (e : _ expr) = { node = e.node; codec = e.codec }
let positive name n = if n < 1 then invalid_arg ("Duckdb.Sql." ^ name ^ ": must be positive")
let row_number w = over "row_number" [] w Codec.Values.int64
let rank w = over "rank" [] w Codec.Values.int64
let dense_rank w = over "dense_rank" [] w Codec.Values.int64
let ntile n w = positive "ntile" n; over "ntile" [ Literal { sql = Int.to_string n; constant = None } ] w Codec.Values.int64
let percent_rank w = over "percent_rank" [] w Codec.Values.float64
let cume_dist w = over "cume_dist" [] w Codec.Values.float64
(* Offsets are literal integers, rendered as such. *)
let count_literal name n =
  if n < 0 then invalid_arg ("Duckdb.Sql." ^ name ^ ": a negative offset");
  Literal { sql = Int.to_string n; constant = None }
let shifted name ?(offset = 1) (e : _ expr) w codec = over name [ e.node; count_literal name offset ] w codec
let lag ?offset e w = shifted "lag" ?offset e w (Codec.Values.nullable e.codec)
let lead ?offset e w = shifted "lead" ?offset e w (Codec.Values.nullable e.codec)
let null_lag ?offset (e : _ expr) w = shifted "lag" ?offset e w e.codec
let null_lead ?offset (e : _ expr) w = shifted "lead" ?offset e w e.codec
let shifted_or name ?(offset = 1) ~(default : _ expr) (e : _ expr) w =
  checked e default;
  over name [ e.node; count_literal name offset; default.node ] w e.codec
let lag_or ?offset ~default e w = shifted_or "lag" ?offset ~default e w
let lead_or ?offset ~default e w = shifted_or "lead" ?offset ~default e w
(* A frame may be empty, and nth_value may run past it: nullable. *)
let first_value (e : _ expr) w = over "first_value" [ e.node ] w (Codec.Values.nullable e.codec)
let last_value (e : _ expr) w = over "last_value" [ e.node ] w (Codec.Values.nullable e.codec)
let nth_value n (e : _ expr) w =
  positive "nth_value" n;
  over "nth_value" [ e.node; count_literal "nth_value" n ] w (Codec.Values.nullable e.codec)
let null_first_value (e : _ expr) w = over "first_value" [ e.node ] w e.codec
let null_last_value (e : _ expr) w = over "last_value" [ e.node ] w e.codec
let null_nth_value n (e : _ expr) w =
  positive "nth_value" n;
  over "nth_value" [ e.node; count_literal "nth_value" n ] w e.codec
(* Aggregates over windows. *)
module Over = struct
  let count_star w = { node = Over (Count_star, w); codec = Codec.Values.int64 }
  let count (e : _ expr) w = over "count" [ e.node ] w Codec.Values.int64
  let min (e : (_, Codec.non_null, _) expr) w = over "min" [ e.node ] w (Codec.Values.nullable e.codec)
  let max (e : (_, Codec.non_null, _) expr) w = over "max" [ e.node ] w (Codec.Values.nullable e.codec)
  let sum = I64.sum_over
  let avg = I64.avg_over
  module Null = struct
    let min (e : (_, Codec.nullable, _) expr) w = over "min" [ e.node ] w e.codec
    let max (e : (_, Codec.nullable, _) expr) w = over "max" [ e.node ] w e.codec
    let sum = I64.Null.sum_over
    let avg = I64.Null.avg_over
  end
end
let select_over ?distinct ?where ?having ?qualify ?(order_by = []) ?limit ?offset exprs ~row =
  let (Body b) = select ?distinct ?where ?having ?limit ?offset exprs ~row in
  Body { columns = b.columns; row = b.row; list = b.list; distinct = b.distinct; joins = b.joins;
         where = b.where; group_by = b.group_by; having = b.having;
         qualify = Option.map qualify ~f:(fun (e : _ expr) -> e.node);
         order_by = List.map order_by ~f:(fun o -> { key = o.key; descending = o.descending });
         limit = b.limit; offset = b.offset }

(* Subqueries. *)
let exists (s : (_, _, _) source) = { node = Exists (Packed s); codec = Codec.Values.bool }
let in_ (type a) (x : (a, _, _) expr) (s : (a * unit, _, _) source) =
  let (Any_body (Body b)) = leftmost s in
  let compatible_column = match b.columns with Fields.(column :: _) -> compatible x.codec column in
  if not compatible_column then
    invalid_arg "Duckdb.Sql.in_: the subquery's column has another codec";
  { node = In_subquery (x.node, Packed s); codec = Codec.Values.(nullable bool) }
(* No row is NULL, so a non-null column becomes nullable; a nullable one
   would decode as an option of an option. *)
let scalar (type a) (s : (a * unit, _, _) source) : (a option, Codec.nullable, _) expr =
  let (Any_body (Body b)) = leftmost s in
  match b.columns with
  | Fields.(Codec.Non_null plan :: _) -> { node = Scalar (Packed s); codec = Codec.Nullable plan }
  | Fields.(Codec.Nullable _ :: _) -> invalid_arg "Duckdb.Sql.scalar: a nullable column (use Null.scalar)"
let null_scalar (type a) (s : (a option * unit, _, _) source) : (a option, Codec.nullable, _) expr =
  let (Any_body (Body b)) = leftmost s in
  match b.columns with
  | Fields.((Codec.Nullable _ as codec) :: _) -> { node = Scalar (Packed s); codec }
  | Fields.(Codec.Non_null _ :: _) -> invalid_arg "Duckdb.Sql.Null.scalar: a non-null column (use scalar)"

(* Set operations: the column types agree by type; the codecs must too. *)
let rec compatible_fields : type l f g r q. (l, f, r) Fields.t -> (l, g, q) Fields.t -> bool = fun a b ->
  match a, b with
  | Fields.[], Fields.[] -> true
  | Fields.(c :: rest), Fields.(d :: rest') -> compatible c d && compatible_fields rest rest'
let set_operation op left right =
  let (Any_body (Body l)) = leftmost left in
  let (Any_body (Body r)) = leftmost right in
  if not (compatible_fields l.columns r.columns) then
    invalid_arg "Duckdb.Sql: set operation sides of different codecs";
  Set { op; left; right }
let union left right = set_operation "UNION" left right
let union_all left right = set_operation "UNION ALL" left right
let intersect left right = set_operation "INTERSECT" left right
let except_ left right = set_operation "EXCEPT" left right

(* Write statements. A body is indexed by its table's shape (so an upsert's
   [excluded] binders are typed by the inserted table) and by its statement
   kind. *)
type assignment = { scope : int; column : string; value : node }
let ( := ) (target : (_, _, _) expr) (value : (_, _, _) expr) =
  checked target value;
  match target.node with
  | Column { scope; name } -> { scope; column = name; value = value.node }
  | _ -> invalid_arg "Duckdb.Sql.( := ): the target must be a column of the statement's table"

type ('row, 'm) result =
  | Count : (int64, Request.one) result
  | Returning : { columns : (_, 'fn, 'row) Fields.t; row : 'fn; list : node list } -> ('row, Request.many) result
type 'shape conflict =
  { key : node list;
    action : [ `Nothing | `Update of node option * (('shape, row) Binders.t -> assignment list) ] }
type 'shape kind =
  | Set of { assignments : assignment list; where : node option }
  | Filter of node option
  | Values of { assignments : assignment list; conflict : 'shape conflict option }
  | Select_into of { columns : node list; source : packed_source; conflict : 'shape conflict option }
type ('shape, 'kind, 'row, 'm) change = Change : { kind : 'shape kind; result : ('row, 'm) result } -> ('shape, 'kind, 'row, 'm) change
module Targets = struct
  type 'list t =
    | [] : unit t
    | (::) : ('a, _, row) expr * 'list t -> ('a * 'list) t
end
let rec target_nodes : type l. l Targets.t -> node list = function
  | Targets.[] -> []
  | Targets.(e :: rest) -> e.node :: target_nodes rest

let set ?where assignments =
  if List.is_empty assignments then invalid_arg "Duckdb.Sql.set: no assignment";
  Change { kind = Set { assignments; where = Option.map where ~f:(fun (e : _ expr) -> e.node) }; result = Count }
let filter (e : _ expr) = Change { kind = Filter (Some e.node); result = Count }
let all = Change { kind = Filter None; result = Count }
let values ?on_conflict assignments = Change { kind = Values { assignments; conflict = on_conflict }; result = Count }
let select_into ?on_conflict targets source =
  Change { kind = Select_into { columns = target_nodes targets; source = Packed source; conflict = on_conflict };
           result = Count }
let returning exprs ~row (Change { kind; result = Count }) =
  Change { kind; result = Returning { columns = fields_of_exprs exprs; row; list = nodes_of_exprs exprs } }
let nothing_on keys = { key = key_nodes keys; action = `Nothing }
let update_on ?where keys f =
  { key = key_nodes keys; action = `Update (Option.map where ~f:(fun (e : _ expr) -> e.node), f) }

(* A statement, resolved against its table: assignments checked, the
   conflict's excluded binders bound. *)
type resolved_conflict = { names : string list; update : (int * assignment list * node option) option }
type statement_kind =
  | Update_statement of { assignments : assignment list; where : node option }
  | Delete_statement of node option
  | Insert_values of { assignments : assignment list; conflict : resolved_conflict option }
  | Insert_select of { columns : string list; source : packed_source; conflict : resolved_conflict option }
type ('row, 'm) statement =
  Statement : { target : string; scope : int; kind : statement_kind; result : ('row, 'm) result } -> ('row, 'm) statement

let own_column ~scope = function
  | Column { scope = s; name } when s = scope -> name
  | _ -> invalid_arg "Duckdb.Sql: a column of another table"
let own_assignments ~scope assignments =
  let names = List.map assignments ~f:(fun (a : assignment) ->
    if a.scope <> scope then invalid_arg "Duckdb.Sql: an assignment to a column of another table";
    a.column) in
  if List.contains_dup names ~compare:String.compare then invalid_arg "Duckdb.Sql: a column assigned twice";
  assignments
let declared_keys (Request.Table_def t : (_, _, _) Request.table) =
  List.filter_map t.constraints ~f:(function
    | Table_constraint.Primary_key names | Table_constraint.Unique names -> Some names
    | _ -> None)
let resolve_conflict (Request.Table_def t as table : (_, _, _) Request.table) ~scope (c : _ conflict) =
  let names = List.map c.key ~f:(own_column ~scope) in
  let sorted = List.sort ~compare:String.compare in
  if not (List.exists (declared_keys table) ~f:(fun key -> List.equal String.equal (sorted key) (sorted names))) then
    invalid_arg "Duckdb.Sql: the conflict key must be the declared primary key or a declared unique key";
  let update = match c.action with
    | `Nothing -> None
    | `Update (where, f) ->
      let excluded = fresh_scope () in
      Some (excluded, own_assignments ~scope (f (binders t.columns ~scope:excluded)), where) in
  { names; update }

let update (Request.Table_def t as table : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  let (Change { kind; result }) = f (binders t.columns ~scope) in
  match kind with
  | Set { assignments; where } ->
    Statement { target = target_of table; scope; result;
                kind = Update_statement { assignments = own_assignments ~scope assignments; where } }
  | _ -> assert false (* excluded by the kind index *)
let delete (Request.Table_def t as table : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  let (Change { kind; result }) = f (binders t.columns ~scope) in
  match kind with
  | Filter where -> Statement { target = target_of table; scope; result; kind = Delete_statement where }
  | _ -> assert false (* excluded by the kind index *)
let insert (Request.Table_def t as table : (_, _, _) Request.table) f =
  let scope = fresh_scope () in
  let (Change { kind; result }) = f (binders t.columns ~scope) in
  let conflict = Option.map ~f:(resolve_conflict table ~scope) in
  let kind = match kind with
    | Values { assignments; conflict = c } ->
      Insert_values { assignments = own_assignments ~scope assignments; conflict = conflict c }
    | Select_into { columns; source; conflict = c } ->
      let names = List.map columns ~f:(own_column ~scope) in
      if List.contains_dup names ~compare:String.compare then invalid_arg "Duckdb.Sql: a column assigned twice";
      Insert_select { columns = names; source; conflict = conflict c }
    | _ -> assert false (* excluded by the kind index *) in
  Statement { target = target_of table; scope; result; kind }

let render_statement : type r m. context -> (r, m) statement -> string =
  fun context (Statement { target; scope; kind; result }) ->
  let listed context nodes = String.concat ~sep:", " (List.map nodes ~f:(render context)) in
  let assigned context assignments = String.concat ~sep:", " (List.map assignments ~f:(fun (a : assignment) ->
    Request.quote a.column ^ " = " ^ render context a.value)) in
  let clause context keyword = function None -> "" | Some node -> " " ^ keyword ^ " " ^ render context node in
  let returning context = match result with
    | Count -> ""
    | Returning { list; _ } -> " RETURNING " ^ listed context list in
  let aliased () =
    let a = alias context in
    (a, { context with aliases = (scope, a) :: context.aliases }) in
  match kind with
  | Update_statement { assignments; where } ->
    let a, inner = aliased () in
    let set = assigned inner assignments in
    let where = clause inner "WHERE" where in
    "UPDATE " ^ target ^ " AS " ^ a ^ " SET " ^ set ^ where ^ returning inner
  | Delete_statement where ->
    let a, inner = aliased () in
    let where = clause inner "WHERE" where in
    "DELETE FROM " ^ target ^ " AS " ^ a ^ where ^ returning inner
  | Insert_values { conflict; _ } | Insert_select { conflict; _ } ->
    (* DuckDB resolves an INSERT's alias in RETURNING only with ON CONFLICT;
       without one the target's columns render unqualified. Values and the
       source see no target row. *)
    let alias, inner = match conflict with
      | Some _ -> let a, inner = aliased () in (" AS " ^ a, inner)
      | None -> ("", { context with aliases = (scope, "") :: context.aliases }) in
    let quoted names = "(" ^ String.concat ~sep:", " (List.map names ~f:Request.quote) ^ ")" in
    let body = match kind with
      | Insert_values { assignments = []; _ } -> " DEFAULT VALUES"
      | Insert_values { assignments; _ } ->
        let names = List.map assignments ~f:(fun (a : assignment) -> a.column) in
        " " ^ quoted names ^ " VALUES (" ^ listed context (List.map assignments ~f:(fun (a : assignment) -> a.value)) ^ ")"
      | Insert_select { columns; source = Packed source; _ } -> " " ^ quoted columns ^ " " ^ render_source context source
      | _ -> assert false in
    let on_conflict = match conflict with
      | None -> ""
      | Some { names; update = None } -> " ON CONFLICT " ^ quoted names ^ " DO NOTHING"
      | Some { names; update = Some (excluded, assignments, where) } ->
        let inner = { inner with aliases = (excluded, "excluded") :: inner.aliases } in
        let set = assigned inner assignments in
        " ON CONFLICT " ^ quoted names ^ " DO UPDATE SET " ^ set ^ clause inner "WHERE" where in
    "INSERT INTO " ^ target ^ alias ^ body ^ on_conflict ^ returning inner

let command (type r m) params (f : _ -> (r, m) statement) : (_, r, m) Request.t =
  let (Packed_fields fields) = fields_of_params params in
  let scope = fresh_scope () in
  let (Statement { result; _ } as statement) = f (bound params ~scope ~index:1) in
  let sql = render_statement { aliases = []; params = scope; next = ref 0 } statement in
  match result with
  | Count -> Request.generated fields Fields.[Codec.Values.int64] ~row:Fn.id sql
  | Returning { columns; row; _ } -> Request.generated fields columns ~row sql

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
  let outer = null_outer
  let lag = null_lag
  let lead = null_lead
  let first_value = null_first_value
  let last_value = null_last_value
  let nth_value = null_nth_value
  let scalar = null_scalar
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
