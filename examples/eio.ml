open! Base

module E = Duckdb_eio

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

let core_error_name (e : Duckdb.Error.t) = cause_name e.cause ^ " in " ^ context_name e.context

let error_name = function
  | E.Invalid_connections _ -> "Invalid_connections"
  | E.Invalid_queue_capacity _ -> "Invalid_queue_capacity"
  | E.Queue_full -> "Queue_full"
  | E.Pool_shutdown -> "Pool_shutdown"
  | E.Reentrant_call -> "Reentrant_call"
  | E.Core error -> "Core(" ^ core_error_name error ^ ")"
  | E.Lifecycle_errors _ -> "Lifecycle_errors"

(* This executable is a fatal-demo: expected errors are reported by constructor,
   then terminate rather than being silently converted to a generic exception. *)
let require label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ error_name error)

let run () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let limits = require "create Eio limits" (E.limits ~connections:1 ~queue_capacity:1) in
      let config =
        match Duckdb.Config.create Duckdb.Config.Memory with
        | Ok config -> config
        | Error error -> failwith ("create in-memory configuration: " ^ core_error_name error)
      in
      let pool = require "create Eio pool" (E.create ~sw limits config) in
      (* The pool is shut down before its switch is released. *)
      Exn.protect
        ~finally:(fun () ->
          match E.shutdown pool with
          | Ok () -> ()
          | Error error -> failwith ("Eio shutdown: " ^ error_name error))
        ~f:(fun () ->
          require "create example table" (E.execute pool "CREATE TABLE example(i BIGINT)");
          let table = Duckdb.Table.(declare "example" Columns.[ "i", int64 ] ~row:Fn.id) in
          (match E.Request.ingest pool table [ [ Duckdb.Args.[40L]; Duckdb.Args.[2L] ] ] ~flush:true with
           | Ok () -> ()
           | Error (E.Request.Adapter error) -> failwith ("ingest owned rows: " ^ error_name error)
           | Error (E.Request.Request e) -> failwith ("ingest owned rows: " ^ core_error_name e));
          let rows = Duckdb.Fields.[int64] in
          (match E.query pool "SELECT i FROM example ORDER BY i" rows ~row:Fn.id with
           | Ok values when List.length values = 2 -> ()
           | Ok _ -> failwith "typed query returned an unexpected row count"
           | Error error -> failwith ("typed query: " ^ error_name error));
          let path = Stdlib.Filename.temp_file "duckdb_eio_example" ".parquet" in
          Stdlib.Sys.remove path;
          Exn.protect
            ~finally:(fun () -> if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path)
            ~f:(fun () ->
              require "export local Parquet" (E.parquet_export pool ~query:"SELECT i FROM example ORDER BY i" ~destination:path);
              (* This worker fold is synchronous; it returns owned rows only. *)
              let values = require "fold local Parquet rows" (E.parquet_fold_rows pool [path] rows ~row:Fn.id ~init:[]
                ~f:(fun row rows -> Ok (Duckdb.Continue (row :: rows)))) in
              if List.length values <> 2 then failwith "typed Parquet fold returned an unexpected row count");
          Stdlib.Printf.printf "duckdb-eio: typed ingestion, query, local Parquet export/read, and shutdown settled\n%!")))

let () = run ()
