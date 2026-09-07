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
  let persistent = String.is_prefix mode ~prefix:"commit" in
  let path = if persistent then Some (Stdlib.Filename.temp_file "duckdb-signal" ".db") else None in
  Option.iter path ~f:Stdlib.Sys.remove;
  let config = ok (D.Config.create (match path with None -> Memory | Some path -> File path)) in
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1
    (Stdlib.Sys.Signal_handle (fun _ -> Stdlib.Atomic.incr handled; raise Stdlib.Sys.Break)) in
  let inject operation =
    if String.equal mode (operation ^ "-enter") then arm 1 0;
    if String.equal mode (operation ^ "-leave") then arm 0 1
  in
  Exn.protect ~finally:(fun () -> arm 0 0; Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous;
    Option.iter path ~f:Stdlib.Sys.remove) ~f:(fun () ->
    (match Stdlib.Sys.with_async_exns (fun () ->
      inject "open";
      let result = D.with_database config ~f:(fun db ->
        if String.is_prefix mode ~prefix:"database-close" then (inject "database-close"; Ok ())
        else (
          inject "connect";
          D.with_connection db ~f:(fun c ->
            ok (D.execute c "create table t(i integer)");
            if String.is_prefix mode ~prefix:"transaction" || String.is_prefix mode ~prefix:"rollback" || persistent then (
              inject "transaction";
              let transaction_result () = D.with_transaction c ~f:(fun tx ->
                ok (D.execute_transaction tx "insert into t values (1)");
                if String.equal mode "transaction-callback" || String.equal mode "transaction-rollback" then
                  (trigger (); Stdlib.Gc.minor ());
                if String.is_prefix mode ~prefix:"rollback" then (inject "rollback"; Error D.Effects_not_allowed)
                else (inject "commit"; Ok ())) in
              if String.equal mode "transaction-rollback" then (
                match transaction_result () with
                | exception Stdlib.Sys.Break ->
                  ok (D.execute c "select case when count(*)=0 then 1 else error('signal rollback') end from t");
                  raise Stdlib.Sys.Break
                | _ -> failwith "callback Break missing")
              else transaction_result ())
            else if String.is_prefix mode ~prefix:"connection-close" then (inject "connection-close"; Ok ())
            else (inject "query"; D.execute c "select sum(i) from range(10000) t(i)")))) in
      Stdlib.Gc.minor (); result) with
     | exception exn when contains_break exn ->
       if String.is_prefix mode ~prefix:"rollback" then (
         match exn with
         | D.Cleanup_exception (D.Effects_not_allowed, Stdlib.Sys.Break) -> ()
         | _ -> failwith "rollback lost primary result error");
       if String.equal mode "commit-leave" then (
         match exn with D.Rollback_exception (Stdlib.Sys.Break, D.Native_error _) -> ()
         | _ -> failwith "post-commit interruption must preserve failed rollback")
     | exception exn -> raise exn
     | _ -> failwith "no Break");
    if persistent then (
      let count = if String.equal mode "commit-leave" then "1" else "0" in
      ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c ->
        D.execute c ("select case when count(*)=" ^ count ^
          " then 1 else error('commit boundary') end from t")))));
    let expected_live = match mode with
      | "open-enter" | "open-leave" | "database-close-enter" -> 2
      | "database-close-leave" -> 1
      | "connect-enter" | "connection-close-leave" -> 3
      | "query-enter" | "transaction-enter" | "rollback-enter" | "commit-enter" -> 5
      | _ -> 4 in
    assert (live_at_signal () = expected_live);
    assert (injections () = 1); assert (Stdlib.Atomic.get handled = 1);
    assert (Duckdb_ffi.live_resources () = 0);
    assert (Duckdb_ffi.fallback_reclaims () = 0);
    Stdlib.Printf.printf "%s: single-Break deterministic-cleanup=ok\n%!" mode)
