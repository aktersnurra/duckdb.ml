open! Base
open Resource
open Syntax

type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]
type 'params params = Params : ('params, _, _) Fields.t -> 'params params
type 'row rows = Rows : (_, 'fn, 'row) Fields.t * 'fn -> 'row rows
type ('params, 'row, 'multiplicity) t =
  { id : int; sql : string; oneshot : bool; params : 'params params; rows : 'row rows }
(* A declared table; its SELECT and INSERT are built once so that they share
   statement-cache entries. *)
type ('columns, 'row) table =
  Table_def : { schema : string; name : string; columns : ('columns, 'fn, 'row) Columns.t; row : 'fn;
                select : (unit, 'row, many) t; insert : ('columns, unit, zero) t }
    -> ('columns, 'row) table

(* Cache identity: two requests never share a statement, even with equal SQL. *)
let next_id = Stdlib.Atomic.make 0
let make ?(oneshot = false) params rows sql =
  { id = Stdlib.Atomic.fetch_and_add next_id 1; sql; oneshot; params = Params params; rows }
let exec ?oneshot params sql = make ?oneshot params (Rows (Fields.[], ())) sql
let one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let zero_or_one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let many ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let query r = r.sql

type context = Query of string | Table of { schema : string; name : string } | Transaction
type cause =
  | Core of error
  | Parameter_count of { expected : int; actual : int }
  | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
  | Unknown_column of { name : string }
  | Missing_column of { name : string }
  | Encode_rejected of { index : int; reason : Error.t }
  | Decode_rejected of { column : int; row : int; reason : Error.t }
  | Rollback_failed of { primary : request_error; rollback : error }
and request_error = { context : context; cause : cause }
let query_of_context = function
  | Query sql -> sql
  | Table { schema; name } -> schema ^ "." ^ name
  | Transaction -> "transaction"
exception Cleanup_exception of request_error * exn

module type QUERY = sig
  type owner
  type error
  type 'a future
  val exec : owner -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
  val find : owner -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
  val find_opt : owner -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
    ('row option, error) result future
  val collect : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    ('row list, error) result future
  val fold : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    init:'a -> f:('row -> 'a -> ('a Query.step, request_error) result) -> ('a, error) result future
end

module type CONNECTION = sig
  include QUERY
  val with_transaction : owner -> f:(transaction -> ('a, request_error) result) -> ('a, error) result future
  val ingest : owner -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
    (unit, error) result future
end

let with_context context result = Result.map_error result ~f:(fun cause -> { context; cause })
let core context result = Result.map_error result ~f:(fun error -> { context; cause = Core error })

(* Encoding: each value becomes one bindable scalar, checked by its codec. *)
type bound = Bound : 'b Scalar.t * 'b option -> bound
let encode_value : type a n. (a, n) Codec.t -> a -> bound Or_error.t = fun codec value ->
  match codec with
  | Codec.Non_null (Codec.Plan plan) -> Or_error.map (plan.encode value) ~f:(fun b -> Bound (plan.scalar, Some b))
  | Codec.Nullable (Codec.Plan plan) ->
    match value with
    | None -> Ok (Bound (plan.scalar, None))
    | Some value -> Or_error.map (plan.encode value) ~f:(fun b -> Bound (plan.scalar, Some b))
let rec encode_args : type l f r. (l, f, r) Fields.t -> l Args.t -> index:int ->
  (bound list, cause) Result.t = fun fields args ~index ->
  match fields, args with
  | Fields.[], Args.[] -> Ok []
  | Fields.(codec :: fields), Args.(value :: args) ->
    match encode_value codec value with
    | Error reason -> Error (Encode_rejected { index; reason })
    | Ok bound -> Result.map (encode_args fields args ~index:(index + 1)) ~f:(fun rest -> bound :: rest)

(* The base scalar each declared position crosses the boundary as. *)
let scalar_id : type a n. (a, n) Codec.t -> int * string = function
  | Codec.Non_null (Codec.Plan plan) -> Scalar.native_id plan.scalar, Scalar.name plan.scalar
  | Codec.Nullable (Codec.Plan plan) -> Scalar.native_id plan.scalar, Scalar.name plan.scalar
let rec scalar_ids : type l f r. (l, f, r) Fields.t -> (int * string) list = function
  | Fields.[] -> []
  | Fields.(codec :: fields) -> scalar_id codec :: scalar_ids fields

(* Unresolved engine types (ANY/INVALID) accept the declaration, as [bind] does. *)
let unresolved actual = actual = Duckdb_ffi.Type_id.invalid || actual = Duckdb_ffi.Type_id.any
let check_types ~declared ~actual ~count_error =
  if Array.length actual <> List.length declared then Error (count_error (List.length declared) (Array.length actual))
  else
    List.foldi declared ~init:(Ok ()) ~f:(fun i acc (id, name) ->
      let* () = acc in
      if unresolved actual.(i) || actual.(i) = id then Ok ()
      else Error (Core (Data_error (Scalar.Type_mismatch { index = i; expected = name; actual = actual.(i) }))))
let check_parameters params p =
  check_types ~declared:(scalar_ids params) ~actual:(Query.parameter_types p)
    ~count_error:(fun expected actual -> Parameter_count { expected; actual })
(* Statements without declared rows (exec) are not constrained: DuckDB reports
   e.g. a Count column for INSERT. *)
let check_columns : type row. row rows -> int array -> (unit, cause) Result.t = fun (Rows (fields, _)) actual ->
  match fields with
  | Fields.[] -> Ok ()
  | Fields.(_ :: _) ->
    check_types ~declared:(scalar_ids fields) ~actual
      ~count_error:(fun expected actual -> Core (Data_error (Scalar.Column_count { expected; actual })))
let validate r p =
  let Params params = r.params in
  let* () = check_parameters params p in
  let* columns = Result.map_error (Query.column_types p) ~f:(fun e -> Core e) in
  check_columns r.rows columns

(* Decoding a borrowed row into an owned value through the declared codecs. *)
let decode_value : type a n. (a, n) Codec.t -> Query.chunk @ local -> column:int -> row:int -> seen:int ->
  (a, cause) Result.t = fun codec chunk ~column ~row ~seen ->
  match Query.column chunk ~column ~row codec with
  | Ok value -> Ok value
  | Error (Data_error (Scalar.Decode_rejected { reason; _ })) -> Error (Decode_rejected { column; row = seen + row; reason })
  | Error e -> Error (Core e)
let rec decode_row : type l f r. (l, f, r) Fields.t -> f -> Query.chunk @ local ->
  column:int -> row:int -> seen:int -> (r, cause) Result.t = fun fields fn chunk ~column ~row ~seen ->
  match fields with
  | Fields.[] -> Ok fn
  | Fields.(codec :: fields) ->
    match decode_value codec chunk ~column ~row ~seen with
    | Error cause -> Error cause
    | Ok value -> decode_row fields (fn value) chunk ~column:(column + 1) ~row ~seen

(* Folds decoded rows. The accumulator carries a request failure as an early
   Stop so the core fold still closes the result on every exit. *)
let fold_result context (Rows (fields, fn) as rows) result ~init ~f =
  let validate types = Result.map_error (check_columns rows types) ~f:(function
    | Core e -> e | _ -> Data_error (Scalar.Column_count { expected = 0; actual = Array.length types })) in
  let+ outcome, _ = core context (Query.fold_validated result ~validate ~init:(Ok init, 0)
    ~f:(fun (chunk @ local) (acc, seen) ->
      let length = Query.chunk_length chunk in
      let rec loop row acc =
        if row = length then Ok (Query.Continue (Ok acc, seen + length))
        else match decode_row fields fn chunk ~column:0 ~row ~seen with
          | Error cause -> Ok (Query.Stop (Error { context; cause }, seen + row))
          | Ok value ->
            match f value acc with
            | Error e -> Ok (Query.Stop (Error e, seen + row))
            | Ok (Query.Stop acc) -> Ok (Query.Stop (Ok acc, seen + row + 1))
            | Ok (Query.Continue acc) -> loop (row + 1) acc in
      match acc with
      | Error _ -> Ok (Query.Stop (acc, seen))
      | Ok acc -> loop 0 acc [@nontail])) in
  outcome
let fold_result context rows result ~init ~f = Result.join (fold_result context rows result ~init ~f)

let witness : Query.prepared Type_equal.Id.t = Type_equal.Id.create ~name:"Duckdb.Request.prepared" (fun _ -> Sexp.Atom "<prepared>")

(* Runs [use] on a validated statement for [r]: cached when allowed (populated
   only outside explicit transactions), otherwise prepared for this call. *)
let with_statement c within r ~use =
  let context = Query r.sql in
  let validated p = with_context context (validate r p) in
  let scoped prepare =
    let* p = core context prepare in
    Exn.protect ~finally:(fun () -> force_close_child (Query.child p)) ~f:(fun () ->
      let* () = validated p in
      use p) in
  let cached p = lend_child (Query.child p) within (fun () ->
    let outcome = use p in
    (match outcome with
     | Error { cause = Core (Data_error Scalar.Parameter_schema_changed); _ } -> cache_remove c ~key:r.id
     | Ok _ | Error _ -> ());
    outcome) in
  if r.oneshot || cache_capacity c = 0 then
    match within with
    | None -> scoped (Query.prepare c r.sql)
    | Some tx -> scoped (Query.prepare_transaction tx r.sql)
  else
    match cache_find c witness ~key:r.id, within with
    | Some p, _ -> cached p
    | None, Some tx -> scoped (Query.prepare_transaction tx r.sql)
    | None, None ->
      let* p = core context (Query.prepare_cached c r.sql) in
      match validated p with
      | Error _ as error -> force_close_child (Query.child p); error
      | Ok () -> cache_add c witness ~key:r.id p (Query.child p); cached p

let bind_all context p bounds =
  List.foldi bounds ~init:(Ok ()) ~f:(fun i acc (Bound (typ, value)) ->
    let* () = acc in core context (Query.bind_scalar p (i + 1) typ value))

let run c within r args ~consume =
  let context = Query r.sql in
  let Params params = r.params in
  let* bounds = with_context context (encode_args params args ~index:1) in
  with_statement c within r ~use:(fun p ->
    let* () = bind_all context p bounds in
    let* result = core context (Query.execute_prepared p) in
    consume context result)

let collect_rows c within r args =
  run c within r args ~consume:(fun context result ->
    Result.map (fold_result context r.rows result ~init:[] ~f:(fun row rows -> Ok (Query.Continue (row :: rows))))
      ~f:List.rev)
(* Stops at a second row: its presence is all that is needed. *)
let at_most_one c within r args ~expected =
  run c within r args ~consume:(fun context result ->
    fold_result context r.rows result ~init:None ~f:(fun row -> function
      | None -> Ok (Query.Continue (Some row))
      | Some _ -> Error { context; cause = Row_count { expected; actual = `More_than_one } }))
let run_exec c within r args = run c within r args ~consume:(fun context result -> core context (Query.close_result result))
let run_find c within r args =
  let* row = at_most_one c within r args ~expected:`One in
  match row with
  | Some row -> Ok row
  | None -> Error { context = Query r.sql; cause = Row_count { expected = `One; actual = `Zero } }
let run_fold c within r args ~init ~f =
  run c within r args ~consume:(fun context result -> fold_result context r.rows result ~init ~f)

let fold_on c r ~init ~f = run_fold c None r Args.[] ~init ~f

(* Declared tables. *)
let rec fields_of_columns : type l f r. (l, f, r) Columns.t -> (l, f, r) Fields.t = function
  | Columns.[] -> Fields.[]
  | Columns.((_, codec) :: columns) -> Fields.(codec :: fields_of_columns columns)
let rec column_names : type l f r. (l, f, r) Columns.t -> string list = function
  | Columns.[] -> []
  | Columns.((name, _) :: columns) -> name :: column_names columns
let quote name = "\"" ^ String.substr_replace_all name ~pattern:"\"" ~with_:"\"\"" ^ "\""
let declare_table ?(schema = "main") name columns ~row =
  let names = column_names columns and fields = fields_of_columns columns in
  let target = quote schema ^ "." ^ quote name in
  let listed = String.concat ~sep:", " (List.map names ~f:quote) in
  let select = many Fields.[] fields ~row ("SELECT " ^ listed ^ " FROM " ^ target) in
  let insert = exec fields ("INSERT INTO " ^ target ^ " (" ^ listed ^ ") VALUES ("
    ^ String.concat ~sep:", " (List.map names ~f:(fun _ -> "?")) ^ ")") in
  Table_def { schema; name; columns; row; select; insert }

(* Typed appender: the declaration is checked against the catalog, in the
   appender's own transaction snapshot, before any row is accepted. *)
type ('columns, 'row) appender = { table : ('columns, 'row) table; core : Appender.appender }
let table_context (Table_def t) = Table { schema = t.schema; name = t.name }
(* Poisons a transaction whose typed table operation failed without a core error. *)
let typed_failure = Native_error "Typed table operation failed; transaction must roll back"
let catalog_columns = many Fields.[string; string] Fields.[string; bool] ~row:(fun name default -> name, default)
  "SELECT column_name, column_default IS NOT NULL FROM duckdb_columns() \
   WHERE database_name = current_database() AND schema_name = ? AND table_name = ? ORDER BY column_index"
let check_declaration names catalog =
  let position name = List.findi catalog ~f:(fun _ (catalog_name, _) -> String.equal name catalog_name) in
  match List.find names ~f:(fun name -> Option.is_none (position name)) with
  | Some name -> Error (Unknown_column { name })
  | None ->
    match List.find catalog ~f:(fun (name, has_default) ->
      not has_default && not (List.mem names name ~equal:String.equal)) with
    | Some (name, _) -> Error (Missing_column { name })
    | None -> Ok (List.map names ~f:(fun name -> fst (Option.value_exn (position name))))
let open_typed tx (Table_def t as table) =
  let context = table_context table in
  let c = transaction_connection tx in
  let in_table result = Result.map_error result ~f:(fun e -> { e with context }) in
  let* catalog = in_table (collect_rows c (Some tx) catalog_columns Args.[t.schema; t.name]) in
  let names = column_names t.columns in
  let* indices = match catalog with
    | [] -> Ok [] (* opening the appender reports the missing table *)
    | _ :: _ ->
      Result.map_error (check_declaration names catalog) ~f:(fun cause ->
        poison_transaction tx typed_failure; { context; cause }) in
  let* a = core context (Appender.open_appender tx ~schema:t.schema t.name) in
  let checked =
    let* () =
      if List.equal Int.equal indices (List.init (List.length catalog) ~f:Fn.id) then Ok ()
      else core context (Appender.select_columns a ~names:(Array.of_list names) ~indices:(Array.of_list indices)) in
    with_context context (check_types ~declared:(scalar_ids (fields_of_columns t.columns))
      ~actual:(Appender.types a)
      ~count_error:(fun expected actual -> Core (Data_error (Scalar.Column_count { expected; actual })))) in
  match checked with
  | Ok () -> Ok { table; core = a }
  | Error _ as error -> poison_transaction tx typed_failure; force_close_child (Appender.child a); error
let with_appender_transaction tx table ~f =
  let context = table_context table in
  let* a = open_typed tx table in
  let primary = ref None in
  let work () =
    match f a with
    | Error e -> primary := Some e; poison_transaction tx typed_failure; Ok (Error e)
    | Ok x -> Ok (Result.map (core context (Appender.close_appender a.core)) ~f:(fun () -> x)) in
  match capture_all (fun () -> scope work (fun () -> force_close_child (Appender.child a.core))) with
  | Ok (Ok outcome) -> outcome
  | Ok (Error e) -> poison_transaction tx e; Error { context; cause = Core e }
  | Error (exn, backtrace) ->
    poison_transaction tx typed_failure;
    match !primary with
    | Some e -> Stdlib.Printexc.raise_with_backtrace (Cleanup_exception (e, exn)) backtrace
    | None -> Stdlib.Printexc.raise_with_backtrace exn backtrace
(* A codec rejection rejects the whole batch before any native row. *)
let append (type c) (a : (c, _) appender) (rows : c Args.t list) =
  let (Table_def t) = a.table in
  let context = table_context a.table in
  let fields = fields_of_columns t.columns in
  let* rows = with_context context (Result.all (List.map rows ~f:(fun args -> encode_args fields args ~index:1))) in
  let cells = List.map rows ~f:(List.map ~f:(fun (Bound (typ, value)) -> Appender.Cell (typ, value))) in
  core context (Appender.append_rows a.core cells)
let flush a = core (table_context a.table) (Appender.flush_appender a.core)

let transaction_outcome =
  { rollback_failed = (fun primary rollback -> { context = primary.context; cause = Rollback_failed { primary; rollback } });
    cleanup_failed = (fun primary exn -> Cleanup_exception (primary, exn)) }

module Connection = struct
  type owner = connection
  type error = request_error
  type 'a future = 'a
  let exec c r args = run_exec c None r args
  let find c r args = run_find c None r args
  let find_opt c r args = at_most_one c None r args ~expected:`Zero_or_one
  let collect c r args = collect_rows c None r args
  let fold c r args ~init ~f = run_fold c None r args ~init ~f
  let with_transaction c ~f =
    with_transaction_lifted ~lift:(fun error -> { context = Transaction; cause = Core error })
      ~outcome:transaction_outcome c ~f
  let ingest c table batches ~flush:explicit =
    with_transaction c ~f:(fun tx -> with_appender_transaction tx table ~f:(fun a ->
      let* () = List.fold batches ~init:(Ok ()) ~f:(fun acc rows -> let* () = acc in append a rows) in
      if explicit then flush a else Ok ()))
end
module Transaction = struct
  type owner = transaction
  type error = request_error
  type 'a future = 'a
  let exec tx r args = run_exec (transaction_connection tx) (Some tx) r args
  let find tx r args = run_find (transaction_connection tx) (Some tx) r args
  let find_opt tx r args = at_most_one (transaction_connection tx) (Some tx) r args ~expected:`Zero_or_one
  let collect tx r args = collect_rows (transaction_connection tx) (Some tx) r args
  let fold tx r args ~init ~f = run_fold (transaction_connection tx) (Some tx) r args ~init ~f
end
