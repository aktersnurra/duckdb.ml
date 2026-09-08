open! Base
open Duckdb
external arm : int -> unit = "appender_arm" [@@noalloc]
external entered : unit -> int = "appender_entered" [@@noalloc]
external release : unit -> unit = "appender_release" [@@noalloc]
external waiting : unit -> bool = "appender_waiting" [@@noalloc]
external fail_rollback : unit -> unit = "appender_fail_rollback" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let await f = let rec loop n = if f () then () else if n = 0 then failwith "handshake timeout" else (Thread.delay 0.001;loop (n-1)) in loop 10000
let spawn f = let result = ref None in let t = Thread.create (fun () -> result := Some (try Ok (f ()) with e -> Error e)) () in t,result
let join (t,r) = Thread.join t; match !r with Some (Ok x) -> x | Some (Error e) -> raise e | None -> failwith "worker missing outcome"
let count c = ok (with_prepared c "SELECT count(*) FROM a" ~f:(fun p -> fold_rows (ok (execute_prepared p)) Row.(Column (Required Int64,Empty)) ~init:0L ~f:(fun (n,()) _ -> Ok (Stop n))))
let race explicit point =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c -> with_connection db ~f:(fun other ->
    ok (execute c "CREATE TABLE a(x BIGINT)"); arm point;
    let worker = spawn (fun () ->
      let callback a =
        ok (append_rows a [[Cell (Required Int64,9007199254740993L)]]);
        if point = 3 then flush_appender a else Ok () in
      if explicit then with_transaction c ~f:(fun tx -> with_appender_transaction tx "a" ~f:callback)
      else with_appender c "a" ~f:callback) in
    Exn.protect ~finally:release ~f:(fun () ->
      await (fun () -> entered () = point);
      assert (match execute c "SELECT 1" with Error Busy -> true | _ -> false);
      Stdlib.Gc.compact ();
      ok (execute other "ALTER TABLE a ALTER x TYPE DOUBLE"));
    let outcome = join worker in
    assert (Result.is_error outcome);
    assert (Int64.equal (count other) 0L);
    (* Commit conflicts can already abort the transaction and force discard;
       otherwise the original connection remains clean and reusable. *)
    (match execute c "SELECT 1" with Ok () | Error Closed -> () | _ -> failwith "unclean connection");
    ok (execute other "SELECT 1"); arm 0; Ok ()))))
let gc_and_drain () =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
    ok (execute c "CREATE TABLE a(x VARCHAR)");
    let append_worker = ref None in
    let inspector = ref None in
    let outcome = with_appender c "a" ~f:(fun a ->
      arm 2;
      append_worker := Some (spawn (fun () -> append_rows a [[Cell (Required String,String.make 200000 'x' ^ "\000end")]]));
      await (fun () -> entered () = 2);
      assert (match close_appender a with Error Busy -> true | _ -> false);
      assert (match append_rows a [] with Error Busy -> true | _ -> false);
      inspector := Some (spawn (fun () ->
        Exn.protect ~finally:release ~f:(fun () -> await waiting; Stdlib.Gc.compact ())));
      Ok ()) in
    ignore (join (Option.value_exn !inspector));
    ok (join (Option.value_exn !append_worker));
    assert (Result.is_error outcome); arm 0;
    let n = ok (with_prepared c "SELECT count(*) FROM a" ~f:(fun p -> fold_rows (ok (execute_prepared p)) Row.(Column (Required Int64,Empty)) ~init:0L ~f:(fun (n,()) _ -> Ok (Stop n)))) in
    assert (Int64.equal n 0L); Ok ())))
let () =
  List.iter [false;true] ~f:(fun explicit -> List.iter [1;2;3;4;5] ~f:(race explicit));
  gc_and_drain ();
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
    ok (execute c "CREATE TABLE a(x BIGINT UNIQUE)");
    let original = ref None in
    let outcome = with_appender c "a" ~f:(fun a ->
      ok (append_rows a [[Cell (Required Int64,1L)];[Cell (Required Int64,1L)]]);
      match flush_appender a with
      | Ok () -> failwith "constraint did not fail"
      | Error e -> original := Some e; fail_rollback (); Error e) in
    assert (match outcome with Error (Rollback_failed (primary, Native_error _)) -> phys_equal primary (Option.value_exn !original) | _ -> false);
    assert (match execute c "SELECT 1" with Error Closed -> true | _ -> false);
    with_connection db ~f:(fun observer -> assert (Int64.equal (count observer) 0L); Ok ()))));
  assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "appender concurrency: ten snapshot/DDL races, unlocked GC, Busy admission and scoped draining passed"
