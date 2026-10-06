open! Base

module D = Duckdb
module R = D.Request

let cause_name : Duckdb.Error.cause -> string = function
  | Invalid_configuration _ -> "Invalid_configuration" | Embedded_nul -> "Embedded_nul" | Closed -> "Closed"
  | Busy -> "Busy" | Cancelled -> "Cancelled" | Native _ -> "Native"
  | Unsupported_statement -> "Unsupported_statement" | Effects_not_allowed -> "Effects_not_allowed"
  | Type_mismatch _ -> "Type_mismatch" | Null _ -> "Null" | Index _ -> "Index"
  | Unbound_parameter _ -> "Unbound_parameter" | Parameter_count _ -> "Parameter_count"
  | Column_count _ -> "Column_count" | Parameter_schema_changed -> "Parameter_schema_changed"
  | Row_count _ -> "Row_count" | Unknown_column _ -> "Unknown_column" | Missing_column _ -> "Missing_column"
  | Encode_rejected _ -> "Encode_rejected" | Decode_rejected _ -> "Decode_rejected"
  | Destination_exists -> "Destination_exists" | Unsupported_parquet_type _ -> "Unsupported_parquet_type"
  | Rollback_failed _ -> "Rollback_failed"

let context_name : Duckdb.Error.context -> string = function
  | Database -> "database" | Connection -> "connection" | Transaction -> "transaction"
  | Query sql -> "query " ^ sql | Table { schema; name } -> "table " ^ schema ^ "." ^ name
  | Parquet path -> "Parquet " ^ path

let error_name (e : Duckdb.Error.t) = cause_name e.cause ^ " in " ^ context_name e.context

(* The Parquet roundtrip below is a fatal-demo: expected errors are reported
   by constructor, then terminate rather than being silently converted to a
   generic exception. *)
let require label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ error_name error)

(* Requests and tables are plain values: declared once, checked against the
   engine when first used, and cached per connection. *)
let example = D.Table.(declare "example" Columns.[ "value", int64; "note", string ]
  ~row:(fun value note -> value, note))
let create_example = R.exec D.Fields.[] "create table example(value bigint, note varchar)"
let insert_example = D.Table.insert example
let count_example = R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id "select count(*) from example"

(* Handles are local to their scope, so results are threaded without [let*]:
   a binding operator's continuation is a global closure and cannot use a
   local handle. Several steps: [match]. A helper that only passes the handle
   along is inferred local; annotate [(c @ local)] when the compiler reports
   an escape at the call site. *)
let setup (connection @ local) =
  match R.Session.exec connection create_example D.Args.[] with
  | Error _ as error -> error
  | Ok () ->
    match R.Session.with_transaction connection ~f:(fun transaction ->
      R.Session.exec transaction insert_example D.Args.[42L; "owned\000text"]) with
    | Error _ as error -> error
    | Ok () ->
      D.Table.with_appender connection example ~f:(fun appender ->
        D.Table.append appender [D.Args.[9007199254740993L; "bulk\000row"]])

(* The low-level escape hatch: positional binding and borrowed chunks, read
   inside the result lease. Chunk values are copied out as owned values. *)
let sum_above (session @ local) threshold =
  D.Statement.with_prepared session "select value from example where value > ?" ~f:(fun prepared ->
    match D.Statement.bind prepared 1 D.Fields.int64 threshold with
    | Error error -> Error error
    | Ok () ->
      D.Statement.fold_chunks prepared ~init:0L ~f:(fun chunk total ->
        let rec loop row total =
          if row = D.Statement.chunk_length chunk then Ok (D.Continue total)
          else match D.Statement.column chunk ~column:0 ~row D.Fields.int64 with
            | Error error -> Error error
            | Ok value -> loop (row + 1) Int64.(total + value)
        in
        loop 0 total [@nontail]))

(* One step: Base's [Result.bind] takes a local [~f], so the continuation may
   use the handle. A local closure cannot be an argument in a tail call, hence
   [@nontail]. *)
let count_and_sum (session @ local) =
  Result.bind (R.Session.find session count_example D.Args.[]) ~f:(fun count ->
    Result.map (sum_above session 0L) ~f:(fun sum -> count, sum)) [@nontail]

let () =
  let config = require "create in-memory configuration" (D.Config.create Memory) in
  let (count, sum), values = require "run example" (D.with_database config ~f:(fun database ->
    D.with_connection database ~f:(fun connection ->
      match setup connection with
      | Error error -> Error error
      | Ok () ->
        match count_and_sum connection with
        | Error error -> Error error
        | Ok totals ->
          (* The file is owned by this example and removed on every exit path. *)
          let file = Stdlib.Filename.temp_file "duckdb-synchronous-" ".parquet" in
          Stdlib.Sys.remove file;
          let rows = Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file)
            ~f:(fun () ->
              let path = require "construct local Parquet path" (D.Parquet.path file) in
              require "export local Parquet" (D.Parquet.export connection ~query:"select value, note from example order by value" path);
              (* The fold callback is synchronous; it only builds owned rows. *)
              require "read local Parquet" (D.Parquet.fold_table connection [path] example ~init:[]
                ~f:(fun row rows -> Ok (D.Continue (row :: rows))))) in
          Ok (totals, rows)))) in
  Stdlib.Printf.printf "%Ld rows, statement sum %Ld\n" count sum;
  List.iter values ~f:(fun (value, note) -> Stdlib.Printf.printf "owned row: %Ld, %d bytes\n" value (String.length note));
  Stdlib.print_endline "synchronous typed request/table transaction and local Parquet roundtrip complete"
