open! Base
open Duckdb
external arm : int -> int -> unit = "signal_arm" [@@noalloc]
external target : int -> bool -> unit = "stage3c_target" [@@noalloc]
external trigger : unit -> unit = "signal_trigger" [@@noalloc]
external injections : unit -> int = "signal_injections" [@@noalloc]
external live : unit -> int = "signal_live" [@@noalloc]
let handled = Stdlib.Atomic.make 0
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let rec is_break = function
  | Stdlib.Sys.Break -> true
  | Rollback_exception (e,_) | Cleanup_exception (_,e) | Request.Cleanup_exception (_,e) -> is_break e
  | Exn.Finally (a,b) -> is_break a || is_break b
  | _ -> false
let core r = Result.map_error r ~f:(fun (e : Request.request_error) ->
  match e.cause with Request.Core e -> e | _ -> Native_error "unexpected typed failure")
let count c = ok (with_prepared c "SELECT count(*) FROM a" ~f:(fun p ->
  fold_chunks (ok (execute_prepared p)) ~init:0L ~f:(fun chunk _ ->
    match column chunk ~column:0 ~row:0 Codec.Values.int64 with Ok n -> Ok (Stop n) | Error e -> Error e)))
let () =
  let mode = Stdlib.Sys.argv.(1) in
  let leave = String.is_suffix mode ~suffix:"-leave" in
  let inject name = if String.equal mode (name ^ (if leave then "-leave" else "-enter")) then arm (if leave then 0 else 1) (if leave then 1 else 0) in
  let file = Stdlib.Filename.temp_file "stage3c-signal-" ".parquet" in
  Stdlib.Sys.remove file;
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1 (Stdlib.Sys.Signal_handle (fun _ ->
    Stdlib.Atomic.incr handled; raise Stdlib.Sys.Break)) in
  Exn.protect ~finally:(fun () ->
    arm 0 0; target 0 false; Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous;
    if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file) ~f:(fun () ->
    ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
      ok (execute c "CREATE TABLE a(x VARCHAR)");
      let caught =
        try Stdlib.Sys.with_async_exns (fun () ->
          if String.is_prefix mode ~prefix:"export" then (
            target (if String.is_prefix mode ~prefix:"export-copy" then 1
              else if String.is_substring mode ~substring:"remove" then 3 else 2) leave;
            let query = if String.is_prefix mode ~prefix:"export-fail" then "SELECT CAST('bad' AS BIGINT)"
              else "SELECT 9007199254740993::BIGINT" in
            ok (Parquet.export c ~query (ok (Parquet.path file))))
          else ok (with_transaction c ~f:(fun tx ->
            (* The declared table's catalog query runs first; arm at the
               native appender creation itself. *)
            if String.is_prefix mode ~prefix:"create" then target 5 leave;
            let table = Table.(declare "a" Columns.[ "x", string ] ~row:Fn.id) in
            let result = core (Table.with_appender_transaction tx table ~f:(fun a ->
              inject "append";
              ok (core (Table.append a [Args.[String.make 10000 'x' ^ "\000end"]]));
              inject "flush"; ok (core (Table.flush a));
              if String.equal mode "callback" then (trigger ();Stdlib.Gc.minor ());
              if String.is_prefix mode ~prefix:"discard" then (
                inject "discard";
                Error { Request.context = Request.Transaction; cause = Request.Core (Native_error "primary callback") })
              else (
                (* The scope's close flushes, then clears/destroys. *)
                inject "close-flush";
                if String.equal mode "close-enter" || String.equal mode "close-leave" then target 4 leave;
                Ok ()))) in
            inject "commit"; result));
          Stdlib.Gc.minor ()); false
        with e when is_break e -> true in
      assert caught;
      if String.equal mode "commit-leave" then (
        assert (match execute c "SELECT 1" with Error Closed -> true | _ -> false);
        ok (with_connection db ~f:(fun observer -> assert (Int64.equal (count observer) 1L); Ok ())))
      else (assert (Int64.equal (count c) 0L); ok (execute c "SELECT 1"));
      if String.equal mode "export-publish-leave" || String.is_prefix mode ~prefix:"export-remove" then assert (Stdlib.Sys.file_exists file)
      else assert (not (Stdlib.Sys.file_exists file));
      Ok ()))) ;
    let expected = match mode with
      | "create-enter" -> 7 | "create-leave" -> 10
      | "append-enter" -> 12 | "append-leave" -> 10
      | "flush-enter" | "flush-leave" | "close-flush-enter" | "close-flush-leave"
      | "close-enter" | "discard-enter" | "callback" -> 10
      | "close-leave" | "discard-leave" -> 9
      (* Named COMMIT uses an immutable C literal, not an owned SQL copy. *)
      | "commit-enter" -> 4 | "commit-leave" -> 4
      | "export-copy-enter" -> 6 | "export-copy-leave" -> 7
      | "export-publish-enter" | "export-publish-leave" -> 7
      | "export-remove-enter" | "export-remove-leave" | "export-fail-remove-enter" | "export-fail-remove-leave" -> 6
      | _ -> failwith "unknown mode" in
    Stdlib.Printf.printf "%s live=%d expected=%d\n%!" mode (live ()) expected;
    assert (live () = expected); assert (injections () = 1); assert (Stdlib.Atomic.get handled = 1);
    assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
    Stdlib.print_endline "single Break preserved, connection clean or discarded, zero binding resources/fallback")
