open! Base
open Failure

type ('columns, 'shape, 'row) t = ('columns, 'shape, 'row) Request.table
module Columns = Columns

type ('a, 'n) column = ('a, 'n) Sql.column
module Binders = struct
  type 'shape t =
    | [] : unit t
    | (::) : ('a, 'n) column * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
end
module Key = struct
  type 'key t =
    | [] : unit t
    | (::) : ('a, Codec.non_null) column * 'key t -> ('a * 'key) t
end

let rec binders : type l f r s. (l, f, r, s) Columns.t -> scope:int -> s Binders.t = fun columns ~scope ->
  match columns with
  | Columns.[] -> Binders.[]
  | Columns.((name, codec) :: rest) -> Binders.({ Sql.scope; name; codec } :: binders rest ~scope)
let rec key_columns : type k. k Key.t -> (int * string) list = function
  | Key.[] -> []
  | Key.(c :: rest) -> (c.Sql.scope, c.name) :: key_columns rest
let rec key_types : type k. k Key.t -> string list = function
  | Key.[] -> []
  | Key.(c :: rest) -> Sql.sql_type c.Sql.codec :: key_types rest
let rec key_fields : type k. k Key.t -> k Sql.packed_fields = function
  | Key.[] -> Sql.Packed_fields Fields.[]
  | Key.(c :: rest) ->
    let (Sql.Packed_fields fields) = key_fields rest in
    Sql.Packed_fields Fields.(c.Sql.codec :: fields)
let same_set a b =
  let sort = List.sort ~compare:String.compare in
  List.equal String.equal (sort a) (sort b)
let keys constraints =
  List.filter_map constraints ~f:(function
    | Table_constraint.Primary_key names | Table_constraint.Unique names -> Some names
    | _ -> None)

(* Constraints as the callback builds them: columns still carry the scope
   they were bound in, and expressions are unrendered. *)
module Constraint = struct
  type t =
    | Primary_key of (int * string) list
    | Unique of (int * string) list
    | Foreign_key of { columns : (int * string) list; table : string; references : string list }
    | Check of Sql.node
    | Default of { column : int * string; node : Sql.node }
  let primary_key key = Primary_key (key_columns key)
  let unique key = Unique (key_columns key)
  let foreign_key key ~references:((Request.Table_def other : (_, _, _) Request.table), f) =
    let scope = Sql.fresh_scope () in
    let target = f (binders other.columns ~scope) in
    let referenced = key_columns target in
    if List.exists referenced ~f:(fun (s, _) -> s <> scope) then Sql.foreign ();
    let references = List.map referenced ~f:snd in
    (* DuckDB matches the referenced columns in the key's declared order. *)
    if not (List.exists (keys other.constraints) ~f:(List.equal String.equal references)) then
      invalid_arg "Duckdb.Table: a foreign key must reference a declared primary or unique key, in its column order";
    (* One OCaml type can stand for several SQL types (string: VARCHAR, BLOB). *)
    if not (List.equal String.equal (key_types key) (key_types target)) then
      invalid_arg "Duckdb.Table: a foreign key's columns must have the SQL types of the referenced key";
    Foreign_key { columns = key_columns key; table = other.schema ^ "\000" ^ other.name; references }
  let default (c : (_, _) column) (e : (_, _, _) Sql.expr) = Default { column = (c.scope, c.name); node = e.node }
  let check (e : (_, _, _) Sql.expr) = Check e.node
  let check_null (e : (_, _, _) Sql.expr) = Check e.node
end

(* Renders the callback's constraints against the declaration's scope. *)
let resolve ~schema ~scope (constraints : Constraint.t list) =
  let names columns =
    List.map columns ~f:(fun (s, name) -> if s <> scope then Sql.foreign () else name) in
  let render node = Sql.render_bare ~scope node in
  let resolved = List.map constraints ~f:(function
    | Constraint.Primary_key columns -> Table_constraint.Primary_key (names columns)
    | Constraint.Unique columns -> Table_constraint.Unique (names columns)
    | Constraint.Foreign_key { columns; table; references } ->
      (match String.lsplit2 table ~on:'\000' with
       | Some (other_schema, other) when String.equal other_schema schema ->
         Table_constraint.Foreign_key { columns = names columns; table = other; references }
       | _ -> invalid_arg "Duckdb.Table: a foreign key must reference a table in the same schema")
    | Constraint.Check node -> Table_constraint.Check { sql = render node; columns = Sql.mentioned node }
    | Constraint.Default { column; node } ->
      if not (List.is_empty (Sql.mentioned node)) then
        invalid_arg "Duckdb.Table: a default cannot mention a column";
      let constant = match node with Sql.Literal { constant; _ } -> constant | _ -> None in
      Table_constraint.Default { column = List.hd_exn (names [ column ]); sql = render node; constant }) in
  if List.count resolved ~f:(function Table_constraint.Primary_key _ -> true | _ -> false) > 1 then
    invalid_arg "Duckdb.Table: at most one primary key";
  resolved

let declare ?(schema = "main") ?constraints name columns ~row =
  let constraints = match constraints with
    | None -> []
    | Some f ->
      let scope = Sql.fresh_scope () in
      resolve ~schema ~scope (f (binders columns ~scope)) in
  Request.declare_table ~schema ~constraints name columns ~row
let select (Request.Table_def t : (_, _, _) t) = t.select
let insert (Request.Table_def t : (_, _, _) t) = t.insert

(* One column of the declaration: name, SQL type, nullability. *)
let rec specs : type l f r s. (l, f, r, s) Columns.t -> (string * string * bool) list = function
  | Columns.[] -> []
  | Columns.((name, codec) :: rest) ->
    let nullable = match codec with Codec.Nullable _ -> true | Codec.Non_null _ -> false in
    (name, Sql.sql_type codec, nullable) :: specs rest
let quoted names = "(" ^ String.concat ~sep:", " (List.map names ~f:Request.quote) ^ ")"
let ddl (Request.Table_def t : (_, _, _) t) =
  let default name = List.find_map t.constraints ~f:(function
    | Table_constraint.Default { column; sql; _ } when String.equal column name -> Some sql
    | _ -> None) in
  let columns = List.map (specs t.columns) ~f:(fun (name, sql_type, nullable) ->
    Request.quote name ^ " " ^ sql_type ^ (if nullable then "" else " NOT NULL")
    ^ Option.value_map (default name) ~default:"" ~f:(fun sql -> " DEFAULT " ^ sql)) in
  let table name = Request.quote t.schema ^ "." ^ Request.quote name in
  let constraints = List.filter_map t.constraints ~f:(function
    | Table_constraint.Primary_key names -> Some ("PRIMARY KEY " ^ quoted names)
    | Table_constraint.Unique names -> Some ("UNIQUE " ^ quoted names)
    | Table_constraint.Foreign_key { columns; table = other; references } ->
      Some ("FOREIGN KEY " ^ quoted columns ^ " REFERENCES " ^ table other ^ " " ^ quoted references)
    | Table_constraint.Check { sql; _ } -> Some ("CHECK (" ^ sql ^ ")")
    | Table_constraint.Default _ -> None) in
  "CREATE TABLE " ^ table t.name ^ " (" ^ String.concat ~sep:", " (columns @ constraints) ^ ")"
(* The declaration's structure as text, for migration checksums: independent
   of how the DDL is spelled, so a library change to quoting or clause syntax
   does not change an applied checksum. Type names and expression rendering
   remain part of it. *)
let canonical (Request.Table_def t : (_, _, _) t) =
  let listed names = String.concat ~sep:"," names in
  String.concat ~sep:"\n"
    ((Printf.sprintf "table %s.%s" t.schema t.name)
     :: List.map (specs t.columns) ~f:(fun (name, sql_type, nullable) ->
          Printf.sprintf "column %s %s %s" name sql_type (if nullable then "null" else "not null"))
     @ List.map t.constraints ~f:(function
         | Table_constraint.Primary_key names -> "primary key " ^ listed names
         | Table_constraint.Unique names -> "unique " ^ listed names
         | Table_constraint.Foreign_key { columns; table; references } ->
           Printf.sprintf "foreign key %s references %s %s" (listed columns) table (listed references)
         | Table_constraint.Check { sql; _ } -> "check " ^ sql
         | Table_constraint.Default { column; sql; _ } -> Printf.sprintf "default %s %s" column sql))
let create (s @ local) table = Request.Session.exec s (Request.exec ~oneshot:true Fields.[] (ddl table)) Args.[] [@nontail]

(* Verification reads the catalog in the session's snapshot. *)
let catalog_columns = Request.many Fields.[string; string] Fields.[string; bool; bool]
  ~row:(fun name nullable default -> (name, nullable, default))
  "SELECT column_name, is_nullable, column_default IS NOT NULL FROM duckdb_columns() \
   WHERE database_name = current_database() AND lower(schema_name) = lower(?) AND lower(table_name) = lower(?) \
   ORDER BY column_index"
let catalog_constraints = Request.many Fields.[string; string] Fields.[int64; string; string]
  ~row:(fun index kind table -> (index, kind, table))
  "SELECT CAST(constraint_index AS BIGINT), constraint_type, coalesce(referenced_table, '') \
   FROM duckdb_constraints() WHERE database_name = current_database() AND lower(schema_name) = lower(?) \
   AND lower(table_name) = lower(?) AND constraint_type <> 'NOT NULL'"
(* One row per listed name, in list order (a foreign key's two lists pair up
   by position). *)
let catalog_names list = Request.many Fields.[string; string] Fields.[int64; string]
  ~row:(fun index name -> (index, name))
  ("SELECT index, name FROM (SELECT CAST(constraint_index AS BIGINT) AS index, \
    unnest(range(1, len(" ^ list ^ ") + 1)) AS position, unnest(" ^ list ^ ") AS name \
    FROM duckdb_constraints() WHERE database_name = current_database() AND lower(schema_name) = lower(?) \
    AND lower(table_name) = lower(?) AND constraint_type <> 'NOT NULL') ORDER BY index, position")
let catalog_columns_of = catalog_names "constraint_column_names"
let catalog_references = catalog_names "referenced_column_names"
(* Unique (non-primary) indexes, one row per indexed expression in order.
   [expressions] is a VARCHAR rendering of the list; each element is SQL
   text: a column (quoted when it needs quoting) or an expression. *)
let catalog_unique_indexes = Request.many Fields.[string; string] Fields.[string; string]
  ~row:(fun index expression -> (index, expression))
  "SELECT index_name, expression FROM (SELECT index_name, \
   unnest(range(1, len(CAST(expressions AS VARCHAR[])) + 1)) AS position, \
   unnest(CAST(expressions AS VARCHAR[])) AS expression FROM duckdb_indexes() \
   WHERE database_name = current_database() AND lower(schema_name) = lower(?) \
   AND lower(table_name) = lower(?) AND is_unique AND NOT is_primary) ORDER BY index_name, position"
(* An index expression as a column name: a bare identifier, or a quoted one
   unquoted. Other expressions are no column. *)
let index_column expression =
  let n = String.length expression in
  if n >= 2 && Char.equal expression.[0] '"' && Char.equal expression.[n - 1] '"' then
    Some (String.substr_replace_all (String.sub expression ~pos:1 ~len:(n - 2)) ~pattern:"\"\"" ~with_:"\"")
  else if String.for_all expression ~f:(fun c -> Char.is_alphanum c || Char.equal c '_') then Some expression
  else None

(* A constraint as verification compares it: kind, column set, and for a
   foreign key the referenced table and column set. *)
type shape = { kind : string; columns : string list; table : string; references : string list }
let describe { kind; columns; table; references } =
  kind ^ " " ^ quoted columns
  ^ if String.is_empty table then "" else " REFERENCES " ^ Request.quote table ^ " " ^ quoted references
(* Key columns compare as sets; a foreign key compares its (column,
   referenced column) pairs, so a permuted reference is a difference.
   Identifiers compare as DuckDB resolves them, ignoring (ASCII) case. *)
let same a b =
  let lower = List.map ~f:String.lowercase in
  let pairs s = List.sort ~compare:Poly.compare (List.zip_exn (lower s.columns) (lower s.references)) in
  String.equal a.kind b.kind && String.Caseless.equal a.table b.table
  && if String.equal a.kind "FOREIGN KEY" then List.equal Poly.equal (pairs a) (pairs b)
     else same_set (lower a.columns) (lower b.columns)
let declared_shapes constraints =
  List.filter_map constraints ~f:(function
    | Table_constraint.Primary_key columns -> Some { kind = "PRIMARY KEY"; columns; table = ""; references = [] }
    | Table_constraint.Unique columns -> Some { kind = "UNIQUE"; columns; table = ""; references = [] }
    | Table_constraint.Foreign_key { columns; table; references } -> Some { kind = "FOREIGN KEY"; columns; table; references }
    | Table_constraint.Check { columns; _ } -> Some { kind = "CHECK"; columns; table = ""; references = [] }
    | Table_constraint.Default _ -> None)
(* The first shape of [expected] without a distinct match in [actual]. *)
let rec unmatched expected actual =
  match expected with
  | [] -> None
  | e :: rest ->
    match List.findi actual ~f:(fun _ a -> same e a) with
    | None -> Some e
    | Some (i, _) -> unmatched rest (List.filteri actual ~f:(fun j _ -> j <> i))

(* Compares the declaration with catalog rows read by [verify]. *)
let compare_catalog (Request.Table_def t : (_, _, _) t) ~catalog ~kinds ~columns ~references ~indexes =
  let context = Table { schema = t.schema; name = t.name } in
  let mismatch constraint_kind ~expected ~actual =
    Error { context; cause = Constraint_mismatch { constraint_kind; expected; actual } } in
  let nullability = List.find_map (specs t.columns) ~f:(fun (name, _, nullable) ->
    match List.find catalog ~f:(fun (n, _, _) -> String.Caseless.equal n name) with
    | Some (_, actual, _) when Bool.( <> ) actual nullable ->
      let show n = Request.quote name ^ if n then " nullable" else " NOT NULL" in
      Some (show nullable, show actual)
    | _ -> None) in
  match nullability with
  | Some (expected, actual) -> mismatch "NOT NULL" ~expected ~actual
  | None ->
    let of_index rows index =
      List.filter_map rows ~f:(fun (i, name) -> if Int64.equal i index then Some name else None) in
    let actual = List.map kinds ~f:(fun (index, kind, table) ->
      { kind; columns = of_index columns index; table; references = of_index references index }) in
    let declared = declared_shapes t.constraints in
    (* A unique index over plain columns enforces a declared UNIQUE; indexes
       are not declared, so an extra one is no difference. *)
    let indexed = List.filter_map (List.dedup_and_sort ~compare:String.compare (List.map indexes ~f:fst))
      ~f:(fun index ->
        let columns = List.filter_map indexes ~f:(fun (i, e) -> Option.some_if (String.equal i index) e) in
        let names = List.filter_map columns ~f:index_column in
        Option.some_if (List.length names = List.length columns)
          { kind = "UNIQUE"; columns = names; table = ""; references = [] }) in
    match unmatched declared (actual @ indexed), unmatched actual declared with
    | Some e, _ -> mismatch e.kind ~expected:(describe e) ~actual:"none"
    | None, Some a -> mismatch a.kind ~expected:"none" ~actual:(describe a)
    | None, None ->
      let defaulted name = List.exists t.constraints ~f:(function
        | Table_constraint.Default { column; _ } -> String.Caseless.equal column name
        | _ -> false) in
      match List.find catalog ~f:(fun (name, _, default) ->
        List.mem (Columns.names t.columns) name ~equal:String.Caseless.equal && Bool.( <> ) default (defaulted name)) with
      | Some (name, _, true) -> mismatch "DEFAULT" ~expected:"none" ~actual:("DEFAULT on " ^ Request.quote name)
      | Some (name, _, false) -> mismatch "DEFAULT" ~expected:("DEFAULT on " ^ Request.quote name) ~actual:"none"
      | None -> Ok ()

let verify (s @ local) (Request.Table_def t as table : (_, _, _) t) =
  let context = Table { schema = t.schema; name = t.name } in
  let args = Args.[t.schema; t.name] in
  match Request.Session.collect s catalog_columns args with
  | Error e -> Error e
  | Ok [] -> Error { context; cause = Unknown_table { schema = t.schema; name = t.name } }
  | Ok catalog ->
    match Request.check_declaration ~equal:String.Caseless.equal (Columns.names t.columns)
            (List.map catalog ~f:(fun (name, _, default) -> (name, default))) with
    | Error cause -> Error { context; cause }
    | Ok (_ : int list) ->
      (* Types: the declared columns, prepared against the catalog. *)
      let typed = Request.many ~oneshot:true Fields.[] (Request.fields_of_columns t.columns) ~row:t.row
        ("SELECT " ^ String.concat ~sep:", " (List.map (Columns.names t.columns) ~f:Request.quote)
         ^ " FROM " ^ Request.quote t.schema ^ "." ^ Request.quote t.name ^ " LIMIT 0") in
      match Request.Session.collect s typed Args.[] with
      | Error e -> Error { e with context }
      | Ok (_ : _ list) ->
        match Request.Session.collect s catalog_constraints args with
        | Error e -> Error e
        | Ok kinds ->
          match Request.Session.collect s catalog_columns_of args with
          | Error e -> Error e
          | Ok columns ->
            match Request.Session.collect s catalog_references args with
            | Error e -> Error e
            | Ok references ->
              match Request.Session.collect s catalog_unique_indexes args with
              | Error e -> Error e
              | Ok indexes -> compare_catalog table ~catalog ~kinds ~columns ~references ~indexes

let lookup (Request.Table_def t : (_, _, _) t) f =
  let scope = Sql.fresh_scope () in
  let key = f (binders t.columns ~scope) in
  let columns = key_columns key in
  if List.exists columns ~f:(fun (s, _) -> s <> scope) then Sql.foreign ();
  let names = List.map columns ~f:snd in
  if not (List.exists (keys t.constraints) ~f:(same_set names)) then
    invalid_arg "Duckdb.Table.lookup: the key must be the declared primary key or a declared unique key";
  let codecs = specs t.columns in
  let condition = List.mapi names ~f:(fun i name ->
    let sql_type = List.find_map_exn codecs ~f:(fun (n, ty, _) -> Option.some_if (String.equal n name) ty) in
    Printf.sprintf "%s = CAST($%d AS %s)" (Request.quote name) (i + 1) sql_type) in
  let (Sql.Packed_fields params) = key_fields key in
  Request.generated params (Request.fields_of_columns t.columns) ~row:t.row
    ("SELECT " ^ String.concat ~sep:", " (List.map (Columns.names t.columns) ~f:Request.quote)
     ^ " FROM " ^ Request.quote t.schema ^ "." ^ Request.quote t.name
     ^ " WHERE " ^ String.concat ~sep:" AND " condition)

(* The payload is global so that a facade function receiving a local appender
   can still pass the internal one to the global internals. *)
type ('columns, 'row) appender = { appender : ('columns, 'row) Request.appender @@ global }
(* A connection owns the appender's transaction; a transaction lends its own. *)
let with_appender (type k) (s : k Session.t @ local) table ~f =
  let f appender = f { appender } in
  match s with
  | Session.Connection c -> Request.with_owned_transaction c ~f:(fun tx -> Request.with_appender_transaction tx table ~f)
  | Session.Transaction tx -> Request.with_appender_transaction tx table ~f
let append ({ appender } @ local) rows = Request.append appender rows
let append_columns ({ appender } @ local) columns = Request.append_columns appender columns
let flush ({ appender } @ local) = Request.flush appender
