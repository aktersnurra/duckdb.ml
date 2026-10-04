open! Base

module D = Duckdb
module R = D.Request

let error_name = function
  | D.Invalid_configuration _ -> "Invalid_configuration"
  | Embedded_nul -> "Embedded_nul"
  | Closed -> "Closed"
  | Busy -> "Busy"
  | Cancelled -> "Cancelled"
  | Live_children -> "Live_children"
  | Native_error _ -> "Native_error"
  | Unsupported_statement -> "Unsupported_statement"
  | Data_error _ -> "Data_error"
  | Destination_exists -> "Destination_exists"
  | Unsupported_parquet_type _ -> "Unsupported_parquet_type"
  | Effects_not_allowed -> "Effects_not_allowed"
  | Rollback_failed _ -> "Rollback_failed"

let request_error_name (e : R.request_error) = match e.cause with
  | R.Core core -> error_name core
  | Parameter_count _ -> "Parameter_count"
  | Row_count _ -> "Row_count"
  | Unknown_column _ -> "Unknown_column"
  | Missing_column _ -> "Missing_column"
  | Encode_rejected _ -> "Encode_rejected"
  | Decode_rejected _ -> "Decode_rejected"
  | Rollback_failed _ -> "Rollback_failed"

(* This executable is a fatal-demo: expected errors are reported by constructor,
   then terminate rather than being silently converted to a generic exception. *)
let require label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ error_name error)
let require_request label = function
  | Ok value -> value
  | Error (e : R.request_error) ->
    failwith (label ^ ": " ^ request_error_name e ^ " in " ^ R.query_of_context e.context)

(* Requests and tables are plain values: declared once, checked against the
   engine when first used, and cached per connection. *)
let example = D.Table.(declare "example" Columns.[ "value", int64; "note", string ]
  ~row:(fun value note -> value, note))
let create_example = R.exec D.Fields.[] "create table example(value bigint, note varchar)"
let insert_example = D.Table.insert example

let () =
  let config = require "create in-memory configuration" (D.Config.create Memory) in
  let values = require "open database" (D.with_database config ~f:(fun database ->
    D.with_connection database ~f:(fun connection ->
      require_request "create example table" (R.Connection.exec connection create_example D.Args.[]);
      require_request "run insert transaction" (R.Connection.with_transaction connection ~f:(fun transaction ->
        R.Transaction.exec transaction insert_example D.Args.[42L; "owned\000text"]));
      require_request "append owned rows" (D.Table.with_appender connection example ~f:(fun appender ->
        D.Table.append appender [D.Args.[9007199254740993L; "bulk\000row"]]));
      (* The file is owned by this example and removed on every exit path. *)
      let file = Stdlib.Filename.temp_file "duckdb-synchronous-" ".parquet" in
      Stdlib.Sys.remove file;
      Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file)
        ~f:(fun () ->
          let path = require "construct local Parquet path" (D.Parquet.path file) in
          require "export local Parquet" (D.Parquet.export connection ~query:"select value, note from example order by value" path);
          (* The fold callback is synchronous; it only builds owned rows. *)
          Ok (require_request "read local Parquet" (D.Parquet.fold_table connection [path] example ~init:[]
            ~f:(fun row rows -> Ok (D.Continue (row :: rows))))))))) in
  List.iter values ~f:(fun (value, note) -> Stdlib.Printf.printf "owned row: %Ld, %d bytes\n" value (String.length note));
  Stdlib.print_endline "synchronous typed request/table transaction and local Parquet roundtrip complete"
