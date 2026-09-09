open! Base
module D = Duckdb
module B = D.Bridge
module E = Evidence_support
module A = Stdlib.Atomic
external reset_counts : unit -> unit = "adapter_bridge_reset"
external count : int -> int = "adapter_bridge_count"
external disconnect_gate : bool -> unit = "adapter_bridge_disconnect_gate"
external disconnect_entered : unit -> bool = "adapter_bridge_disconnect_entered"
external execute_gate : int -> unit = "adapter_bridge_execute_gate"
external execute_entered : unit -> int = "adapter_bridge_execute_entered"
external fail_rollback : bool -> unit = "adapter_bridge_fail_rollback"
external request_failure : int -> unit = "adapter_bridge_request_failure"
let ok = function Ok x -> x | Error _ -> failwith "expected Ok"
let expect error = function Error actual when Poly.equal error actual -> () | _ -> failwith "unexpected result"
let check label condition = if not condition then failwith label
let memory f = ok (D.with_database (ok (D.Config.create D.Config.Memory)) ~f)
let connection db f = D.with_connection db ~f
let rows c sql = D.with_prepared c sql ~f:(fun p ->
  Result.bind (D.execute_prepared p) ~f:(fun r ->
    D.fold_rows r D.Row.(Column (D.Scalar.Required D.Scalar.Int64, Empty)) ~init:[]
      ~f:(fun (x, ()) xs -> Ok (D.Continue (x :: xs)))))
exception Callback_failure
let callback_failure () = raise Callback_failure
let aliases db = connection db (fun owner ->
  let request = B.create () in
  let facade = ok (B.run request owner ~f:(fun facade ->
    expect D.Busy (D.execute owner "SELECT 1");
    expect D.Busy (D.close_connection facade);
    expect D.Busy (B.run request owner ~f:(fun _ -> Ok ()));
    expect D.Busy (B.run (B.create ()) facade ~f:(fun _ -> Ok ()));
    ok (D.execute facade "SELECT 42"); Ok facade)) in
  expect D.Closed (D.execute facade "SELECT 1");
  expect D.Closed (D.close_connection facade);
  expect D.Closed (B.cancel request);
  expect D.Closed (B.run request owner ~f:(fun _ -> Ok ()));
  check "settled" (Poly.equal (B.settlement request) B.Settled);
  List.iter [false; true] ~f:(fun exceptional ->
    let request = B.create () and escaped = ref None in
    let outcome = E.capture (fun () -> B.run request owner ~f:(fun facade ->
      escaped := Some facade;
      if exceptional then callback_failure () else Error D.Embedded_nul)) in
    (match outcome with
     | E.Returned result when not exceptional -> expect D.Embedded_nul result
     | E.Raised failure when exceptional ->
       check "exception identity" (phys_equal failure.exception_ Callback_failure);
       check "callback backtrace" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string failure.backtrace) ~substring:"callback_failure")
     | _ -> failwith "callback outcome");
    expect D.Closed (D.execute (Option.value_exn !escaped) "SELECT 1");
    expect D.Closed (B.cancel request));
  let request = B.create () in
  let p, r, tx = ok (B.run request owner ~f:(fun facade ->
    let tx = ok (D.with_transaction facade ~f:(fun tx -> Ok tx)) in
    let p = ok (D.prepare facade "SELECT 1::BIGINT") in
    let r = ok (D.execute_prepared p) in Ok (p, r, tx))) in
  expect D.Closed (D.parameter_count p);
  expect D.Closed (D.fold_chunks r ~init:() ~f:(fun _ () -> Ok (D.Stop ())));
  expect D.Closed (D.execute_transaction tx "SELECT 1");
  check "owned return" (String.equal (ok (B.run (B.create ()) owner ~f:(fun _ -> Ok "owned"))) "owned");
  D.execute owner "SELECT 1")
let pre_entry db = connection db (fun owner ->
  let request = B.create () in
  reset_counts ();
  ok (B.cancel request); ok (B.cancel request);
  check "fresh pending" (Poly.equal (B.settlement request) B.Pending);
  expect D.Cancelled (B.run request owner ~f:(fun _ -> failwith "cancelled callback ran"));
  check "pre-entry SQL count" (count 0 = 0 && count 1 = 0 && count 2 = 0);
  D.execute owner "SELECT 1")
let live_children db = connection db (fun owner ->
  let p = ok (D.prepare owner "SELECT 1") in
  let request = B.create () in
  expect D.Live_children (B.run request owner ~f:(fun _ -> Ok ()));
  expect D.Closed (B.cancel request);
  let r = ok (D.execute_prepared p) in
  expect D.Busy (B.run (B.create ()) owner ~f:(fun _ -> Ok ()));
  ok (D.close_result r); ok (D.close_prepared p);
  ok (D.execute owner "CREATE TABLE live_appender (i BIGINT)");
  ok (D.with_transaction owner ~f:(fun tx ->
    D.with_appender_transaction tx "live_appender" ~f:(fun _ ->
      expect D.Busy (B.run (B.create ()) owner ~f:(fun _ -> Ok ()));
      Ok ())));
  let a = ok (B.run (B.create ()) owner ~f:(fun facade ->
    D.with_appender facade "live_appender" ~f:(fun a -> Ok a))) in
  expect D.Closed (D.flush_appender a); Ok ())
let concurrent db = connection db (fun owner ->
  let entered = A.make false and release = A.make false in
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    A.set entered true; E.await ~label:"callback release" (fun () -> A.get release);
    D.execute facade "SELECT 1")) ~f:(fun join ->
    Exn.protect ~finally:(fun () -> A.set release true) ~f:(fun () ->
      E.await ~label:"callback entered" (fun () -> A.get entered);
      E.with_worker (fun () ->
        expect D.Busy (B.run request owner ~f:(fun _ -> Ok ()));
        expect D.Busy (D.execute owner "SELECT 1");
        expect D.Busy (D.close_connection owner);
        expect D.Busy (B.run (B.create ()) owner ~f:(fun _ -> Ok ())))
        ~f:(fun second -> second ());
      A.set release true; ok (join ())));
  D.execute owner "SELECT 1")
let transactions db = connection db (fun owner -> connection db (fun observer ->
  ok (D.execute owner "CREATE TABLE cancelled_rows (i BIGINT)");
  List.iter [0; 1; 2] ~f:(fun variant ->
    let request = B.create () in
    reset_counts ();
    let result = B.run request owner ~f:(fun facade ->
      (* Ignore the entire transaction error. Variant zero has no earlier
         Cancelled operation/poison: only the real pre-COMMIT latch saves it. *)
      ignore (D.with_transaction facade ~f:(fun tx ->
        ok (D.execute_transaction tx "INSERT INTO cancelled_rows VALUES (1)");
        let entered = A.make false and release = A.make false in
        E.with_worker (fun () -> E.await ~label:"cancel handshake" (fun () -> A.get entered);
          ok (B.cancel request); A.set release true) ~f:(fun join ->
          Exn.protect ~finally:(fun () -> A.set entered true) ~f:(fun () ->
            A.set entered true; E.await ~label:"cancel acknowledged" (fun () -> A.get release); join ()));
        if variant = 1 then ignore (D.execute_transaction tx "INSERT INTO cancelled_rows VALUES (2)");
        if variant = 2 then (try callback_failure () with Callback_failure -> ());
        Ok ()));
      Ok ()) in
    expect D.Cancelled result;
    check "pre-COMMIT latch: committed rows/count" (count 2 = 0 && count 3 = 1);
    check "observer rollback" (Poly.equal (ok (rows observer "SELECT count(*) FROM cancelled_rows")) [0L]));
  (* Dropped snapshot result and cancelled appender both roll back, not flush. *)
  ok (D.execute owner "CREATE SEQUENCE appender_flush_probe START 1");
  ok (D.execute owner "CREATE TABLE discarded_buffer (i BIGINT CHECK (nextval('appender_flush_probe') > 0))");
  let request = B.create () in
  expect D.Cancelled (B.run request owner ~f:(fun facade ->
    D.with_appender facade "discarded_buffer" ~f:(fun a ->
      ok (D.append_rows a [[D.Cell (D.Scalar.Required D.Scalar.Int64, 9L)]]);
      ok (B.cancel request); ignore (D.flush_appender a); Ok ())));
  check "appender discarded" (Poly.equal (ok (rows observer "SELECT count(*) FROM discarded_buffer")) [0L]);
  (* Sequences are not rolled back: this distinguishes discard from a flush
     followed by rollback, without an unsafe appender/test FFI entry point. *)
  check "cancelled appender never flushed" (Poly.equal (ok (rows observer "SELECT nextval('appender_flush_probe')")) [1L]);
  ok (D.with_appender owner "discarded_buffer" ~f:(fun a ->
    D.append_rows a [[D.Cell (D.Scalar.Required D.Scalar.Int64, 10L)]]));
  check "ordinary appender flush control" (match ok (rows observer "SELECT nextval('appender_flush_probe')") with [n] -> Int64.(n > 2L) | _ -> false);
  let request = B.create () in
  expect D.Cancelled (B.run request owner ~f:(fun facade ->
    D.with_prepared facade "SELECT 1::BIGINT" ~f:(fun p ->
      ok (B.cancel request); ignore (D.execute_prepared p); Ok ())));
  Ok ()))
let traversal db = connection db (fun owner ->
  List.iter [false; true] ~f:(fun stop ->
    let request = B.create () and visits = ref 0 in
    expect D.Cancelled (B.run request owner ~f:(fun facade ->
      D.with_prepared facade "SELECT i::BIGINT FROM range(5000) t(i)" ~f:(fun p ->
        Result.bind (D.execute_prepared p) ~f:(fun r ->
          D.fold_chunks r ~init:() ~f:(fun _ () ->
            Int.incr visits; ok (B.cancel request);
            Ok (if stop then D.Stop () else D.Continue ()))))));
    check "no next callback after latch" (!visits = 1));
  D.execute owner "SELECT 1")
let snapshots db = connection db (fun owner -> connection db (fun observer ->
  ok (D.execute owner "CREATE TABLE snapshot_rows (i BIGINT)");
  List.iter [false; true] ~f:(fun cancelled ->
    let request = B.create () in
    reset_counts (); execute_gate 2;
    E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
      (* This statement actually materializes inside with_child_snapshot. *)
      D.with_prepared facade "INSERT INTO snapshot_rows VALUES (8) RETURNING i" ~f:(fun p ->
        Result.bind (D.execute_prepared p) ~f:D.close_result))) ~f:(fun join ->
      Exn.protect ~finally:(fun () -> execute_gate 0) ~f:(fun () ->
        E.await ~label:"snapshot native result produced" (fun () -> execute_entered () = 2);
        check "snapshot BEGIN" (count 1 = 1 && count 0 = 1 && count 2 = 0);
        if cancelled then ok (B.cancel request);
        execute_gate 0;
        let result = join () in
        if cancelled then expect D.Cancelled result else ok result));
    check "snapshot settlement counts" (if cancelled then count 2 = 0 && count 3 = 1 else count 2 = 1 && count 3 = 0));
  check "snapshot observer rollback" (Poly.equal (ok (rows observer "SELECT count(*) FROM snapshot_rows")) [1L]);
  Ok ()))
exception Cleanup_failure
let cleanup_failure () = raise Cleanup_failure
let diagnostics db =
  List.iter [false; true] ~f:(fun cancelled ->
    ok (connection db (fun owner ->
      let request = B.create () in
      expect D.Embedded_nul (B.run request owner ~f:(fun _ ->
        if cancelled then ok (B.cancel request); Error D.Embedded_nul));
      let exceptional_request = B.create () in
      let outcome = E.capture (fun () -> B.run exceptional_request owner ~f:(fun _ ->
        if cancelled then ok (B.cancel exceptional_request);
        Exn.protect ~f:callback_failure ~finally:cleanup_failure)) in
      (match outcome with
       | E.Raised { exception_ = Exn.Finally (Callback_failure, Cleanup_failure); backtrace } ->
         check "Finally backtrace" (not (String.is_empty (Stdlib.Printexc.raw_backtrace_to_string backtrace)))
       | _ -> failwith "Finally composite lost"); Ok ())));
  connection db (fun owner ->
    let request = B.create () in
    reset_counts (); fail_rollback true;
    let result = Exn.protect ~finally:(fun () -> fail_rollback false) ~f:(fun () ->
      B.run request owner ~f:(fun facade -> D.with_transaction facade ~f:(fun _ ->
        ok (B.cancel request); Error D.Embedded_nul))) in
    (match result with Error (D.Rollback_failed (D.Embedded_nul, D.Native_error _)) -> ()
     | _ -> failwith "result rollback composite lost");
    check "transaction discard detached/disposed" (count 6 = 1 && count 7 = 1 && count 4 = 1);
    expect D.Closed (D.execute owner "SELECT 1"); Ok ())
type _ Stdlib.Effect.t += Escape : unit Stdlib.Effect.t
let effects_and_rollback db = connection db (fun owner ->
  let delivered = ref 0 in
  let result = Stdlib.Effect.Deep.try_with (fun () ->
    B.run (B.create ()) owner ~f:(fun facade -> D.with_transaction facade ~f:(fun _ ->
      Stdlib.Effect.perform Escape; Ok ()))) ()
    { effc = fun (type a) (effect : a Stdlib.Effect.t) -> match effect with
        | Escape -> Some (fun (k : (a, _) Stdlib.Effect.Deep.continuation) ->
          Int.incr delivered; Stdlib.Effect.Deep.continue k ())
        | _ -> None } in
  expect D.Effects_not_allowed result; check "outer effect denied" (!delivered = 0);
  let request = B.create () in
  fail_rollback true;
  let outcome = Exn.protect ~finally:(fun () -> fail_rollback false) ~f:(fun () ->
    E.capture (fun () -> B.run request owner ~f:(fun facade ->
      D.with_transaction facade ~f:(fun _ -> callback_failure ())))) in
  (match outcome with
   | E.Raised { exception_ = D.Rollback_exception (Callback_failure, D.Native_error _); backtrace } ->
     check "composite callback backtrace" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace) ~substring:"callback_failure")
   | _ -> failwith "rollback composite");
  expect D.Closed (D.execute owner "SELECT 1"); Ok ())
let parent_close db =
  let entered = A.make false and release = A.make false and published = A.make false in
  let request = B.create () and owner = ref None in
  reset_counts (); disconnect_gate true;
  E.with_worker (fun () ->
    E.await ~label:"parent owner published" (fun () -> A.get published);
    B.run request (Option.value_exn !owner) ~f:(fun facade ->
      A.set entered true; E.await ~label:"parent callback release" (fun () -> A.get release);
      D.execute facade "SELECT 1")) ~f:(fun request_join ->
    E.with_worker (fun () -> connection db (fun c ->
      owner := Some c; A.set published true;
      E.await ~label:"parent request admitted" (fun () -> A.get entered);
      Ok ())) ~f:(fun close_join ->
      Exn.protect ~finally:(fun () -> A.set release true; A.set published true; A.set entered true; disconnect_gate false) ~f:(fun () ->
        E.await ~label:"parent admitted before revocation probe" (fun () -> A.get entered);
        E.await ~label:"parent scope revoked" (fun () ->
          A.get published && match D.execute (Option.value_exn !owner) "SELECT 1" with Error D.Closed -> true | _ -> false);
        check "request still pending" (Poly.equal (B.settlement request) B.Pending);
        check "no early disconnect" (count 4 = 0);
        A.set release true;
        expect D.Closed (request_join ());
        E.await ~label:"native disconnect entered" disconnect_entered;
        check "settlement before disconnect" (Poly.equal (B.settlement request) B.Settled);
        check "parent revoke native detach/dispose" (count 6 = 1 && count 7 = 1);
        disconnect_gate false; ok (close_join ()))));
  expect D.Closed (D.execute (Option.value_exn !owner) "SELECT 1"); Ok ()
let parquet db = connection db (fun owner ->
  let name = Stdlib.Filename.temp_file "bridge-b1-" ".parquet" in
  Stdlib.Sys.remove name;
  Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists name then Stdlib.Sys.remove name) ~f:(fun () ->
    let path = ok (D.Parquet.path name) in
    ok (D.Parquet.export owner ~query:"SELECT 7::BIGINT AS i" path);
    let missing = ok (D.Parquet.path (name ^ ".missing")) in
    let request = B.create () in
    reset_counts ();
    expect D.Cancelled (B.run request owner ~f:(fun facade ->
      D.Parquet.fold_rows facade [path; missing] D.Row.(Column (D.Scalar.Required D.Scalar.Int64, Empty))
        ~init:() ~f:(fun _ () -> ok (B.cancel request); Ok (D.Continue ()))));
    check "next parquet suppressed" (count 0 = 1); Ok ()))
exception Native_create_failure
let[@inline never] run_create_failure request owner =
  B.run request owner ~f:(fun _ -> failwith "failed create callback") [@nontail]
let native_admission_failures db = connection db (fun owner ->
  Stdlib.Callback.Safe.register_exception "resource_lifecycle_create_failure" Native_create_failure;
  List.iter [1; 2] ~f:(fun mode ->
    reset_counts ();
    let before = Duckdb_ffi.live_resources () in
    let request = B.create () in
    request_failure mode;
    let result = Exn.protect ~finally:(fun () -> request_failure 0) ~f:(fun () ->
      E.capture (fun () -> run_create_failure request owner)) in
    (match mode, result with
     | 1, E.Raised { exception_ = Native_create_failure; backtrace } ->
       check "create failure backtrace retained"
         (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace) ~substring:"run_create_failure")
     | 2, E.Returned (Error D.Busy) -> ()
     | _ -> failwith "native acquisition failure outcome");
    check "failed binding settles admitted lease" (Poly.equal (B.settlement request) B.Settled);
    check "failed binding deterministic cleanup"
      (count 5 = 0 && count 6 = 0 && count 7 = (if mode = 2 then 1 else 0)
       && Duckdb_ffi.live_resources () = before);
    ok (D.execute owner "SELECT 1");
    ok (B.run (B.create ()) owner ~f:(fun facade -> D.execute facade "SELECT 2")));
  reset_counts ();
  let before = Duckdb_ffi.live_resources () in
  let request = B.create () in
  ok (B.cancel request);
  expect D.Cancelled (B.run request owner ~f:(fun _ -> failwith "pre-cancelled admission"));
  let p = ok (D.prepare owner "SELECT 1") in
  expect D.Live_children (B.run (B.create ()) owner ~f:(fun _ -> failwith "child admission"));
  ok (D.close_prepared p);
  check "failed ML admission allocates no native request"
    (count 5 = 0 && count 7 = 0 && Duckdb_ffi.live_resources () = before);
  Ok ())
let native_lifecycle db = connection db (fun owner ->
  List.iter [0; 1; 2; 3; 4] ~f:(fun outcome ->
    reset_counts ();
    let before = Duckdb_ffi.live_resources () in
    let request = B.create () in
    let result = E.capture (fun () -> B.run request owner ~f:(fun facade ->
      check "Resource binds after admission" (count 5 = 1);
      check "native lease stays live in callback" (Duckdb_ffi.live_resources () = before + 1);
      ok (D.execute facade "SELECT 1");
      match outcome with
      | 0 -> Ok ()
      | 1 -> Error D.Embedded_nul
      | 2 -> callback_failure ()
      | 3 -> ok (B.cancel request);
        check "native cancel published before acknowledgement" (count 8 = 1);
        Ok ()
      | _ -> D.execute facade "SELECT missing_resource_lifecycle_column")) in
    (match outcome, result with
     | 0, E.Returned (Ok ()) | 1, E.Returned (Error D.Embedded_nul)
     | 3, E.Returned (Error D.Cancelled) | 4, E.Returned (Error (D.Native_error _)) -> ()
     | 2, E.Raised failure ->
       check "native lifecycle exception identity" (phys_equal failure.exception_ Callback_failure)
     | _, E.Raised failure -> Stdlib.Printexc.raise_with_backtrace failure.exception_ failure.backtrace
     | _ -> failwith "native lifecycle outcome");
    check "Resource detaches/disposes every terminal path" (count 6 = 1 && count 7 = 1);
    check "Resource deterministic native reclamation" (Duckdb_ffi.live_resources () = before));
  Ok ())
let native_root_lifetime db = connection db (fun owner ->
  let entered = A.make false and release = A.make false in
  reset_counts ();
  let before = Duckdb_ffi.fallback_reclaims () in
  E.with_worker (fun () -> B.run (B.create ()) owner ~f:(fun facade ->
    ok (D.execute facade "SELECT 1");
    A.set entered true;
    E.await ~label:"rooted callback release" (fun () -> A.get release);
    D.execute facade "SELECT 2")) ~f:(fun join ->
    Exn.protect ~finally:(fun () -> A.set release true) ~f:(fun () ->
      E.await ~label:"rooted callback admitted" (fun () -> A.get entered);
      E.with_worker (fun () ->
        Stdlib.Gc.full_major (); Stdlib.Gc.full_major ();
        check "admitted callback native lease rooted" (count 5 = 1 && count 6 = 0);
        check "admitted callback owner not finalized" (Duckdb_ffi.fallback_reclaims () = before && count 4 = 0))
        ~f:(fun collect -> collect ());
      A.set release true; ok (join ())));
  check "rooted callback settled deterministically" (count 6 = 1 && count 7 = 1);
  Ok ())
let native_snapshot_discard db = connection db (fun owner ->
  reset_counts (); execute_gate 2; fail_rollback true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    D.with_prepared facade "SELECT 1::BIGINT" ~f:(fun p ->
      Result.bind (D.execute_prepared p) ~f:D.close_result))) ~f:(fun join ->
    Exn.protect ~finally:(fun () -> execute_gate 0; fail_rollback false) ~f:(fun () ->
      E.await ~label:"snapshot discard result produced" (fun () -> execute_entered () = 2);
      ok (B.cancel request); execute_gate 0;
      (match join () with
       | Error (D.Rollback_failed (D.Cancelled, D.Native_error _)) -> ()
       | _ -> failwith "snapshot discard composite");
      check "snapshot detaches before close" (count 6 = 1 && count 7 = 1 && count 4 = 1)));
  expect D.Closed (D.execute owner "SELECT 1"); Ok ())
let run () =
  Stdlib.Printexc.record_backtrace true;
  memory (fun db ->
    List.iter ["native_admission_failures", native_admission_failures; "native_lifecycle", native_lifecycle; "native_root_lifetime", native_root_lifetime;
      "native_snapshot_discard", native_snapshot_discard; "aliases", aliases; "pre_entry", pre_entry; "live_children", live_children;
      "concurrent", concurrent; "transactions", transactions; "snapshots", snapshots; "traversal", traversal; "diagnostics", diagnostics; "effects_and_rollback", effects_and_rollback;
      "parent_close", parent_close; "parquet", parquet] ~f:(fun (name, test) ->
        Stdlib.print_endline name; ok (test db)); Ok ());
  check "no native resources" (Duckdb_ffi.live_resources () = 0);
  check "no fallback reclamation" (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "adapter bridge B1: ok (ML cooperative only; NOT accepted cancellation bridge)"
let rec report_exception = function
  | E.Multiple_failures (first, second) ->
    report_exception first.exception_; report_exception second.exception_
  | exn -> Stdlib.prerr_endline (Exn.to_string exn)
let () = try run () with exn -> report_exception exn; raise exn
