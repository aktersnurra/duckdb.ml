open! Base
module D = Duckdb
module B = D.Bridge
module S = Evidence_support
type seam = Execute | Rollback | Result | Prepared | Extracted | Chunk
          | Appender_clear | Appender_destroy | Disconnect | Database_close
          | Publication | Unlink
let seams = [Execute; Rollback; Result; Prepared; Extracted; Chunk;
  Appender_clear; Appender_destroy; Disconnect; Database_close; Publication; Unlink]
let id = function Execute -> 0 | Rollback -> 1 | Result -> 2 | Prepared -> 3
  | Extracted -> 4 | Chunk -> 5 | Appender_clear -> 6 | Appender_destroy -> 7
  | Disconnect -> 8 | Database_close -> 9 | Publication -> 10 | Unlink -> 11
let name = function Execute -> "execute" | Rollback -> "rollback" | Result -> "result"
  | Prepared -> "prepared" | Extracted -> "extracted" | Chunk -> "chunk"
  | Appender_clear -> "appender-clear" | Appender_destroy -> "appender-destroy"
  | Disconnect -> "disconnect" | Database_close -> "database-close"
  | Publication -> "publication" | Unlink -> "unlink"
let is_interrupted = function Execute | Rollback | Result | Prepared | Extracted | Disconnect | Database_close -> true | _ -> false
external reset : unit -> unit = "responsiveness_reset" [@@noalloc]
external activate : unit -> unit = "responsiveness_activate" [@@noalloc]
external deactivate : unit -> unit = "responsiveness_deactivate" [@@noalloc]
external set_gate : int -> bool -> unit = "responsiveness_gate" [@@noalloc]
external native_entered : int -> int = "responsiveness_entered" [@@noalloc]
external interrupts : unit -> int = "responsiveness_interrupts" [@@noalloc]
external interrupted_connections : unit -> int = "responsiveness_interrupted_connections" [@@noalloc]
external native_errors : unit -> int = "responsiveness_native_errors" [@@noalloc]
external executions : unit -> int = "responsiveness_executions" [@@noalloc]
external joins : unit -> int = "responsiveness_joins" [@@noalloc]
external finish_calls : unit -> int = "responsiveness_finish_calls" [@@noalloc]
external locked_engine_calls : unit -> int = "responsiveness_locked_engine_calls" [@@noalloc]
external fail_rollback : bool -> unit = "responsiveness_fail_rollback" [@@noalloc]
let hold seam = set_gate (id seam) true
let release seam = set_gate (id seam) false
let entered seam = native_entered (id seam)
let release_all () = List.iter seams ~f:release
let check label value = if not value then failwith label
let ok = function Ok x -> x | Error _ -> failwith "responsiveness DuckDB error"
let check_settled r =
  check "Bridge settlement" (match B.settlement r with Settled -> true | Pending -> false);
  check "terminal cancellation Closed" (match B.cancel r with Error Closed -> true | _ -> false)
let check_inventory () =
  check "ordinary cleanup no locked engine calls" (locked_engine_calls () = 0);
  check "ordinary cleanup visited finish paths" (finish_calls () > 0);
  check "all binding resources released without GC" (Duckdb_ffi.live_resources () = 0);
  check "no finalizer fallback" (Duckdb_ffi.fallback_reclaims () = 0)
let check_outcome seam outcome =
  if is_interrupted seam then (match outcome with
    | Error (D.Native_error message) ->
      check "real native interrupted diagnostic" (String.is_substring (String.lowercase message) ~substring:"interrupt")
    | _ -> failwith "native interrupted error was flattened")
  else match outcome with Error D.Cancelled -> () | _ -> failwith "missing latched cancellation"
let long_query = "SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)"
let with_owner f = D.with_database (ok (D.Config.create Memory)) ~f:(fun db -> D.with_connection db ~f)
let suppressed_work request =
  Exn.protect ~finally:deactivate ~f:(fun () -> with_owner (fun owner ->
    activate ();
    B.run request owner ~f:(fun facade ->
      (* Finite real native work makes a missing final dispatch check observable. *)
      ignore (D.execute facade "SELECT 1");
      failwith "cancelled dispatched callback entered")))
let reused_work previous current =
  Exn.protect ~finally:deactivate ~f:(fun () -> with_owner (fun owner ->
    ok (B.run previous owner ~f:(fun facade -> D.execute facade "SELECT 1"));
    B.run current owner ~f:(fun facade ->
      activate (); D.execute facade "SELECT 42")))
let work seam request =
  Exn.protect ~finally:deactivate ~f:(fun () ->
    with_owner (fun owner ->
      B.run request owner ~f:(fun facade ->
        if is_interrupted seam then
          D.with_transaction facade ~f:(fun tx -> activate (); D.execute_transaction tx long_query)
        else match seam with
        | Chunk ->
          D.with_prepared facade "SELECT 42::BIGINT" ~f:(fun p ->
            let r = ok (D.execute_prepared p) in
            D.fold_chunks r ~init:() ~f:(fun _chunk () ->
              activate (); ok (B.cancel request); Ok (D.Stop ())))
        | Appender_clear | Appender_destroy ->
          ok (D.execute facade "CREATE TABLE t(x BIGINT)");
          D.with_appender facade "t" ~f:(fun a ->
            ok (D.append_rows a [[D.Cell (D.Scalar.Required D.Scalar.Int64, 42L)]]);
            activate (); ok (B.cancel request); Ok ())
        | Publication | Unlink ->
          let destination = Stdlib.Filename.temp_file "bridge-heartbeat-" ".parquet" in
          Stdlib.Sys.remove destination;
          Exn.protect ~finally:(fun () ->
            (* Gate only the binding's real owned-temp unlink, not fixture cleanup. *)
            deactivate ();
            if Stdlib.Sys.file_exists destination then Stdlib.Sys.remove destination)
            ~f:(fun () ->
              let path = ok (D.Parquet.path destination) in
              activate (); D.Parquet.export facade ~query:"SELECT 42::BIGINT AS x" path)
        | Execute | Rollback | Result | Prepared | Extracted | Disconnect | Database_close -> assert false)))
exception Worker_failure
exception Cleanup_failure
let callback_failure_frame () =
  raise (Sys.opaque_identity Worker_failure)
let exceptional_work ~fail_cleanup request =
  Stdlib.Callback.Safe.register_exception "responsiveness_cleanup_failure" Cleanup_failure;
  Exn.protect ~finally:(fun () -> fail_rollback false; deactivate ()) ~f:(fun () ->
    ignore (Sys.opaque_identity (with_owner (fun owner ->
      B.run request owner ~f:(fun facade ->
        D.with_transaction facade ~f:(fun tx ->
          ok (D.execute_transaction tx "CREATE TABLE t(x INTEGER)");
          activate (); fail_rollback fail_cleanup; callback_failure_frame ()))))))
let check_exception ~fail_cleanup = function
  | S.Raised failure ->
    (match failure.exception_ with
     | Exn.Finally (primary, cleanup) when fail_cleanup ->
       check "worker identity in cleanup composite" (phys_equal primary Worker_failure);
       check "cleanup identity in composite" (phys_equal cleanup Cleanup_failure)
     | exn when not fail_cleanup -> check "worker identity" (phys_equal exn Worker_failure)
     | _ -> failwith "lost primary/cleanup composite");
    check "source-specific callback trace transported"
      (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string failure.backtrace) ~substring:"callback_failure_frame")
  | S.Returned () -> failwith "worker exception became success"
