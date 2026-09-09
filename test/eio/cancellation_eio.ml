open! Base
module E = Duckdb_eio
exception Requested
external reset : int -> unit = "eio_foundation_reset"
external counter : int -> int = "eio_foundation_counter"
external hold : bool -> unit = "eio_foundation_hold"
external hold_cleanup : int -> bool -> unit = "eio_foundation_hold_cleanup"
external hold_between : bool -> unit = "eio_foundation_hold_between"
external wait_between : unit -> unit = "eio_foundation_wait_between"
let check name b = if not b then failwith name
let unwrap = function Ok x -> x | Error _ -> failwith "unexpected adapter error"
let config () = unwrap (Duckdb.Config.create Duckdb.Config.Memory)
let pool sw n q = unwrap (E.create ~sw (unwrap (E.limits ~connections:n ~queue_capacity:q)) (config ()))
let pause clock = Eio.Time.sleep clock 0.001
let until clock name f =
  let deadline = Eio.Time.now clock +. 5. in
  let rec loop () =
    if f () then ()
    else if Float.(Eio.Time.now clock > deadline) then failwith name
    else (pause clock; loop ()) in
  loop ()
let sql = "SELECT SUM(i) FROM range(10000000000) t(i)"

(* The held query has entered duckdb_execute_prepared, so the counters below
   distinguish a cancelled admitted producer from merely observing Cancelled. *)
let queue_and_admission clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let running = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "running query entered native engine" (fun () -> counter 5 = 1);
      let context, resolve_context = Eio.Promise.create () in
      let queued = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve resolve_context cc;
          try ignore (E.execute p "SELECT 99"); false with Eio.Cancel.Cancelled Requested -> true)) in
      let cc = Eio.Promise.await context in
      (* Independent overflow proves B already owns the sole queued entry. *)
      check "B demonstrably admitted before cancellation"
        (match E.execute p "SELECT 98" with Error E.Queue_full -> true | _ -> false);
      Eio.Cancel.cancel cc Requested;
      until clock "admitted B settles while A stays held" (fun () -> Eio.Promise.is_resolved queued);
      check "queued caller preserves cancellation identity" (Eio.Promise.await_exn queued);
      check "A remains held after B settlement" (not (Eio.Promise.is_resolved running));
      check "queued cancellation has no native work or retirement"
        (counter 14 = 1 && counter 0 = 1 && counter 1 = 0 && counter 2 = 0 && counter 3 = 1 && counter 4 = 0);
      let replacement = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "SELECT 100") in
      check "C occupies freed Q while A stays held" (not (Eio.Promise.is_resolved replacement));
      check "replacement admission consumes exactly one entry"
        (match E.execute p "SELECT 101" with Error E.Queue_full -> true | _ -> false);
      check "C is queued without native work" (counter 3 = 1);
      hold false;
      unwrap (Eio.Promise.await_exn running);
      unwrap (Eio.Promise.await_exn replacement);
      unwrap (E.execute p "SELECT 102");
      check "A C and subsequent reuse execute exactly once without retirement"
        (counter 0 = 1 && counter 1 = 0 && counter 3 = 3);
      unwrap (E.shutdown p)));
  check "queued cancellation did not interrupt an unrelated running owner" (counter 4 = 0);
  check "exact final owner inventory" (counter 0 = 1 && counter 1 = 1 && counter 2 = 1)

let queued_shutdown clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let running = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "shutdown A held natively" (fun () -> counter 5 = 1);
      let queued = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p "SELECT 99")) in
      check "shutdown B demonstrably admitted"
        (match E.execute p "SELECT 98" with Error E.Queue_full -> true | _ -> false);
      let shutdown = Eio.Fiber.fork_promise ~sw (fun () -> E.shutdown p) in
      until clock "shutdown removes B before unrelated A finishes"
        (fun () -> counter 4 = 1 && Eio.Promise.is_resolved queued);
      check "shutdown B settles with named result"
        (match Eio.Promise.await_exn queued with Error E.Pool_shutdown -> true | _ -> false);
      check "shutdown still joins held A"
        (not (Eio.Promise.is_resolved running) && not (Eio.Promise.is_resolved shutdown));
      check "shutdown B has no native acquisition cleanup or SQL"
        (counter 14 = 1 && counter 0 = 1 && counter 1 = 0 && counter 2 = 0 && counter 3 = 1);
      hold false;
      ignore (Eio.Promise.await_exn running);
      unwrap (Eio.Promise.await_exn shutdown);
      unwrap (E.shutdown p)));
  check "shutdown exactly-once owner inventory" (counter 0 = 1 && counter 1 = 1 && counter 2 = 1)

let fifo_overflow_and_zero clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 2 in
    unwrap (E.execute p "CREATE TABLE fifo(x INTEGER)");
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let running = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "FIFO running entry" (fun () -> counter 5 = 1);
      (* q2 depends on q1: both succeeding proves FIFO, not just eventual work. *)
      let q1 = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "CREATE TABLE fifo_dependency(x INTEGER)") in
      let q2 = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "INSERT INTO fifo_dependency VALUES (1)") in
      Eio.Fiber.yield ();
      check "finite queue overflow" (match E.execute p "SELECT 7" with Error E.Queue_full -> true | _ -> false);
      check "overflow causes no native SQL" (counter 3 = 2);
      hold false;
      ignore (Eio.Promise.await_exn running);
      unwrap (Eio.Promise.await_exn q1); unwrap (Eio.Promise.await_exn q2);
      check "FIFO requests reached native SQL exactly once" (counter 3 = 4);
      unwrap (E.shutdown p)));
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 0 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let running = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "Q=0 running entry" (fun () -> counter 5 = 1);
      check "Q=0 rejects waiting admission" (match E.execute p "SELECT 8" with Error E.Queue_full -> true | _ -> false);
      check "Q=0 rejection executes no SQL" (counter 3 = 1);
      hold false; ignore (Eio.Promise.await_exn running); unwrap (E.shutdown p)))

let running_cancellation_then_reuse clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let cancelled = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Fiber.fork ~sw (fun () ->
            until clock "cancelled request native entry" (fun () -> counter 5 = 1);
            Eio.Cancel.cancel cc Requested);
          try ignore (E.execute p sql); false with Eio.Cancel.Cancelled Requested -> true)) in
      until clock "real native interrupt" (fun () -> counter 4 = 1);
      hold false;
      check "running cancellation preserves original identity" (Eio.Promise.await_exn cancelled);
      let before_interrupts = counter 4 in
      unwrap (E.execute p "SELECT 42");
      Eio.Fiber.yield (); pause clock;
      check "replacement B executes after A cancellation settled" (counter 3 = 2);
      check "later B usability adds no interrupt (not an active-B race)" (counter 4 = before_interrupts);
      (* A completed promise does not bypass the adapter's post-await cancellation check. *)
      Eio.Cancel.sub (fun cc ->
        Eio.Cancel.cancel cc Requested;
        try ignore (E.execute p "SELECT 43"); failwith "resolved-context cancellation bypassed"
        with Eio.Cancel.Cancelled Requested -> ());
      check "already-cancelled caller starts no native SQL" (counter 3 = 2);
      unwrap (E.shutdown p)))

(* The gate is entered only after DuckDB has returned from execute_prepared but
   before the worker returns to the adapter. Cancellation here is therefore a
   foreign-return/adapter-terminal race, not cancellation before native entry. *)
let foreign_return_then_reuse clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    hold_cleanup 18 true;
    Exn.protect ~finally:(fun () -> hold_cleanup 18 false) ~f:(fun () ->
      let context, publish = Eio.Promise.create () in
      let a = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve publish cc;
        try ignore (E.execute p "SELECT 44"); false with Eio.Cancel.Cancelled Requested -> true)) in
      until clock "A foreign return reached before adapter terminal" (fun () -> counter 18 = 1);
      check "foreign return releases runtime and A completion remains pending"
        (counter 6 = 0 && not (Eio.Promise.is_resolved a));
      let caller = Eio.Promise.await context in
      Eio.Cancel.cancel caller Requested;
      Eio.Cancel.cancel caller Requested;
      check "repeated terminal cancellation cannot return before held worker boundary"
        (not (Eio.Promise.is_resolved a));
      hold_cleanup 18 false;
      check "foreign-return cancellation preserves caller identity" (Eio.Promise.await_exn a);
      let interrupts = counter 4 in
      unwrap (E.execute p "SELECT 45");
      check "post-terminal later B usability adds no interrupt" (counter 3 = 2 && counter 4 = interrupts);
      unwrap (E.shutdown p)));
  check "foreign-return gate was actual native return" (counter 18 = 1)

(* A test-only C gate releases the runtime while the synchronous callback is
   between its two real statements. It does not invoke Eio from the worker. *)
let transaction_between_statements clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    let escaped = ref None in
    hold_between true;
    Exn.protect ~finally:(fun () -> hold_between false) ~f:(fun () ->
      let a = Eio.Fiber.fork_promise ~sw (fun () -> E.transaction p ~f:(fun tx ->
        escaped := Some tx;
        unwrap (Duckdb.execute_transaction tx "CREATE TABLE between_tx(x INTEGER)");
        wait_between ();
        Duckdb.execute_transaction tx "INSERT INTO between_tx VALUES (1)")) in
      until clock "A held between its two statements" (fun () -> counter 20 = 1);
      let b = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "INSERT INTO between_tx VALUES (2)") in
      Eio.Fiber.yield ();
      check "B starts before A completes and cannot interleave" (not (Eio.Promise.is_resolved a) && not (Eio.Promise.is_resolved b) && counter 3 = 1);
      hold_between false;
      unwrap (Eio.Promise.await_exn a); unwrap (Eio.Promise.await_exn b);
      check "two-statement transaction then competing B have ordered native effects" (counter 3 = 3);
      let tx = Option.value_exn !escaped in
      check "escaped transaction token is revoked" (match Duckdb.execute_transaction tx "SELECT 1" with Error Duckdb.Closed -> true | _ -> false);
      check "worker callback outward scheduler effect hits core barrier"
        (match E.transaction p ~f:(fun _ -> Eio.Fiber.yield (); Ok ()) with Error (E.Core Duckdb.Effects_not_allowed) -> true | _ -> false);
      unwrap (E.shutdown p)))

let replacement_shutdown_wins clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    hold_cleanup 19 true;
    Exn.protect ~finally:(fun () -> hold_cleanup 19 false) ~f:(fun () ->
      let retiring = Eio.Fiber.fork_promise ~sw (fun () -> E.transaction p ~f:(fun _ -> Ok ())) in
      until clock "successful replacement connect returned but is not published" (fun () -> counter 19 = 1);
      let stopped = Eio.Fiber.fork_promise ~sw (fun () -> E.shutdown p) in
      check "shutdown wins while successful replacement candidate is held" (not (Eio.Promise.is_resolved retiring) && not (Eio.Promise.is_resolved stopped));
      hold_cleanup 19 false;
      unwrap (Eio.Promise.await_exn retiring); unwrap (Eio.Promise.await_exn stopped);
      check "shutdown-winning candidate closes rather than becoming idle or retrying" (counter 0 = 2 && counter 1 = 2 && counter 2 = 1)));
  check "replacement-return gate selected a successful candidate" (counter 19 = 1)

let transaction_isolation_and_reentry () =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 2 0 in
    let entered, release = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> E.transaction p ~f:(fun tx ->
      Eio.Promise.resolve release ();
      let native_snapshot () = List.init 5 ~f:counter @ [counter 14] in
      let before = native_snapshot () in
      check "create callback reentry rejected before context effects"
        (match E.create ~sw (unwrap (E.limits ~connections:1 ~queue_capacity:0)) (config ()) with
         | Error E.Reentrant_call -> true | _ -> false);
      check "execute callback reentry rejected before effects" (match E.execute p "SELECT 9" with Error E.Reentrant_call -> true | _ -> false);
      check "transaction callback reentry rejected before effects"
        (match E.transaction p ~f:(fun _ -> failwith "nested callback entered") with Error E.Reentrant_call -> true | _ -> false);
      check "shutdown callback reentry rejected before effects" (match E.shutdown p with Error E.Reentrant_call -> true | _ -> false);
      check "all callback reentries cause zero native acquisition SQL interrupt or close"
        (List.equal Int.equal before (native_snapshot ()));
      Duckdb.execute_transaction tx "CREATE TABLE tx_isolation(x INTEGER)")) in
    Eio.Promise.await entered;
    unwrap (Eio.Promise.await_exn a);
    let b = E.transaction p ~f:(fun tx -> Duckdb.execute_transaction tx "INSERT INTO tx_isolation VALUES (1)") in
    unwrap b;
    check "whole transactions retire rather than share SQL slot" (counter 0 = 4 && counter 1 = 2);
    unwrap (E.shutdown p));
  check "reentrant call made no extra native SQL" (counter 3 = 2)

let selectors env =
  let clock = Eio.Stdenv.clock env in
  ["queue_and_admission", (fun () -> queue_and_admission clock);
   "queued_shutdown", (fun () -> queued_shutdown clock);
   "fifo_overflow_and_zero", (fun () -> fifo_overflow_and_zero clock);
   "running_cancellation_then_reuse", (fun () -> running_cancellation_then_reuse clock);
   "foreign_return_then_reuse", (fun () -> foreign_return_then_reuse clock);
   "transaction_between_statements", (fun () -> transaction_between_statements clock);
   "replacement_shutdown_wins", (fun () -> replacement_shutdown_wins clock);
   "transaction_isolation_and_reentry", transaction_isolation_and_reentry]

let run_if_selected env selector =
  match List.find (selectors env) ~f:(fun (name, _) -> String.equal selector name) with
  | None -> false
  | Some (name, test) ->
    let live = Duckdb_ffi.live_resources () in
    let fallback = Duckdb_ffi.fallback_reclaims () in
    Stdlib.Printf.printf "cancellation backend=%s\n%!" (Eio.Stdenv.backend_id env);
    test ();
    if Duckdb_ffi.live_resources () <> live || Duckdb_ffi.fallback_reclaims () <> fallback then
      failwith "cancellation resource baseline not restored";
    Stdlib.Printf.printf "cancellation %s: PASS live=%d fallback=%d\n%!" name live fallback;
    true

let run env =
  Stdlib.Printf.printf "cancellation backend=%s\n%!" (Eio.Stdenv.backend_id env);
  List.iter (selectors env) ~f:(fun (name, test) ->
    if Array.length (Sys.get_argv ()) = 1 || String.equal (Sys.get_argv ()).(1) name then (
      test (); Stdlib.Printf.printf "cancellation %s: PASS\n%!" name))
