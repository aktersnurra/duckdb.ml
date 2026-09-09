open! Base

module D = Duckdb

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

(* This executable is a fatal-demo: expected errors are reported by constructor,
   then terminate rather than being silently converted to a generic exception. *)
let require label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ error_name error)

let () =
  let config = require "create in-memory configuration" (D.Config.create Memory) in
  let values = require "open database" (D.with_database config ~f:(fun database ->
    D.with_connection database ~f:(fun connection ->
      require "create example table" (D.execute connection "create table example(value bigint, note varchar)");
      require "run insert transaction" (D.with_transaction connection ~f:(fun transaction ->
        D.with_prepared_transaction transaction "insert into example values (?, ?)" ~f:(fun statement ->
          require "bind integer parameter" (D.bind statement 1 (D.Scalar.Required D.Scalar.Int64) 42L);
          require "bind string parameter" (D.bind statement 2 (D.Scalar.Required D.Scalar.String) "owned\000text");
          D.close_result (require "execute prepared insert" (D.execute_prepared statement)))));
      require "append owned rows" (D.with_appender connection "example" ~f:(fun appender ->
        D.append_rows appender [[D.Cell (D.Scalar.Required D.Scalar.Int64, 9007199254740993L);
          D.Cell (D.Scalar.Required D.Scalar.String, "bulk\000row")]]));
      (* The file is owned by this example and removed on every exit path. *)
      let file = Stdlib.Filename.temp_file "duckdb-synchronous-" ".parquet" in
      Stdlib.Sys.remove file;
      Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file)
        ~f:(fun () ->
          let path = require "construct local Parquet path" (D.Parquet.path file) in
          require "export local Parquet" (D.Parquet.export connection ~query:"select value, note from example order by value" path);
          let decoder = D.Row.(Map (Column (D.Scalar.Required D.Scalar.Int64,
            Column (D.Scalar.Required D.Scalar.String, Empty)), fun (value, (note, ())) -> value, note)) in
          (* The fold callback is synchronous; it only builds owned rows. *)
          D.Parquet.fold_rows connection [path] decoder ~init:[]
            ~f:(fun row rows -> Ok (D.Continue (row :: rows))))))) in
  List.iter values ~f:(fun (value, note) -> Stdlib.Printf.printf "owned row: %Ld, %d bytes\n" value (String.length note));
  Stdlib.print_endline "synchronous prepared/appender transaction and local Parquet roundtrip complete"
