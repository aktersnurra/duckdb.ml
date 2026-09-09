open! Core
open! Async
module S = Evidence_support
exception Worker_failure
exception Cleanup_failure
exception Dispatch_failure
let ok = function Ok x -> x | Error _ -> failwith "DuckDB error"
let check_failure expected = function
  | S.Raised f -> assert (phys_equal f.exception_ expected)
  | S.Returned _ -> failwith "missing failure"

let transaction () =
  let escaped = ref None in
  let rows = ok (Duckdb.with_database (ok (Duckdb.Config.create Memory)) ~f:(fun db ->
    Duckdb.with_connection db ~f:(fun c ->
      Duckdb.with_transaction c ~f:(fun tx ->
        escaped := Some tx;
        ok (Duckdb.execute_transaction tx "CREATE TABLE t(s VARCHAR)");
        ok (Duckdb.execute_transaction tx "INSERT INTO t VALUES ('owned')");
        Duckdb.with_prepared_transaction tx "SELECT s FROM t" ~f:(fun p ->
          let r = ok (Duckdb.execute_prepared p) in
          Duckdb.fold_chunks r ~init:[] ~f:(fun chunk rows ->
            let text = ok (Duckdb.column chunk ~column:0 ~row:0 (Duckdb.Scalar.Required Duckdb.Scalar.String)) in
            Ok (Duckdb.Continue (text :: rows)))))))) in
  (match Duckdb.execute_transaction (Option.value_exn !escaped) "SELECT 1" with
   | Error Duckdb.Closed -> () | _ -> failwith "escaped token usable");
  assert (Duckdb_ffi.live_resources () = 0);
  rows

let wait_scheduler predicate =
  let start = Mtime_clock.counter () in
  let rec loop () =
    if predicate () then return ()
    else if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.)
    then failwith "Async handshake deadline"
    else Clock_ns.after (Time_ns.Span.of_ms 1.) >>= loop in
  loop ()

(* Inject at the submission boundary, not inside the worker. This tests routing,
   not real thread-pool exhaustion (no global pool configuration is changed). *)
let submit ~fail_dispatch work =
  match S.capture (fun () ->
    if fail_dispatch then raise Dispatch_failure;
    In_thread.run (fun () -> S.capture work)) with
  | S.Returned deferred -> deferred
  | S.Raised failure -> return (S.Raised failure)

let abandoned_caller () =
  let caller = Monitor.create () in
  let observed = Ivar.create () and completion = Ivar.create () and failed = Ivar.create () in
  let count = ref 0 in
  Monitor.detach_and_iter_errors caller ~f:(fun exn ->
    match Monitor.extract_exn exn with
    | Dispatch_failure -> assert (not (Ivar.is_full completion)); Ivar.fill_exn failed ()
    | Worker_failure ->
      assert (Ivar.is_full completion && !count = 1);
      Ivar.fill_exn observed ()
    | _ -> assert false);
  (* Caller fails and abandons its deferred before worker completion. The
     essential producer belongs to this outer context, not the failing caller. *)
  let abandoned = Scheduler.within_v ~monitor:caller (fun () -> Deferred.never ()) in
  ignore abandoned;
  let running = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let worker = submit ~fail_dispatch:false (fun () ->
    Stdlib.Atomic.set running true;
    S.await ~label:"abandoned caller release" (fun () -> Stdlib.Atomic.get release);
    S.settle (fun () -> raise Worker_failure) ~cleanup:(fun () -> raise Cleanup_failure)) in
  let producer = worker >>| fun result ->
    let settled = S.restore result in
    check_failure Worker_failure settled.primary;
    check_failure Cleanup_failure settled.cleanup;
    incr count;
    Ivar.fill_exn completion settled;
    match settled.primary with
    | S.Raised failure -> Monitor.send_exn caller ~backtrace:(`This failure.backtrace) failure.exception_
    | S.Returned _ -> assert false in
  Monitor.protect ~finally:(fun () ->
    Stdlib.Atomic.set release true;
    producer)
    (fun () ->
      wait_scheduler (fun () -> Stdlib.Atomic.get running) >>= fun () ->
      ignore (Scheduler.within_v ~monitor:caller (fun () -> raise Dispatch_failure));
      Ivar.read failed >>= fun () ->
      assert (not (Deferred.is_determined producer));
      Stdlib.Atomic.set release true;
      producer >>= fun () ->
      Ivar.read observed)

let cases () =
  let raw = ref None in
  let cleaned = Stdlib.Atomic.make false in
  Monitor.try_with (fun () ->
    let d = In_thread.run (fun () ->
      Exn.protect ~f:(fun () -> raise Worker_failure)
        ~finally:(fun () -> Stdlib.Atomic.set cleaned true)) in
    raw := Some d; d)
  >>= fun outcome ->
  (match outcome with
   | Error exn -> assert (match Monitor.extract_exn exn with Worker_failure -> true | _ -> false)
   | Ok _ -> failwith "missing worker exception");
  assert (Stdlib.Atomic.get cleaned);
  assert (not (Deferred.is_determined (Option.value_exn !raw)));
  (* Never join that deliberately undetermined raw deferred. *)
  In_thread.run (fun () -> S.capture (fun () -> Error Duckdb.Embedded_nul))
  >>= fun ordinary ->
  (match ordinary with S.Returned (Error Duckdb.Embedded_nul) -> () | _ -> assert false);
  let executed = Stdlib.Atomic.make false in
  submit ~fail_dispatch:true (fun () -> Stdlib.Atomic.set executed true)
  >>= fun dispatch ->
  check_failure Dispatch_failure dispatch;
  assert (not (Stdlib.Atomic.get executed));
  let completion = Ivar.create () in
  let deliveries = ref 0 in
  Monitor.try_with (fun () ->
    let caller = Monitor.current () in
    (* This private completion producer owns accounting, independently of the
       caller's abandoned deferred. No scheduler calls occur inside the worker. *)
    don't_wait_for (
      In_thread.run (fun () -> S.settle (fun () -> raise Worker_failure)
        ~cleanup:(fun () -> raise Cleanup_failure))
      >>= fun settled ->
      check_failure Worker_failure settled.primary;
      check_failure Cleanup_failure settled.cleanup;
      incr deliveries;
      Ivar.fill_exn completion settled;
      assert (Ivar.is_full completion);
      (match settled.primary with
       | S.Raised failure -> Monitor.send_exn caller ~backtrace:(`This failure.backtrace) failure.exception_
       | S.Returned _ -> assert false);
      return ());
    Deferred.never ())
  >>= fun routed ->
  assert (Ivar.is_full completion && !deliveries = 1);
  (match routed with Error exn -> assert (match Monitor.extract_exn exn with Worker_failure -> true | _ -> false)
   | Ok _ -> assert false);
  abandoned_caller () >>= fun () ->
  let running = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let worker = In_thread.run (fun () ->
    S.capture (fun () ->
      Stdlib.Atomic.set running true;
      S.await ~label:"Async heartbeat release" (fun () -> Stdlib.Atomic.get release);
      transaction ())) in
  Monitor.protect ~finally:(fun () ->
    Stdlib.Atomic.set release true;
    worker >>| fun outcome -> ignore (S.restore outcome))
    (fun () ->
      wait_scheduler (fun () -> Stdlib.Atomic.get running) >>= fun () ->
      assert (not (Deferred.is_determined worker));
      Stdlib.Atomic.set release true;
      worker >>| fun result ->
      assert (List.equal String.equal (S.restore result) ["owned"]))
  (* The protected join deferred, not an early monitor notification, is returned. *)

let run () =
  Stdlib.Printexc.record_backtrace true;
  don't_wait_for (Monitor.try_with cases >>= function
    | Ok () ->
      assert (Duckdb_ffi.live_resources () = 0);
      assert (Duckdb_ffi.fallback_reclaims () = 0);
      Stdlib.print_endline "async: raw=pending owned-completion=once abandoned-caller=settled primary+cleanup+backtrace=preserved dispatch=simulated heartbeat=ok transaction=owned token=Closed";
      Shutdown.exit 0
    | Error exn -> Stdlib.prerr_endline (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
let () = run ()
