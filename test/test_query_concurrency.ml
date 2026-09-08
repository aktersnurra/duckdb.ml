open! Base
module D = Duckdb
external arm : int -> unit = "query_arm" [@@noalloc]
external entered : unit -> int = "query_entered" [@@noalloc]
external release : unit -> unit = "query_release" [@@noalloc]
external waiting : unit -> bool = "query_waiting" [@@noalloc]
external fail_bind : unit -> unit = "query_fail_bind" [@@noalloc]
external fail_fetch : unit -> unit = "query_fail_fetch" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let busy = function Error D.Busy -> () | _ -> failwith "expected Busy"
let wait predicate =
  let deadline = Unix.gettimeofday () +. 10. in
  while not (predicate ()) do
    if Float.(Unix.gettimeofday () > deadline) then (release (); failwith "handshake timeout");
    Thread.delay 0.001
  done
(* Thread.join alone does not propagate worker exceptions on this runtime. *)
let start f arg =
  let outcome = ref None in
  let thread = Thread.create (fun arg -> outcome := Some (try Ok (f arg) with exn -> Error exn)) arg in
  thread, outcome
let join (thread, outcome) =
  Thread.join thread;
  match !outcome with Some (Ok value) -> value | Some (Error exn) -> raise exn | None -> failwith "missing thread outcome"
let config = ok (D.Config.create Memory)
let connected f = ok (D.with_database config ~f:(fun db -> D.with_connection db ~f))
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let () =
  connected (fun c ->
    D.with_prepared c "select ?::BIGINT" ~f:(fun p ->
      ok (D.bind p 1 (D.Scalar.Required D.Scalar.Int64) 1L);
      fail_bind ();
      (match D.bind p 1 (D.Scalar.Required D.Scalar.Int64) 2L with Error (D.Native_error _) -> () | _ -> assert false);
      (match D.execute_prepared p with Error (D.Data_error (D.Scalar.Unbound_parameter 1)) -> () | _ -> assert false);
      ok (D.bind p 1 (D.Scalar.Required D.Scalar.Int64) 3L);
      let r = ok (D.execute_prepared p) in
      fail_fetch ();
      (match D.fold_chunks r ~init:() ~f:(fun _ () -> assert false) with Error (D.Native_error _) -> () | _ -> assert false);
      ok (D.close_result r);
      ok (D.close_result (ok (D.execute_prepared p))); Ok ()));
  clean (); Stdlib.print_endline "query: injected bind/fetch errors clean and reusable=ok"
let () =
  List.iter [1; 2] ~f:(fun point ->
    connected (fun c ->
      D.with_prepared c "SELECT i FROM range(5000) t(i)" ~f:(fun p ->
        let r = if point = 2 then Some (ok (D.execute_prepared p)) else None in
        arm point;
        let outcome = ref None in
        let worker = start (fun () -> outcome := Some (match r with
          | None -> D.close_result (ok (D.execute_prepared p))
          | Some r -> D.fold_chunks r ~init:() ~f:(fun _ () -> Ok (D.Stop ())))) () in
        Exn.protect ~finally:(fun () -> release (); join worker; arm 0) ~f:(fun () ->
          wait (fun () -> entered () = point);
          busy (D.execute c "select 1"); busy (D.close_prepared p); busy (D.reset p);
          Option.iter r ~f:(fun r -> busy (D.close_result r));
          for _ = 1 to 10 do let _ = String.make 100000 'x' in Stdlib.Gc.compact () done);
        ok (Option.value_exn !outcome); Ok ())));
  clean (); Stdlib.print_endline "query: concurrent execute/fetch exclusion + unlocked GC progress=ok"
let () =
  connected (fun c ->
    D.with_prepared c "select 42::BIGINT" ~f:(fun p ->
      let r = ok (D.execute_prepared p) in
      let result = D.fold_chunks r ~init:() ~f:(fun chunk () ->
        let outcome = ref None in
        let thread = start (fun () ->
          busy (D.close_result r); busy (D.close_prepared p); busy (D.reset p);
          busy (D.fold_chunks r ~init:() ~f:(fun _ () -> Ok (D.Stop ()))); outcome := Some ()) () in
        join thread; assert (Option.is_some !outcome);
        assert (Int64.equal (ok (D.column chunk ~column:0 ~row:0 (D.Scalar.Required D.Scalar.Int64))) 42L);
        Ok (D.Stop ())) in
      result));
  clean (); Stdlib.print_endline "query: live borrowed callback allows concurrent fail-fast aliases without mutex deadlock=ok"
let () =
  List.iter ["prepared"; "transaction"] ~f:(fun scope ->
    connected (fun c ->
      let worker = ref None and retained = ref None in
      arm 2;
      let launch p =
        retained := Some p;
        let r = ok (D.execute_prepared p) in
        let t = start (fun () -> ok (D.fold_chunks r ~init:() ~f:(fun _ () -> Ok (D.Stop ())))) () in
        worker := Some t; wait (fun () -> entered () = 2); Ok () in
      let releaser = start (fun () -> wait waiting; release ()) () in
      Exn.protect ~finally:(fun () -> release (); join releaser; Option.iter !worker ~f:join; arm 0)
        ~f:(fun () ->
          let result = match scope with
            | "prepared" -> D.with_prepared c "select 1" ~f:launch
            | "transaction" -> D.with_transaction c ~f:(fun tx -> launch (ok (D.prepare_transaction tx "select 1")))
            | _ -> assert false in
          ok result);
      (match D.execute_prepared (Option.value_exn !retained) with Error D.Closed -> () | _ -> assert false);
      Ok ()));
  clean (); Stdlib.print_endline "query: scoped prepared/transaction revoke and drain admitted fetch=ok"
let () =
  connected (fun c ->
    let transaction_entered = Stdlib.Atomic.make false in
    let settle = Stdlib.Atomic.make false in
    let worker = ref None in
    arm 0;
    let releaser = start (fun () -> wait waiting; Stdlib.Atomic.set settle true) () in
    Exn.protect ~finally:(fun () -> Stdlib.Atomic.set settle true; join releaser; Option.iter !worker ~f:join)
      ~f:(fun () ->
        D.with_prepared c "select 1" ~f:(fun _ ->
          worker := Some (start (fun () -> ok (D.with_transaction c ~f:(fun tx ->
            Stdlib.Atomic.set transaction_entered true;
            wait (fun () -> Stdlib.Atomic.get settle);
            D.execute_transaction tx "select 2"))) ());
          wait (fun () -> Stdlib.Atomic.get transaction_entered); Ok ())));
  clean (); Stdlib.print_endline "query: scoped connection-prepared close drains another transaction lease=ok"
let () =
  List.iter [3; 4] ~f:(fun point ->
    connected (fun c ->
      let p = if point = 4 then Some (ok (D.prepare c "select ?::VARCHAR")) else None in
      arm point;
      let worker = start (fun () ->
        let p = match p with
          | Some p -> p
          | None -> ok (D.prepare c ("select ?::VARCHAR /*" ^ String.make 100000 'x' ^ "*/")) in
        let text = String.init 200000 ~f:(fun i -> if i % 17 = 0 then '\000' else 'a') in
        ok (D.bind p 1 (D.Scalar.Required D.Scalar.String) text);
        let r = ok (D.execute_prepared p) in
        ok (D.fold_chunks r ~init:() ~f:(fun chunk () ->
          assert (String.equal text (ok (D.column chunk ~column:0 ~row:0 (D.Scalar.Required D.Scalar.String))));
          Ok (D.Stop ())));
        ok (D.close_prepared p)) () in
      Exn.protect ~finally:(fun () -> release (); join worker; arm 0) ~f:(fun () ->
        wait (fun () -> entered () = point);
        busy (D.execute c "select 1"); busy (D.close_connection c);
        for _ = 1 to 20 do let _ = String.make 100000 'g' in Stdlib.Gc.compact () done);
      Ok ()));
  clean (); Stdlib.print_endline "query: native-owned dynamic SQL/string lengths survive unlocked concurrent compaction=ok"
