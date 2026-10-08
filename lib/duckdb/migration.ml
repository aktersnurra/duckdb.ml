open! Base
open Failure

(* A step's work: SQL statements, or OCaml code, in the step's transaction. *)
(* [canonical] is what the checksum covers: the statements themselves, or a
   declaration's structure for declaration-based steps. *)
type kind =
  | Statements of { statements : string list; canonical : string }
  | Run of ([ `Transaction ] Session.t @ local -> (unit, Failure.t) result)
type step = { version : int; name : string; checksum : string; kind : kind }
type column = Column : ('a, 'n) Table.column -> column
type table = Packed : (_, _, _) Table.t -> table

(* An edited SQL step changes its checksum; code cannot be hashed, so a [run]
   step's checksum covers its name only. *)
let step version name kind =
  let text = match kind with
    | Statements { canonical; _ } -> canonical
    | Run _ -> name in
  { version; name; checksum = Stdlib.Digest.to_hex (Stdlib.Digest.string text); kind }

let target ~schema name = Request.quote schema ^ "." ^ Request.quote name
let statements list = Statements { statements = list; canonical = String.concat ~sep:"\n" list }
let sql statement = statements [ statement ]
let run f = Run f
let create table = Statements { statements = [ Table.ddl table ]; canonical = "create " ^ Table.canonical table }
let drop_table ?(schema = "main") name = statements [ "DROP TABLE " ^ target ~schema name ]
let drop_column ?(schema = "main") ~table name =
  statements [ "ALTER TABLE " ^ target ~schema table ^ " DROP COLUMN " ^ Request.quote name ]
let rename_table ?(schema = "main") from ~to_ =
  statements [ "ALTER TABLE " ^ target ~schema from ^ " RENAME TO " ^ Request.quote to_ ]
let rename_column ?(schema = "main") ~table from ~to_ =
  statements [ "ALTER TABLE " ^ target ~schema table ^ " RENAME COLUMN " ^ Request.quote from
               ^ " TO " ^ Request.quote to_ ]

(* DuckDB adds no column with constraints: a non-null column is added with
   its default, then set NOT NULL. *)
let add_column (Request.Table_def t : (_, _, _) Table.t) pick =
  let scope = Sql.fresh_scope () in
  let (Column c) = pick (Table.binders t.columns ~scope) in
  if c.Sql.scope <> scope then Sql.foreign ();
  let name = c.name in
  let constrained = List.exists t.constraints ~f:(function
    | Table_constraint.Primary_key columns | Table_constraint.Unique columns
    | Table_constraint.Check { columns; _ } | Table_constraint.Foreign_key { columns; _ } ->
      List.mem columns name ~equal:String.equal
    | Table_constraint.Default _ -> false) in
  if constrained then
    invalid_arg "Duckdb.Migration.add_column: DuckDB cannot add a column with a key, CHECK or foreign key";
  let sql_type, nullable = List.find_map_exn (Table.specs t.columns) ~f:(fun (n, ty, nullable) ->
    Option.some_if (String.equal n name) (ty, nullable)) in
  (* DuckDB's statement extraction splits ADD COLUMN … DEFAULT <expression>
     (CAST, TRUE, functions, operators) into several statements; a quoted
     constant, cast to the column type, passes. *)
  let default = List.find_map t.constraints ~f:(function
    | Table_constraint.Default { column; constant; _ } when String.equal column name ->
      (match constant with
       | Some constant -> Some (" DEFAULT " ^ constant)
       | None -> invalid_arg "Duckdb.Migration.add_column: the column's default must be a literal")
    | _ -> None) in
  let table = target ~schema:t.schema t.name in
  let canonical = Printf.sprintf "add column %s.%s %s %s %s%s" t.schema t.name name sql_type
    (if nullable then "null" else "not null") (Option.value default ~default:"") in
  Statements { canonical; statements =
    ("ALTER TABLE " ^ table ^ " ADD COLUMN " ^ Request.quote name ^ " " ^ sql_type ^ Option.value default ~default:"")
     :: if nullable then [] else [ "ALTER TABLE " ^ table ^ " ALTER COLUMN " ^ Request.quote name ^ " SET NOT NULL" ] }
let table t = Packed t

(* The bookkeeping table. Hand-written: its [applied_at] default is [now()],
   which typed literals cannot express. Created only when missing, so an
   up-to-date read-only database migrates (to nothing). *)
let history_exists = Request.one Fields.[] Fields.[bool] ~row:Fn.id
  "SELECT count(*) > 0 FROM duckdb_tables() WHERE database_name = current_database() \
   AND schema_name = 'main' AND table_name = 'duckdb_ml_migrations'"
let create_history = Request.exec ~oneshot:true Fields.[]
  "CREATE TABLE IF NOT EXISTS \"main\".\"duckdb_ml_migrations\" (\"version\" BIGINT PRIMARY KEY, \
   \"name\" VARCHAR NOT NULL, \"checksum\" VARCHAR NOT NULL, \
   \"applied_at\" TIMESTAMPTZ NOT NULL DEFAULT now())"
let read_history = Request.many Fields.[] Fields.[int64; string; string]
  ~row:(fun version name checksum -> (Int64.to_int_exn version, name, checksum))
  "SELECT \"version\", \"name\", \"checksum\" FROM \"main\".\"duckdb_ml_migrations\" ORDER BY \"version\""
let record = Request.exec Fields.[int64; string; string]
  "INSERT INTO \"main\".\"duckdb_ml_migrations\" (\"version\", \"name\", \"checksum\") VALUES (?, ?, ?)"

let describe version name checksum = Printf.sprintf "%d %s (%s)" version name checksum
(* The steps not yet applied, or the first difference between the applied
   history and the list. *)
let rec pending steps applied =
  let mismatch version name ~expected ~actual =
    Error { context = Migration { version; name }; cause = Migration_mismatch { version; expected; actual } } in
  match steps, applied with
  | steps, [] -> Ok steps
  | [], (version, name, checksum) :: _ -> mismatch version name ~expected:"none" ~actual:(describe version name checksum)
  | s :: steps, (version, name, checksum) :: rest ->
    if s.version < version then mismatch s.version s.name ~expected:(describe s.version s.name s.checksum) ~actual:"none"
    else if s.version > version then mismatch version name ~expected:"none" ~actual:(describe version name checksum)
    else if String.equal s.name name && String.equal s.checksum checksum then pending steps rest
    else mismatch version name ~expected:(describe s.version s.name s.checksum) ~actual:(describe version name checksum)

let rec run_statements (tx @ local) = function
  | [] -> Ok ()
  | statement :: rest ->
    match Request.Session.exec tx (Request.exec ~oneshot:true Fields.[] statement) Args.[] with
    | Error e -> Error e
    | Ok () -> run_statements tx rest
(* One step and its bookkeeping row in one transaction. *)
let apply_step (c @ local) s =
  let within_step (e : Failure.t) = { e with context = Migration { version = s.version; name = s.name } } in
  Result.map_error ~f:within_step
    (Request.Session.with_transaction c ~f:(fun tx ->
       let performed = match s.kind with Run f -> f tx | Statements { statements = list; _ } -> run_statements tx list in
       match performed with
       | Error e -> Error e
       | Ok () -> Request.Session.exec tx record Args.[Int64.of_int s.version; s.name; s.checksum]))
let rec apply_all (c @ local) applied = function
  | [] -> Ok (List.rev applied)
  | s :: rest ->
    match apply_step c s with
    | Error e -> Error e
    | Ok () -> apply_all c (s.version :: applied) rest
let rec verify_all (c @ local) = function
  | [] -> Ok ()
  | Packed t :: rest ->
    match Table.verify c t with
    | Error e -> Error e
    | Ok () -> verify_all c rest
let rec check_versions = function
  | a :: (b :: _ as rest) ->
    if a.version >= b.version then invalid_arg "Duckdb.Migration.apply: versions must be strictly increasing";
    check_versions rest
  | _ -> ()

let apply (c @ local) ?(verify = []) steps =
  check_versions steps;
  let created = match Request.Session.find c history_exists Args.[] with
    | Error e -> Error e
    | Ok true -> Ok ()
    | Ok false -> Request.Session.exec c create_history Args.[] in
  match created with
  | Error e -> Error e
  | Ok () ->
    match Request.Session.collect c read_history Args.[] with
    | Error e -> Error e
    | Ok applied ->
      match pending steps applied with
      | Error e -> Error e
      | Ok todo ->
        match apply_all c [] todo with
        | Error e -> Error e
        | Ok versions -> Result.map (verify_all c verify) ~f:(fun () -> versions)
