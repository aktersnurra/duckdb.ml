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
let bigints = Table.(declare "a" Columns.[ "x", int64 ] ~row:Fn.id)
let count c = ok (Statement.with_prepared c "SELECT count(*) FROM a" ~f:(fun p ->
  Statement.fold_chunks p ~init:0L ~f:(fun chunk _ ->
    match Statement.column chunk ~column:0 ~row:0 Codec.Values.int64 with Ok n -> Ok (Stop n) | Error e -> Error e)))
let race explicit point =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c -> with_connection db ~f:(fun other ->
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
    ok (execute other "SELECT 1"); arm 0; Ok ()))))
(* The scope's implicit close meets the still-admitted append and returns Busy;
   the drained child is then discarded, so nothing commits. [explicit] runs it
   in a caller-owned transaction, which can then no longer commit. *)
let gc_and_drain ~explicit =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
    ok (execute c "CREATE TABLE a(x VARCHAR)");
    let append_worker = ref None in
    let inspector = ref None in
    let table = Table.(declare "a" Columns.[ "x", string ] ~row:Fn.id) in
    let body a =
      arm 2;
      append_worker := Some (spawn (fun () -> Table.append a [Args.[String.make 200000 'x' ^ "\000end"]]));
      await (fun () -> entered () = 2);
      assert (match Table.flush a with Error { cause = Busy; _ } -> true | _ -> false);
      assert (match Table.append a [] with Error { cause = Busy; _ } -> true | _ -> false);
      inspector := Some (spawn (fun () ->
        Exn.protect ~finally:release ~f:(fun () -> await waiting; Stdlib.Gc.compact ())));
      Ok () in
    let busy_close = function Error { Error.cause = Busy; _ } -> true | _ -> false in
    let settled =
      if explicit then (
        let inner = ref None in
        let settled = with_transaction c ~f:(fun tx ->
          inner := Some (Table.with_appender tx table ~f:body); Ok ()) in
        assert (busy_close (Option.value_exn !inner));
        settled)
      else (
        let outcome = Table.with_appender c table ~f:body in
        assert (busy_close outcome);
        Ok ()) in
    ignore (join (Option.value_exn !inspector));
    ok (join (Option.value_exn !append_worker));
    if explicit then assert (Result.is_error settled);
    arm 0;
    let n = ok (Statement.with_prepared c "SELECT count(*) FROM a" ~f:(fun p -> Statement.fold_chunks p ~init:0L ~f:(fun chunk _ ->
  match Statement.column chunk ~column:0 ~row:0 Codec.Values.int64 with Ok n -> Ok (Stop n) | Error e -> Error e))) in
    assert (Int64.equal n 0L); Ok ())))
let () =
  List.iter [false;true] ~f:(fun explicit -> List.iter [1;2;3;4;5] ~f:(race explicit));
  gc_and_drain ~explicit:false; gc_and_drain ~explicit:true;
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
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
    with_connection db ~f:(fun observer -> assert (Int64.equal (count observer) 0L); Ok ()))));
  assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "appender concurrency: ten snapshot/DDL races, unlocked GC, Busy admission and scoped draining passed"
