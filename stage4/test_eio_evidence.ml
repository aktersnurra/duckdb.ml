open! Base
exception Requested
module S = Evidence_support
exception Cleanup_failure
exception Worker_failure
exception Dispatch_failure
exception Cancelled_with_cleanup of exn * S.failure
let ok = function Ok x -> x | Error _ -> failwith "DuckDB error"
let submit ~fail_dispatch work ~cleanup =
  match S.capture (fun () ->
    if fail_dispatch then raise Dispatch_failure;
    Eio_unix.run_in_systhread (fun () -> S.settle work ~cleanup)) with
  | S.Returned settled -> settled
  | S.Raised failure -> { S.primary = S.Raised failure; cleanup = S.Returned () }

let raw_case env =
    let clock = Eio.Stdenv.clock env in
    let running = Stdlib.Atomic.make false in
    let release = Stdlib.Atomic.make false in
    let returned = Stdlib.Atomic.make false in
    let cancelled = Stdlib.Atomic.make false in
    let context, publish_context = Eio.Promise.create () in
    let wait_worker () = S.await ~label:"raw Eio release" (fun () -> Stdlib.Atomic.get release) in
    let wait_running () =
      let start = Mtime_clock.counter () in
      while not (Stdlib.Atomic.get running) do
        if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.) then failwith "worker start timeout";
        Eio.Time.sleep clock 0.001
      done in
    Eio.Fiber.both
      (fun () ->
        try Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve publish_context cc;
          let value = Eio_unix.run_in_systhread (fun () ->
            Stdlib.Atomic.set running true;
            wait_worker ();
            42) in
          assert (Int.equal value 42);
          Stdlib.Atomic.set returned true;
          Eio.Fiber.check ())
        with Eio.Cancel.Cancelled Requested -> Stdlib.Atomic.set cancelled true)
      (fun () ->
        Exn.protect ~finally:(fun () -> Stdlib.Atomic.set release true) ~f:(fun () ->
          let cc = Eio.Promise.await context in
          wait_running ();
          Eio.Cancel.cancel cc Requested;
          assert (not (Stdlib.Atomic.get returned));
          assert (not (Stdlib.Atomic.get cancelled))));
    assert (Stdlib.Atomic.get returned);
    assert (Stdlib.Atomic.get cancelled);
    Stdlib.print_endline "eio: raw-return=42 then explicit-check=Cancelled"

let protected_case env ~fail_cleanup =
  let clock = Eio.Stdenv.clock env in
  let running = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let cleanup_started = Stdlib.Atomic.make false and cleanup_release = Stdlib.Atomic.make false in
  let completion, publish = Eio.Promise.create () in
  let context, publish_context = Eio.Promise.create () in
  let noticed, publish_noticed = Eio.Promise.create () in
  let reraised = ref false in
  let wait label predicate =
    let start = Mtime_clock.counter () in
    while not (predicate ()) do
      if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.) then failwith label;
      Eio.Time.sleep clock 0.001
    done in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Cancel.protect (fun () ->
        let settled = submit ~fail_dispatch:false (fun () ->
            Stdlib.Atomic.set running true;
            S.await ~label:"protected worker release" (fun () -> Stdlib.Atomic.get release);
            42)
            ~cleanup:(fun () ->
              Stdlib.Atomic.set cleanup_started true;
              S.await ~label:"protected cleanup release" (fun () -> Stdlib.Atomic.get cleanup_release);
              if fail_cleanup then raise Cleanup_failure) in
        Eio.Promise.resolve publish settled));
    Eio.Fiber.fork ~sw (fun () ->
      (try Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve publish_context cc;
        try
          Eio.Fiber.check ();
          ignore (Eio.Promise.await completion);
          Eio.Fiber.check ();
          failwith "waiter was not cancelled"
        with Eio.Cancel.Cancelled _ as cancellation ->
          Eio.Promise.resolve publish_noticed ();
          let settled = Eio.Cancel.protect (fun () -> Eio.Promise.await completion) in
          assert (S.restore settled.primary = 42);
          (match settled.cleanup with
           | S.Returned () -> raise cancellation
           | S.Raised cleanup -> raise (Cancelled_with_cleanup (cancellation, cleanup))))
       with
       | Eio.Cancel.Cancelled Requested when not fail_cleanup -> reraised := true
       | Cancelled_with_cleanup (Eio.Cancel.Cancelled Requested, failure) when fail_cleanup ->
         assert (match failure.exception_ with Cleanup_failure -> true | _ -> false);
         reraised := true));
    Exn.protect ~finally:(fun () ->
      Stdlib.Atomic.set release true;
      Stdlib.Atomic.set cleanup_release true)
      ~f:(fun () ->
        let cc = Eio.Promise.await context in
        wait "producer start" (fun () -> Stdlib.Atomic.get running);
        Eio.Cancel.cancel cc Requested;
        Eio.Promise.await noticed;
        assert (not (Eio.Promise.is_resolved completion));
        Stdlib.Atomic.set release true;
        wait "cleanup start" (fun () -> Stdlib.Atomic.get cleanup_started);
        Eio.Cancel.cancel cc Requested;
        assert (not !reraised);
        Stdlib.Atomic.set cleanup_release true));
  assert !reraised;
  assert (Eio.Promise.is_resolved completion)

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
  rows

let effects () =
  let reached_after_yield = ref false and cleanup = ref false and delivered = ref false in
  ok (Duckdb.with_database (ok (Duckdb.Config.create Memory)) ~f:(fun db ->
    Duckdb.with_connection db ~f:(fun c ->
      ok (Duckdb.execute c "CREATE TABLE t(x INTEGER)");
      let outcome = Stdlib.Effect.Deep.try_with (fun () -> Duckdb.with_transaction c ~f:(fun tx ->
        Exn.protect ~finally:(fun () -> cleanup := true) ~f:(fun () ->
          ok (Duckdb.execute_transaction tx "INSERT INTO t VALUES (1)");
          Eio.Fiber.yield ();
          reached_after_yield := true;
          Ok ()))) ()
        { effc = fun (type a) (_ : a Stdlib.Effect.t) ->
          delivered := true;
          Some (fun continuation -> Stdlib.Effect.Deep.discontinue continuation (Failure "outer effect delivery")) } in
      assert (not !delivered);
      (match outcome with Error Duckdb.Effects_not_allowed -> () | _ -> assert false);
      assert (!cleanup && not !reached_after_yield);
      Duckdb.execute c "SELECT CASE WHEN count(*)=0 THEN 1 ELSE error('not rolled back') END FROM t")))

let run () =
  Stdlib.Printexc.record_backtrace true;
  Eio_main.run (fun env ->
    raw_case env;
    protected_case env ~fail_cleanup:false;
    protected_case env ~fail_cleanup:true;
    List.iter [false; true] ~f:(fun fail_dispatch ->
      let completion, publish = Eio.Promise.create () in
      let executed = Stdlib.Atomic.make false in
      Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () -> Eio.Cancel.protect (fun () ->
          let settled = submit ~fail_dispatch (fun () ->
            Stdlib.Atomic.set executed true; raise Worker_failure) ~cleanup:Fn.id in
          Eio.Promise.resolve publish settled));
        let settled = Eio.Promise.await completion in
        (match settled.primary with
         | S.Raised { exception_ = Dispatch_failure; _ } when fail_dispatch -> ()
         | S.Raised { exception_ = Worker_failure; backtrace } when not fail_dispatch ->
           assert (Stdlib.Printexc.raw_backtrace_length backtrace > 0)
         | _ -> assert false);
        assert (Bool.equal (Stdlib.Atomic.get executed) (not fail_dispatch))));
    let ordinary = submit ~fail_dispatch:false (fun () -> Error Duckdb.Embedded_nul) ~cleanup:Fn.id in
    (match ordinary.primary with S.Returned (Error Duckdb.Embedded_nul) -> () | _ -> assert false);
    assert (List.equal String.equal (Eio_unix.run_in_systhread transaction) ["owned"]);
    effects ());
  assert (Duckdb_ffi.live_resources () = 0);
  assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "eio: waiter-cancel-before-release protected-join+repeat-cancel cleanup-composite=ok transaction=owned token=Closed effect=denied rollback=ok dispatch=simulated"
let () = run ()
