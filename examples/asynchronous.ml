open! Core
open! Async

module A = Duckdb_async

let core_error_name = function
  | Duckdb.Invalid_configuration _ -> "Invalid_configuration"
  | Duckdb.Embedded_nul -> "Embedded_nul"
  | Duckdb.Closed -> "Closed"
  | Duckdb.Busy -> "Busy"
  | Duckdb.Cancelled -> "Cancelled"
  | Duckdb.Live_children -> "Live_children"
  | Duckdb.Native_error _ -> "Native_error"
  | Duckdb.Unsupported_statement -> "Unsupported_statement"
  | Duckdb.Data_error _ -> "Data_error"
  | Duckdb.Destination_exists -> "Destination_exists"
  | Duckdb.Unsupported_parquet_type _ -> "Unsupported_parquet_type"
  | Duckdb.Effects_not_allowed -> "Effects_not_allowed"
  | Duckdb.Rollback_failed _ -> "Rollback_failed"

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
    let batches =
      [ [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L) ]
        ; [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 2L) ]
        ] ]
    in
    await (A.ingest pool ~schema:None ~table:"example" ~batches ~flush:true) >>= fun () ->
    let row = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
    await (A.query pool "SELECT i FROM example ORDER BY i" row) >>= fun values ->
    (* This worker fold is synchronous; do not call or suspend Async here. *)
    await (A.fold_rows pool "SELECT i FROM example ORDER BY i" row ~init:0L
      ~f:(fun (value, ()) total -> Ok (Duckdb.Continue Int64.(total + value)))) >>= fun sum ->
    let parquet = Stdlib.Filename.temp_file "duckdb_async_example" ".parquet" in
    Stdlib.Sys.remove parquet;
    Monitor.protect
      ~finally:(fun () -> if Stdlib.Sys.file_exists parquet then Stdlib.Sys.remove parquet; return ())
      (fun () ->
        await (A.parquet_export pool ~query:"SELECT i FROM example ORDER BY i" ~destination:parquet) >>= fun () ->
        (* This worker fold is synchronous; it returns owned rows only. *)
        await (A.parquet_fold_rows pool [parquet] row ~init:[]
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
