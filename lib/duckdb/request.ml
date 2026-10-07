open! Base
open Resource
open Failure
open Syntax

type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]
type 'params params = Params : ('params, _, _) Fields.t -> 'params params
type 'row rows = Rows : (_, 'fn, 'row) Fields.t * 'fn -> 'row rows | No_rows : unit rows
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
let exec ?oneshot params sql = make ?oneshot params No_rows sql
let one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let zero_or_one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let many ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let query r = r.sql

module type QUERY = sig
  type _ owner
  type error
  type 'a future
  val exec : _ owner @ local -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
  val find : _ owner @ local -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
  val find_opt : _ owner @ local -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
    ('row option, error) result future
  val collect : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    ('row list, error) result future
  val fold : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    init:'a -> f:('row -> 'a -> ('a Query.step, Failure.t) result) -> ('a, error) result future
end

module type CONNECTION = sig
  include QUERY
  val with_transaction : [ `Connection ] owner @ local ->
    f:([ `Transaction ] Session.t @ local -> ('a, Failure.t) result) -> ('a, error) result future
  val ingest : [ `Connection ] owner @ local -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
    (unit, error) result future
end

(* Encoding: each value becomes one bindable scalar, checked by its codec. *)
type bound = Bound : 'b Scalar.t * 'b option -> bound
let encode_plan : type a. a Codec.plan -> a -> bound Or_error.t = fun plan value ->
  match plan with
  | Codec.Identity scalar -> Ok (Bound (scalar, Some value))
  | Codec.Plan plan -> Or_error.map (plan.encode value) ~f:(fun b -> Bound (plan.scalar, Some b))
let encode_value : type a n. (a, n) Codec.t -> a -> bound Or_error.t = fun codec value ->
  match codec with
  | Codec.Non_null plan -> encode_plan plan value
  | Codec.Nullable plan ->
    match value with
    | None -> let (Codec.Packed_scalar s) = Codec.plan_scalar plan in Ok (Bound (s, None))
    | Some value -> encode_plan plan value
let rec encode_args : type l f r. (l, f, r) Fields.t -> l Args.t -> index:int ->
  (bound list, cause) Result.t = fun fields args ~index ->
  match fields, args with
  | Fields.[], Args.[] -> Ok []
  | Fields.(codec :: fields), Args.(value :: args) ->
    match encode_value codec value with
    | Error reason -> Error (Encode_rejected { index; reason })
    | Ok bound -> Result.map (encode_args fields args ~index:(index + 1)) ~f:(fun rest -> bound :: rest)

(* The base scalar each declared position crosses the boundary as. *)
let scalar_id : type a n. (a, n) Codec.t -> int * string = fun codec ->
  let (Codec.Packed_scalar s) = match codec with
    | Codec.Non_null plan -> Codec.plan_scalar plan
    | Codec.Nullable plan -> Codec.plan_scalar plan in
  Scalar.native_id s, Scalar.name s
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
      else Error (Type_mismatch { index = i; expected = name; actual = type_name actual.(i) }))
let check_parameters params p =
  check_types ~declared:(scalar_ids params) ~actual:(Query.parameter_types p)
    ~count_error:(fun expected actual -> Parameter_count { expected; actual })
(* Declared rows are always checked, including zero columns. Statements without
   declared rows (exec, [No_rows]) are not constrained: DuckDB reports e.g. a
   Count column for INSERT. *)
let check_columns : type row. row rows -> int array -> (unit, error) Result.t = fun rows actual ->
  match rows with
  | No_rows -> Ok ()
  | Rows (fields, _) ->
    check_types ~declared:(scalar_ids fields) ~actual
      ~count_error:(fun expected actual -> Column_count { expected; actual })
(* A parameterised table function prepares as one unresolved column whatever
   it returns; such rows are checked against the executed result alone. *)
let validate r p =
  let Params params = r.params in
  let* () = check_parameters params p in
  let* columns = Query.column_types p in
  if (not (Array.is_empty columns)) && Array.for_all columns ~f:unresolved then Ok ()
  else check_columns r.rows columns

(* Decoding a borrowed row into an owned value through the declared codecs.
   Rows are reported absolute within the result: [seen] precede this chunk. *)
let absolute ~seen = function
  | Null { column; row } -> Null { column; row = seen + row }
  | Decode_rejected { column; row; reason } -> Decode_rejected { column; row = seen + row; reason }
  | cause -> cause
let decode_value : type a n. (a, n) Codec.t -> Query.chunk @ local -> column:int -> row:int -> seen:int ->
  (a, cause) Result.t = fun codec chunk ~column ~row ~seen ->
  Result.map_error (Query.column chunk ~column ~row codec) ~f:(absolute ~seen)
let rec decode_row : type l f r. (l, f, r) Fields.t -> f -> Query.chunk @ local ->
  column:int -> row:int -> seen:int -> (r, cause) Result.t = fun fields fn chunk ~column ~row ~seen ->
  match fields with
  | Fields.[] -> Ok fn
  | Fields.(codec :: fields) ->
    match decode_value codec chunk ~column ~row ~seen with
    | Error cause -> Error cause
    | Ok value -> decode_row fields (fn value) chunk ~column:(column + 1) ~row ~seen

(* Folds decoded rows. The accumulator carries a request failure as an early
   Stop so the core fold still closes the result on every exit. Cancellation
   is checked before every row; it is free outside Bridge requests. Rows
   below [Decode.limit] decode on the fast path; from there on the per-cell
   path reports exactly the error it always did (NULL in a non-null column, a
   mistyped column). On the fast path all columns of a row are decoded before
   the row function is applied, so effects between curried arguments do not
   run for a row with a later rejected column. *)
let fold_decoded context fields fn ~validate result ~init ~f =
  let+ outcome, _ = within context (Query.fold_validated ~context result ~validate ~init:(Ok init, 0)
    ~f:(fun (chunk @ local) (acc, seen) ->
      match acc with
      | Error _ -> Ok (Query.Stop (acc, seen))
      | Ok acc ->
        let length = Query.chunk_length chunk in
        let limit = Decode.limit fields chunk ~length in
        let stop e row = Ok (Query.Stop (Error e, seen + row)) in
        let continue_with row acc value loop =
          match f value acc with
          | Error e -> stop e row
          | Ok (Query.Stop acc) -> Ok (Query.Stop (Ok acc, seen + row + 1))
          | Ok (Query.Continue acc) -> loop (row + 1) acc in
        let rec loop row acc =
          if row = length then Ok (Query.Continue (Ok acc, seen + length))
          else match Query.result_checkpoint result with
          | Error cause -> stop { context; cause } row
          | Ok () ->
          if row < limit then
            match Decode.row fields fn chunk row with
            | exception Decode.Rejected { column; reason } ->
              stop { context; cause = Decode_rejected { column; row = seen + row; reason } } row
            | value -> continue_with row acc value loop
          else
            match decode_row fields fn chunk ~column:0 ~row ~seen with
            | Error cause -> stop { context; cause } row
            | Ok value -> continue_with row acc value loop in
        loop 0 acc [@nontail])) in
  outcome
let fold_result : type row a. context -> row rows -> Query.query_result -> init:a ->
  f:(row -> a -> (a Query.step, Failure.t) result) -> (a, Failure.t) result =
  fun context rows result ~init ~f ->
  let validate = check_columns rows in
  Result.join (match rows with
    | Rows (fields, fn) -> fold_decoded context fields fn ~validate result ~init ~f
    | No_rows -> fold_decoded context Fields.[] () ~validate result ~init ~f)

let witness : Query.prepared Type_equal.Id.t = Type_equal.Id.create ~name:"Duckdb.Request.prepared" (fun _ -> Sexp.Atom "<prepared>")

(* Runs [use] on a validated statement for [r]: cached when allowed (populated
   only outside explicit transactions), otherwise prepared for this call. *)
let with_statement c tx r ~context ~use =
  let validated p = within context (validate r p) in
  let scoped prepare =
    let* p = within context prepare in
    Exn.protect ~finally:(fun () -> force_close_child (Query.child p)) ~f:(fun () ->
      let* () = validated p in
      use p) in
  let cached p = lend_child (Query.child p) tx (fun () ->
    let outcome = use p in
    (match outcome with
     | Error { cause = Parameter_schema_changed; _ } -> cache_remove c ~key:r.id
     | Ok _ | Error _ -> ());
    outcome) in
  if r.oneshot || cache_capacity c = 0 then
    match tx with
    | None -> scoped (Query.prepare c r.sql)
    | Some tx -> scoped (Query.prepare_transaction tx r.sql)
  else
    match cache_find c witness ~key:r.id, tx with
    | Some p, _ -> cached p
    | None, Some tx -> scoped (Query.prepare_transaction tx r.sql)
    | None, None ->
      let* p = within context (Query.prepare_cached c r.sql) in
      match validated p with
      | Error _ as error -> force_close_child (Query.child p); error
      | Ok () -> cache_add c witness ~key:r.id p (Query.child p); cached p

let bind_all context p bounds =
  List.foldi bounds ~init:(Ok ()) ~f:(fun i acc (Bound (typ, value)) ->
    let* () = acc in within context (Query.bind_scalar p (i + 1) typ value))

(* Errors are in [context], by default the request's SQL. *)
let run ?context c tx r args ~consume =
  let context = Option.value context ~default:(Query r.sql) in
  let Params params = r.params in
  let* bounds = within context (encode_args params args ~index:1) in
  with_statement c tx r ~context ~use:(fun p ->
    let* () = bind_all context p bounds in
    let* result = within context (Query.execute_prepared p) in
    consume context result)

let collect_rows c tx r args =
  run c tx r args ~consume:(fun context result ->
    Result.map (fold_result context r.rows result ~init:[] ~f:(fun row rows -> Ok (Query.Continue (row :: rows))))
      ~f:List.rev)
(* Stops at a second row: its presence is all that is needed. *)
let at_most_one c tx r args ~expected =
  run c tx r args ~consume:(fun context result ->
    fold_result context r.rows result ~init:None ~f:(fun row -> function
      | None -> Ok (Query.Continue (Some row))
      | Some _ -> Error { context; cause = Row_count { expected; actual = `More_than_one } }))
let run_exec c tx r args = run c tx r args ~consume:(fun context result -> within context (Query.close_result result))
let run_find c tx r args =
  let* row = at_most_one c tx r args ~expected:`One in
  match row with
  | Some row -> Ok row
  | None -> Error { context = Query r.sql; cause = Row_count { expected = `One; actual = `Zero } }
let run_fold ?context c tx r args ~init ~f =
  run ?context c tx r args ~consume:(fun context result -> fold_result context r.rows result ~init ~f)

type ('row, 'out) shape =
  | Exec : (unit, unit) shape
  | Find : ('row, 'row) shape
  | Find_opt : ('row, 'row option) shape
  | Collect : ('row, 'row list) shape
  | Fold : { init : 'a; f : 'row -> 'a -> ('a Query.step, Failure.t) result } -> ('row, 'a) shape

(* One execution path; the shape decides how many rows are admitted. *)
let run_shape : type p row out. connection -> transaction option -> (row, out) shape -> (p, row, _) t -> p Args.t ->
  (out, Failure.t) Result.t = fun c tx shape r args ->
  match shape with
  | Exec -> run_exec c tx r args
  | Find -> run_find c tx r args
  | Find_opt -> at_most_one c tx r args ~expected:`Zero_or_one
  | Collect -> collect_rows c tx r args
  | Fold { init; f } -> run_fold c tx r args ~init ~f

let fold_on ~context c r ~init ~f = run_fold ~context c None r Args.[] ~init ~f

(* Declared tables. *)
let rec fields_of_columns : type l f r. (l, f, r) Columns.t -> (l, f, r) Fields.t = function
  | Columns.[] -> Fields.[]
  | Columns.((_, codec) :: columns) -> Fields.(codec :: fields_of_columns columns)
let column_names columns =
  List.rev (Columns.fold columns ~init:[] { g = (fun (name, _) acc -> name :: acc) })
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
let typed_failure = Native "Typed table operation failed; transaction must roll back"
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
  let* a = within context (Appender.open_appender tx ~schema:t.schema t.name) in
  let checked =
    let* () =
      if List.equal Int.equal indices (List.init (List.length catalog) ~f:Fn.id) then Ok ()
      else within context (Appender.select_columns a ~names:(Array.of_list names) ~indices:(Array.of_list indices)) in
    within context (check_types ~declared:(scalar_ids (fields_of_columns t.columns))
      ~actual:(Appender.types a)
      ~count_error:(fun expected actual -> Column_count { expected; actual })) in
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
    | Ok x -> Ok (Result.map (within context (Appender.close_appender a.core)) ~f:(fun () -> x)) in
  match capture_all (fun () -> scope ~lifting:(Cause context) work (fun () -> force_close_child (Appender.child a.core))) with
  | Ok (Ok outcome) -> outcome
  | Ok (Error cause) -> poison_transaction tx cause; Error { context; cause }
  | Error (exn, backtrace) ->
    poison_transaction tx typed_failure;
    match !primary with
    | Some e -> Stdlib.Printexc.raise_with_backtrace (Cleanup_exception (e, exn)) backtrace
    | None -> Stdlib.Printexc.raise_with_backtrace exn backtrace
(* Staging. Values are written straight into the appender's staging chunks;
   a custom encoder's rejection aborts the batch before any native append. *)
exception Stage_rejected of { index : int; reason : Base.Error.t }
module I64u = Stdlib_upstream_compatible.Int64_u
module F64u = Stdlib_upstream_compatible.Float_u
let stage_base : type b. Duckdb_ffi.appender -> b Scalar.t -> column:int -> row:int -> b -> unit =
  fun native scalar ~column ~row value ->
  match scalar with
  | Scalar.Int64 -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Timestamp_s -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Timestamp_ms -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Timestamp_us -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Timestamp_ns -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Timestamp_tz -> Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Scalar.Int32 -> Duckdb_ffi.stage_int64 native column row (I64u.of_int32 value)
  | Scalar.Date -> Duckdb_ffi.stage_int64 native column row (I64u.of_int32 value)
  | Scalar.Int16 -> Duckdb_ffi.stage_int64 native column row (I64u.of_int (Stdlib_stable.Int16.to_int value))
  | Scalar.Int8 -> Duckdb_ffi.stage_int64 native column row (I64u.of_int (Stdlib_stable.Int8.to_int value))
  | Scalar.Bool -> Duckdb_ffi.stage_int64 native column row (I64u.of_int (if value then 1 else 0))
  | Scalar.Float64 -> Duckdb_ffi.stage_float native column row (F64u.of_float value)
  | Scalar.Float32 -> Duckdb_ffi.stage_float native column row (F64u.of_float (Stdlib_stable.Float32.to_float value))
  | Scalar.String -> Duckdb_ffi.stage_string native column row value
  | Scalar.Blob -> Duckdb_ffi.stage_string native column row value
let stage_plan : type a. Duckdb_ffi.appender -> a Codec.plan -> column:int -> row:int -> index:int -> a -> unit =
  fun native plan ~column ~row ~index value ->
  match plan with
  | Codec.Identity scalar -> stage_base native scalar ~column ~row value
  | Codec.Plan p ->
    match p.encode value with
    | Ok b -> stage_base native p.scalar ~column ~row b
    | Error reason -> Stdlib.raise_notrace (Stage_rejected { index; reason })
(* Stages one row; returns the first column of it holding a NULL the catalog
   forbids. Encoding continues past such a NULL so that a later codec
   rejection still wins. *)
let rec stage_row : type l f r. Appender.appender -> Duckdb_ffi.appender -> (l, f, r) Fields.t -> l Args.t ->
  column:int -> row:int -> int option = fun a native fields args ~column ~row ->
  match fields, args with
  | Fields.[], Args.[] -> None
  | Fields.(codec :: fields), Args.(value :: args) ->
    let index = column + 1 in
    let here = match codec, value with
      | Codec.Non_null plan, value -> stage_plan native plan ~column ~row ~index value; None
      | Codec.Nullable _, None ->
        Duckdb_ffi.stage_null native column row;
        if Appender.nullable a column then None else Some column
      | Codec.Nullable plan, Some value -> stage_plan native plan ~column ~row ~index value; None in
    let rest = stage_row a native fields args ~column:(column + 1) ~row in
    match here with Some _ -> here | None -> rest
(* A codec rejection rejects the whole batch before any native append. *)
let append (type c) (a : (c, _) appender) (rows : c Args.t list) =
  let (Table_def t) = a.table in
  let context = table_context a.table in
  let fields = fields_of_columns t.columns in
  let native = Appender.native a.core in
  Duckdb_ffi.stage_begin native (List.length rows);
  let rec stage rows ~row ~first = match rows with
    | [] -> first
    | args :: rows ->
      let here = stage_row a.core native fields args ~column:0 ~row in
      let first = match first, here with
        | None, Some column -> Some (column, row)
        | _ -> first in
      stage rows ~row:(row + 1) ~first in
  match stage rows ~row:0 ~first:None with
  | exception Stage_rejected { index; reason } ->
    Duckdb_ffi.clear_stage native;
    Error { context; cause = Encode_rejected { index; reason } }
  | exception exn ->
    let backtrace = Stdlib.Printexc.get_raw_backtrace () in
    Duckdb_ffi.clear_stage native;
    Stdlib.Printexc.raise_with_backtrace exn backtrace
  | null -> within context (Appender.append_staged a.core ~null)
(* Columnar ingest. Every check runs before any native work and outside
   admission, so a rejection neither poisons nor touches the appender. *)
let rec bulk_length : type a. a Bulk.Columns.col -> int = function
  | Bulk.Columns.Int64 (_, d) -> Bigarray.Array1.dim d
  | Bulk.Columns.Int32 (_, d) -> Bigarray.Array1.dim d
  | Bulk.Columns.Int16 d -> Bigarray.Array1.dim d
  | Bulk.Columns.Int8 d -> Bigarray.Array1.dim d
  | Bulk.Columns.Bool d -> Bigarray.Array1.dim d
  | Bulk.Columns.Float64 d -> Bigarray.Array1.dim d
  | Bulk.Columns.Float32 d -> Bigarray.Array1.dim d
  | Bulk.Columns.Strings (_, s) -> Array.length s
  | Bulk.Columns.Nullable (inner, _) -> bulk_length inner
let rec bulk_scalar : type a. a Bulk.Columns.col -> Codec.packed_scalar = function
  | Bulk.Columns.Int64 (s, _) -> Codec.Packed_scalar s
  | Bulk.Columns.Int32 (s, _) -> Codec.Packed_scalar s
  | Bulk.Columns.Int16 _ -> Codec.Packed_scalar Scalar.Int16
  | Bulk.Columns.Int8 _ -> Codec.Packed_scalar Scalar.Int8
  | Bulk.Columns.Bool _ -> Codec.Packed_scalar Scalar.Bool
  | Bulk.Columns.Float64 _ -> Codec.Packed_scalar Scalar.Float64
  | Bulk.Columns.Float32 _ -> Codec.Packed_scalar Scalar.Float32
  | Bulk.Columns.Strings (s, _) -> Codec.Packed_scalar s
  | Bulk.Columns.Nullable (inner, _) -> bulk_scalar inner
let first_zero (mask : Bulk.mask) ~len =
  let rec go i = if i = len then None else if mask.{i} = 0 then Some i else go (i + 1) in
  go 0
let rec check_columns_bulk : type l f r. Appender.appender -> (l, f, r) Columns.t -> l Bulk.Columns.t ->
  column:int -> rows:int -> (unit, cause) Result.t = fun a declared bulk ~column ~rows ->
  match declared, bulk with
  | Columns.[], Bulk.Columns.[] -> Ok ()
  | Columns.((_, codec) :: declared), Bulk.Columns.(col :: bulk) ->
    let length = bulk_length col in
    let mask_length = match col with Bulk.Columns.Nullable (_, m) -> Bigarray.Array1.dim m | _ -> length in
    let custom = match codec with
      | Codec.Non_null (Codec.Plan _) -> true
      | Codec.Nullable (Codec.Plan _) -> true
      | Codec.Non_null (Codec.Identity _) -> false
      | Codec.Nullable (Codec.Identity _) -> false in
    let (Codec.Packed_scalar s) = bulk_scalar col in
    let actual = (Appender.types a).(column) in
    let* () =
      if length <> rows then Error (Length_mismatch { column; expected = rows; actual = length })
      else if mask_length <> rows then Error (Length_mismatch { column; expected = rows; actual = mask_length })
      else if custom then
        Error (Encode_rejected { index = column + 1;
          reason = Base.Error.of_string "a column with a custom codec cannot be appended in bulk" })
      else if actual <> Scalar.native_id s then
        Error (Type_mismatch { index = column; expected = Scalar.name s; actual = type_name actual })
      else match col with
        | Bulk.Columns.Nullable (_, m) when not (Appender.nullable a column) ->
          (match first_zero m ~len:rows with Some row -> Error (Null { column; row }) | None -> Ok ())
        | _ -> Ok () in
    check_columns_bulk a declared bulk ~column:(column + 1) ~rows
(* Stages input rows [pos, pos + n) into staging rows [0, n). A string under a
   NULL mask entry is never staged (so never validated). *)
let rec stage_column : type a. Duckdb_ffi.appender -> a Bulk.Columns.col -> column:int -> pos:int -> n:int -> unit =
  fun native col ~column ~pos ~n ->
  match col with
  | Bulk.Columns.Int64 (_, d) -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Int32 (_, d) -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Int16 d -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Int8 d -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Bool d -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Float64 d -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Float32 d -> Duckdb_ffi.stage_blit native column d pos n
  | Bulk.Columns.Strings (_, s) -> for i = 0 to n - 1 do Duckdb_ffi.stage_string native column i s.(pos + i) done
  | Bulk.Columns.Nullable (Bulk.Columns.Strings (_, s), m) ->
    for i = 0 to n - 1 do
      if m.{pos + i} = 0 then Duckdb_ffi.stage_null native column i
      else Duckdb_ffi.stage_string native column i s.(pos + i)
    done
  | Bulk.Columns.Nullable (inner, m) ->
    stage_column native inner ~column ~pos ~n;
    Duckdb_ffi.stage_mask native column m pos n
let rec stage_columns : type l. Duckdb_ffi.appender -> l Bulk.Columns.t -> column:int -> pos:int -> n:int -> unit =
  fun native bulk ~column ~pos ~n ->
  match bulk with
  | Bulk.Columns.[] -> ()
  | Bulk.Columns.(col :: rest) ->
    stage_column native col ~column ~pos ~n;
    stage_columns native rest ~column:(column + 1) ~pos ~n
let append_columns (type c) (a : (c, _) appender) (bulk : c Bulk.Columns.t) =
  let (Table_def t) = a.table in
  let context = table_context a.table in
  let rows = match bulk with Bulk.Columns.[] -> 0 | Bulk.Columns.(col :: _) -> bulk_length col in
  let* () = within context (check_columns_bulk a.core t.columns bulk ~column:0 ~rows) in
  let native = Appender.native a.core in
  within context (Appender.append_slices a.core ~rows ~stage:(fun ~pos ~n ->
    stage_columns native bulk ~column:0 ~pos ~n))
let flush a = within (table_context a.table) (Appender.flush_appender a.core)

(* A transaction owned by the calling scope; errors pass through flat. *)
let with_owned_transaction c ~f = Resource.with_transaction ~lifting:(Flat Transaction) c ~f

module Session = struct
  type 'k owner = 'k Session.t
  type error = Failure.t
  type 'a future = 'a
  let run (s @ local) shape r args = run_shape (Session.connection s) (Session.within s) shape r args
  let exec (s @ local) r args = run s Exec r args
  let find (s @ local) r args = run s Find r args
  let find_opt (s @ local) r args = run s Find_opt r args
  let collect (s @ local) r args = run s Collect r args
  let fold (s @ local) r args ~init ~f = run s (Fold { init; f }) r args
  let with_transaction (Session.Connection c : [ `Connection ] owner @ local) ~f =
    with_owned_transaction c ~f:(fun tx -> f (Session.Transaction tx))
  let ingest (Session.Connection c : [ `Connection ] owner @ local) table batches ~flush:explicit =
    with_owned_transaction c ~f:(fun tx ->
      with_appender_transaction tx table ~f:(fun a ->
        let* () = List.fold batches ~init:(Ok ()) ~f:(fun acc rows -> let* () = acc in append a rows) in
        if explicit then flush a else Ok ()))
end
