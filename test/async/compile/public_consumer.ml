open! Base
module A = Duckdb_async
let submit pool = A.transaction pool ~f:(fun tx ->
  Result.map (Duckdb.execute_transaction tx "select 42") ~f:(fun () -> "owned"))
let observe request = A.completion request
let typed pool =
  let row = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
  A.query pool "SELECT 1::BIGINT" row
let lifecycle limits config =
  Async.Deferred.bind (A.create limits config) ~f:(function
    | Error _ -> Async.Deferred.unit
    | Ok pool ->
      (match A.execute pool "select 1" with
       | Error _ -> ()
       | Ok request -> ignore (A.cancel request : (A.cancel_ack, A.error) result));
      match A.shutdown pool with
      | Error _ -> Async.Deferred.unit
      | Ok settled -> Async.Deferred.map settled ~f:(fun _ -> ()))
let rec failures = function
  | A.Expected error ->
    (match error with
     | A.Invalid_connections _ | A.Invalid_queue_capacity _ | A.Queue_full
     | A.Pool_shutdown | A.Cancelled | A.Reentrant_call | A.Core _
     | A.Offload_unavailable _ -> [])
  | A.Raised { exception_; backtrace = _ } -> [exception_]
  | A.During_cleanup {primary; cleanup} -> failures primary @ failures cleanup
  | A.During_cancellation failure -> failures failure
