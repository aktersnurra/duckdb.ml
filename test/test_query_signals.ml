open! Base
module D = Duckdb
external arm : int -> int -> unit = "signal_arm" [@@noalloc]
external trigger : unit -> unit = "signal_trigger" [@@noalloc]
external injections : unit -> int = "signal_injections" [@@noalloc]
external live_at_signal : unit -> int = "signal_live" [@@noalloc]
let handled = Stdlib.Atomic.make 0
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let rec contains_break = function
  | Stdlib.Sys.Break -> true
  | D.Rollback_exception (exn, _) | D.Cleanup_exception (_, exn) -> contains_break exn
  | Exn.Finally (a, b) -> contains_break a || contains_break b
  | _ -> false
let () =
  let mode = Stdlib.Sys.argv.(1) in
  let inject operation =
    if String.equal mode (operation ^ "-enter") then arm 1 0;
    if String.equal mode (operation ^ "-leave") then arm 0 1 in
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1
    (Stdlib.Sys.Signal_handle (fun _ -> Stdlib.Atomic.incr handled; raise Stdlib.Sys.Break)) in
  Exn.protect ~finally:(fun () -> arm 0 0; Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous) ~f:(fun () ->
    (match Stdlib.Sys.with_async_exns (fun () ->
      ok (D.with_database (ok (D.Config.create Memory)) ~f:(fun db ->
        D.with_connection db ~f:(fun c ->
          inject "prepare";
          let bind_kind = if String.is_prefix mode ~prefix:"bind-int" then "BIGINT"
            else if String.is_prefix mode ~prefix:"bind-float" then "DOUBLE" else "VARCHAR" in
          D.with_prepared c ("SELECT ?::" ^ bind_kind ^ ", i FROM range(5000) t(i)") ~f:(fun p ->
            if String.is_prefix mode ~prefix:"bind-int" then (
              inject "bind-int"; ok (D.bind p 1 (D.Scalar.Required D.Scalar.Int64) 42L))
            else if String.is_prefix mode ~prefix:"bind-float" then (
              inject "bind-float"; ok (D.bind p 1 (D.Scalar.Required D.Scalar.Float64) 0.1))
            else if String.is_prefix mode ~prefix:"bind-null" then (
              inject "bind-null"; ok (D.bind p 1 (D.Scalar.Nullable D.Scalar.String) None))
            else (inject "bind"; ok (D.bind p 1 (D.Scalar.Required D.Scalar.String) (String.make 10000 'b')));
            if String.is_prefix mode ~prefix:"reset" then (inject "reset"; ok (D.reset p))
            else if String.is_prefix mode ~prefix:"prepared-close" then (
              inject "prepared-close";
              try ok (D.close_prepared p) with Stdlib.Sys.Break ->
                (match D.parameter_count p with Error D.Closed -> () | _ -> failwith "interrupted close did not revoke prepared");
                ok (D.execute c "select 1"); raise Stdlib.Sys.Break)
            else (
              inject "execute";
              let r = ok (D.execute_prepared p) in
              if String.is_prefix mode ~prefix:"result-close" then (
                inject "result-close";
                try ok (D.close_result r) with Stdlib.Sys.Break ->
                  ok (D.reset p); ok (D.execute c "select 1"); raise Stdlib.Sys.Break)
              else (
                inject "fetch";
                ignore (ok (D.fold_chunks r ~init:0 ~f:(fun chunk n ->
                  assert (D.chunk_length chunk > 0);
                  if String.equal mode "callback" then (trigger (); Stdlib.Gc.minor ());
                  if String.is_prefix mode ~prefix:"next-fetch" && n = 0 then inject "next-fetch";
                  if String.is_prefix mode ~prefix:"chunk-close" then (inject "chunk-close"; Ok (D.Stop n))
                  else Ok (D.Continue (n + 1)))) : int)));
            Ok ()))));
      Stdlib.Gc.minor ()) with
     | exception exn when contains_break exn -> ()
     | exception exn -> raise exn
     | () -> failwith "missing Break");
    let expected = match mode with
      | "bind-enter" | "execute-leave" | "fetch-enter" | "result-close-enter" -> 7
      | "prepare-enter" | "prepare-leave" | "bind-leave" | "reset-enter" | "reset-leave" | "execute-enter" | "prepared-close-enter" | "result-close-leave" -> 6
      | "prepared-close-leave" -> 5
      | "fetch-leave" | "next-fetch-enter" | "next-fetch-leave" | "callback" | "chunk-close-enter" -> 8
      | "chunk-close-leave" | "bind-int-enter" | "bind-int-leave" | "bind-float-enter" | "bind-float-leave"
      | "bind-null-enter" | "bind-null-leave" -> 6
      | _ -> failwith "unknown test mode" in
    Stdlib.Printf.printf "%s: live-at-signal=%d expected=%d\n%!" mode (live_at_signal ()) expected;
    assert (live_at_signal () = expected);
    assert (injections () = 1); assert (Stdlib.Atomic.get handled = 1);
    assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
    Stdlib.Printf.printf "%s: single-Break prepared/result/chunk deterministic-cleanup=ok\n%!" mode)
