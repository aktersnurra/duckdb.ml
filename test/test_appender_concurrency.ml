open! Base
open Duckdb
external arm : int -> unit = "appender_arm" [@@noalloc]
external entered : unit -> int = "appender_entered" [@@noalloc]
external release : unit -> unit = "appender_release" [@@noalloc]
external fail_rollback : unit -> unit = "appender_fail_rollback" [@@noalloc]
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let await f = let rec loop n = if f () then () else if n = 0 then failwith "handshake timeout" else (Thread.delay 0.001;loop (n-1)) in loop 10000
let spawn f = let result = ref None in let t = Thread.create (fun () -> result := Some (try Ok (f ()) with e -> Error e)) () in t,result
let join (t,r) = Thread.join t; match !r with Some (Ok x) -> x | Some (Error e) -> raise e | None -> failwith "worker missing outcome"
let bigints = Table.(declare "a" Columns.[ "x", int64 ] ~row:Fn.id)
let count c = ok (Statement.with_prepared c "SELECT count(*) FROM a" ~f:(fun p ->
  Statement.fold_chunks p ~init:0L ~f:(fun chunk _ ->
    match Statement.column chunk ~column:0 ~row:0 Codec.Values.int64 with Ok n -> Ok (Stop n) | Error e -> Error e)))
(* Owned handles are global: threads may share them. *)
let owned f =
  let db = ok (Owned.open_database (ok (Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (Owned.close_database db)) ~f:(fun () -> f db)
let connection db f =
  let c = ok (Owned.connect db) in
  Exn.protect ~finally:(fun () -> ok (Owned.close_connection c)) ~f:(fun () -> f c)
let race explicit point =
  owned (fun db -> connection db (fun c -> connection db (fun other ->
    ok (execute c "CREATE TABLE a(x BIGINT)"); arm point;
    let worker = spawn (fun () ->
      let callback a =
        ok (Table.append a [Args.[9007199254740993L]]);
        if point = 3 then Table.flush a else Ok () in
      if explicit then with_transaction c ~f:(fun tx -> Table.with_appender tx bigints ~f:callback)
      else Table.with_appender c bigints ~f:callback) in
    Exn.protect ~finally:release ~f:(fun () ->
      await (fun () -> entered () = point);
      assert (match execute c "SELECT 1" with Error { cause = Busy; _ } -> true | _ -> false);
      Stdlib.Gc.compact ();
      ok (execute other "ALTER TABLE a ALTER x TYPE DOUBLE"));
    let outcome = join worker in
    assert (Result.is_error outcome);
    assert (Int64.equal (count other) 0L);
    (* Commit conflicts can already abort the transaction and force discard;
       otherwise the original connection remains clean and reusable. *)
    (match execute c "SELECT 1" with Ok () | Error { cause = Closed; _ } -> () | _ -> failwith "unclean connection");
    ok (execute other "SELECT 1"); arm 0)))
let () =
  List.iter [false;true] ~f:(fun explicit -> List.iter [1;2;3;4;5] ~f:(race explicit));
  owned (fun db -> connection db (fun c ->
    ok (execute c "CREATE TABLE a(x BIGINT UNIQUE)");
    let original = ref None in
    let outcome = Table.with_appender c bigints ~f:(fun a ->
      ok (Table.append a [Args.[1L]; Args.[1L]]);
      match Table.flush a with
      | Ok () -> failwith "constraint did not fail"
      | Error e -> original := Some e; fail_rollback (); Error e) in
    assert (match outcome with
      | Error { cause = Rollback_failed { primary; rollback = { cause = Native _; _ } }; _ } ->
        phys_equal primary (Option.value_exn !original)
      | _ -> false);
    assert (match execute c "SELECT 1" with Error { cause = Closed; _ } -> true | _ -> false);
    ok (with_connection db ~f:(fun observer -> assert (Int64.equal (count observer) 0L); Ok ()))));
  assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "appender concurrency: ten snapshot/DDL races, unlocked GC, Busy admission and rollback failure passed"
