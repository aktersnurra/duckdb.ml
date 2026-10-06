open! Core
open! Async

module A = Duckdb_async

let cause_name : Duckdb.Error.cause -> string = function
  | Invalid_configuration _ -> "Invalid_configuration" | Embedded_nul -> "Embedded_nul" | Closed -> "Closed"
  | Busy -> "Busy" | Cancelled -> "Cancelled" | Native _ -> "Native"
  | Unsupported_statement -> "Unsupported_statement" | Effects_not_allowed -> "Effects_not_allowed"
  | Type_mismatch _ -> "Type_mismatch" | Null _ -> "Null" | Index _ -> "Index"
  | Length_mismatch _ -> "Length_mismatch"
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
  | A.Invalid_connections _ -> "Invalid_connections"
  | A.Invalid_queue_capacity _ -> "Invalid_queue_capacity"
  | A.Queue_full -> "Queue_full"
  | A.Pool_shutdown -> "Pool_shutdown"
  | A.Cancelled -> "Cancelled"
  | A.Reentrant_call -> "Reentrant_call"
  | A.Core error -> "Core(" ^ core_error_name error ^ ")"
  | A.Offload_unavailable _ -> "Offload_unavailable"

let failure_name = function
  | A.Expected error -> "Expected(" ^ error_name error ^ ")"
  | A.Raised _ -> "Raised"
  | A.During_cleanup _ -> "During_cleanup"
  | A.During_cancellation _ -> "During_cancellation"

(* This executable is a fatal-demo: expected errors are reported by constructor,
   then terminate rather than being silently converted to a generic exception. *)
let require label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ error_name error)

let require_failure label = function
  | Ok value -> value
  | Error failure -> failwith (label ^ ": " ^ failure_name failure)

let await request =
  let request = require "admit Async request" request in
  require "register Async completion" (A.completion request)
  >>| require_failure "await Async completion"

let example () =
  let limits = require "create Async limits" (A.Limits.create ~connections:2 ~queue_capacity:4) in
  let config =
    match Duckdb.Config.create Memory with
    | Ok config -> config
    | Error error -> failwith ("create in-memory configuration: " ^ core_error_name error)
  in
  A.create limits config >>= fun created ->
  let pool = require_failure "create Async pool" created in
  (* Shutdown is awaited even if request completion fails. *)
  Monitor.protect
    ~finally:(fun () -> require "request Async shutdown" (A.shutdown pool) >>| require_failure "await Async shutdown")
    (fun () ->
    await (A.execute pool "CREATE TABLE example(i BIGINT)") >>= fun () ->
    let table = Duckdb.Table.(declare "example" Columns.[ "i", int64 ] ~row:Fn.id) in
    A.Request.ingest pool table [ [ Duckdb.Args.[1L]; Duckdb.Args.[2L] ] ] ~flush:true >>| (function
      | Ok () -> ()
      | Error (A.Request.Adapter failure) -> failwith ("ingest: " ^ failure_name failure)
      | Error (A.Request.Request e) -> failwith ("ingest: " ^ core_error_name e))
    >>= fun () ->
    (* The transaction token is local to this synchronous worker callback. *)
    let count = Duckdb.Request.one Duckdb.Fields.[] Duckdb.Fields.[int64] ~row:Fn.id "SELECT count(*) FROM example" in
    A.Request.with_transaction pool ~f:(fun transaction ->
      Duckdb.Request.Session.find transaction count Duckdb.Args.[]) >>| (function
      | Ok 2L -> ()
      | Ok _ -> failwith "transaction count returned an unexpected value"
      | Error (A.Request.Adapter failure) -> failwith ("transaction: " ^ failure_name failure)
      | Error (A.Request.Request e) -> failwith ("transaction: " ^ core_error_name e))
    >>= fun () ->
    let row = Duckdb.Fields.[int64] in
    await (A.query pool "SELECT i FROM example ORDER BY i" row ~row:Fn.id) >>= fun values ->
    (* This worker fold is synchronous; do not call or suspend Async here. *)
    await (A.fold_rows pool "SELECT i FROM example ORDER BY i" row ~row:Fn.id ~init:0L
      ~f:(fun value total -> Ok (Duckdb.Continue Int64.(total + value)))) >>= fun sum ->
    let parquet = Stdlib.Filename.temp_file "duckdb_async_example" ".parquet" in
    Stdlib.Sys.remove parquet;
    Monitor.protect
      ~finally:(fun () -> if Stdlib.Sys.file_exists parquet then Stdlib.Sys.remove parquet; return ())
      (fun () ->
        await (A.parquet_export pool ~query:"SELECT i FROM example ORDER BY i" ~destination:parquet) >>= fun () ->
        (* This worker fold is synchronous; it returns owned rows only. *)
        await (A.parquet_fold_rows pool [parquet] row ~row:Fn.id ~init:[]
          ~f:(fun value values -> Ok (Duckdb.Continue (value :: values)))) >>= fun parquet_values ->
        Stdlib.Printf.printf "ingested %d rows; query/fold sum=%Ld; Parquet read %d owned rows\n%!"
          (List.length values) sum (List.length parquet_values);
        return ()))
  >>| fun () -> Stdlib.print_endline "duckdb-async: example completed and shutdown settled"

let run () =
  don't_wait_for (Monitor.try_with example >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> Stdlib.prerr_endline (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())

let () = run ()
