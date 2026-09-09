open! Base
module E = Duckdb_eio
exception Requested
exception Close_fault of int
external reset : int -> unit = "eio_foundation_reset"
external held_entry : int -> int = "eio_foundation_held_entry"
external counter : int -> int = "eio_foundation_counter"
external hold : bool -> unit = "eio_foundation_hold"
external hold_database : bool -> unit = "eio_foundation_hold_database"
external hold_init : int -> bool -> unit = "eio_foundation_hold_init"
external fail_close : int -> int -> unit = "eio_foundation_fail_close"
external hold_cleanup : int -> bool -> unit = "eio_foundation_hold_cleanup"
let check name b = if not b then failwith name
let cancelled = function
  | Eio.Cancel.Cancelled Requested
  | E.Cancelled_with_failures (Eio.Cancel.Cancelled Requested, _, _) -> true
  | _ -> false
let unwrap = function Ok x -> x | Error _ -> failwith "unexpected error"
let config () = unwrap (Duckdb.Config.create Duckdb.Config.Memory)
let pool sw n q = unwrap (E.create ~sw (unwrap (E.limits ~connections:n ~queue_capacity:q)) (config ()))
let inventory ~connected ~disconnected ~databases =
  check "native connect attempts" (counter 0 = connected);
  check "native disconnect inventory" (counter 1 = disconnected);
  check "native database close inventory" (counter 2 = databases);
  check "native execution released runtime" (counter 6 = 0)
let failures f =
  try match f () with
    | Error (E.Lifecycle_errors fs) -> fs
    | _ -> failwith "expected lifecycle failure"
  with E.Lifecycle_failure fs -> fs
let close_faults fs = List.count fs ~f:(fun f -> match f.E.cause with
  | E.Raised_failure (Close_fault _, bt) -> Stdlib.Printexc.raw_backtrace_length bt > 0
  | _ -> false)
let original_trace = ref ""
let[@inline never] raised_callback _ =
  try raise Requested with Requested as ex ->
    let bt = Stdlib.Printexc.get_raw_backtrace () in
    original_trace := Stdlib.Printexc.raw_backtrace_to_string bt;
    Stdlib.Printexc.raise_with_backtrace ex bt
let check_trace bt =
  let text = Stdlib.Printexc.raw_backtrace_to_string bt in
  check "callback raw trace retains original prefix" (String.is_prefix text ~prefix:!original_trace);
  check "callback raw trace source frame" (String.is_substring text ~substring:"raised_callback")
let pause clock = Eio.Time.sleep clock 0.001
let until clock name condition =
  let deadline = Eio.Time.now clock +. 5. in
  let rec loop () =
    if condition () then ()
    else if Float.(Eio.Time.now clock > deadline) then failwith name
    else (pause clock; loop ()) in
  loop ()
let held clock f =
  hold true;
  Exn.protect ~f:(fun () -> f (fun () -> until clock "actual native gate entry" (fun () -> counter 5 > 0)))
    ~finally:(fun () -> hold false)
let sql = "SELECT SUM(i) FROM range(10000000000) t(i)"

let reuse_and_exception () =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    unwrap (E.execute p "SELECT 1"); unwrap (E.execute p "SELECT 2");
    inventory ~connected:1 ~disconnected:0 ~databases:0;
    check "SQL reuse independent execution count" (counter 3 = 2);
    unwrap (E.transaction p ~f:(fun _ -> Ok ()));
    inventory ~connected:2 ~disconnected:1 ~databases:0;
    (try ignore (E.transaction p ~f:raised_callback); failwith "missing callback exception"
     with Requested -> check_trace (Stdlib.Printexc.get_raw_backtrace ()));
    inventory ~connected:3 ~disconnected:2 ~databases:0;
    unwrap (E.execute p "SELECT 3");
    check "post-exception request actually executed" (counter 3 = 3);
    unwrap (E.shutdown p); unwrap (E.shutdown p));
  inventory ~connected:3 ~disconnected:3 ~databases:1

let replacement_failure clock =
  reset 1;
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 2 in
    hold_database true;
    Exn.protect ~finally:(fun () -> hold_database false) ~f:(fun () ->
    let running, queued = held clock (fun entered ->
      let running = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.protect (fun () -> E.transaction p ~f:(fun tx -> Duckdb.execute_transaction tx "SELECT 1"))) in
      entered ();
      let queued = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p "SELECT 99")) in
      Eio.Fiber.yield ();
      check "queued request has no native execution" (counter 3 = 1);
      running, queued) in
    let fs = failures (fun () -> Eio.Promise.await_exn running) in
    check "replacement failure delivered with request" (List.exists fs ~f:(fun f -> Poly.equal f.E.phase E.Connect));
    check "queued replacement-failure shutdown" (match Eio.Promise.await_exn queued with Error E.Pool_shutdown -> true | _ -> false);
    check "replacement stops admission" (match E.execute p "SELECT 88" with Error E.Pool_shutdown -> true | _ -> false);
    until clock "replacement drain at actual database close" (fun () -> counter 8 = 1);
    let a = Eio.Fiber.fork_promise ~sw (fun () -> failures (fun () -> E.shutdown p)) in
    let b = Eio.Fiber.fork_promise ~sw (fun () -> failures (fun () -> E.shutdown p)) in
    Eio.Fiber.yield ();
    check "already-Stopping shutdown waiters await native cleanup"
      (not (Eio.Promise.is_resolved a) && not (Eio.Promise.is_resolved b));
    hold_database false;
    let a = Eio.Promise.await_exn a and b = Eio.Promise.await_exn b in
    check "shared replacement shutdown retains failure" (List.length a = 1 && List.length b = 1);
    check "repeated stopped shutdown" (List.length (failures (fun () -> E.shutdown p)) = 1);
    check "no queued or rejected SQL native work" (counter 3 = 1)));
  inventory ~connected:2 ~disconnected:1 ~databases:1

let primary_and_close raised_primary =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 1 in
    fail_close 1 0;
    let fs = failures (fun () -> E.transaction p ~f:(if raised_primary then raised_callback else fun _ -> Error Duckdb.Embedded_nul)) in
    check "primary plus raised retirement close preserved" (List.length fs = 2 && close_faults fs = 1);
    (match List.hd_exn fs with
     | { E.phase = Operation; cause = Raised_failure (Requested, bt) } when raised_primary -> check_trace bt
     | { E.phase = Operation; cause = Core_failure Duckdb.Embedded_nul } when not raised_primary -> ()
     | _ -> failwith "original primary constituent lost");
    let fs = failures (fun () -> E.shutdown p) in
    check "retirement failure also retained by shutdown" (close_faults fs = 1);
    check "repeated failed shutdown settles" (close_faults (failures (fun () -> E.shutdown p)) = 1));
  inventory ~connected:1 ~disconnected:1 ~databases:1

let independent_close () =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 2 1 in
    fail_close 2 1;
    let fs = failures (fun () -> E.shutdown p) in
    check "all independent raised close failures retained" (List.length fs = 3 && close_faults fs = 3);
    check "database close attempted after BOTH connection failures"
      (Poly.equal (List.last_exn fs).E.phase E.Close_database);
    check "repeated composite shutdown settles" (close_faults (failures (fun () -> E.shutdown p)) = 3));
  inventory ~connected:2 ~disconnected:2 ~databases:1

let partial_creation () =
  reset 2;
  fail_close 2 1;
  Eio.Switch.run (fun sw ->
    let fs = failures (fun () -> E.create ~sw (unwrap (E.limits ~connections:3 ~queue_capacity:0)) (config ())) in
    check "partial init primary plus every cleanup" (List.length fs = 4 && close_faults fs = 3);
    check "partial init connect primary" (Poly.equal (List.hd_exn fs).E.phase E.Connect));
  inventory ~connected:3 ~disconnected:2 ~databases:1

let already_cancelled_creator () =
  reset (-1);
  Eio.Switch.run (fun sw ->
    Eio.Cancel.sub (fun cc ->
      Eio.Cancel.cancel cc Requested;
      let cancelled = try
        ignore (pool sw 1 0); false
      with Eio.Cancel.Cancelled Requested -> true in
      check "already-cancelled creator propagates original caller cancellation" cancelled);
    Eio.Switch.check sw;
    check "already-cancelled creator acquires no native owners"
      (counter 14 = 0 && counter 0 = 0 && counter 1 = 0 && counter 2 = 0));
  inventory ~connected:0 ~disconnected:0 ~databases:0

let cancelled_creator clock kind inject_close =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let context, resolve_context = Eio.Promise.create () in
    if inject_close then fail_close 1 1;
    hold_init kind true;
    Exn.protect ~finally:(fun () -> hold_init kind false) ~f:(fun () ->
      let creator = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve resolve_context cc;
        try ignore (pool sw 1 0); false with
        | Eio.Cancel.Cancelled Requested when not inject_close -> true
        | E.Cancelled_with_failures (Eio.Cancel.Cancelled Requested, bt, fs) when inject_close ->
          check "creator cancellation retains original backtrace" (Stdlib.Printexc.raw_backtrace_length bt > 0);
          check "creator cancellation retains both independent close failures"
            (List.length fs = 2 && close_faults fs = 2 &&
             List.equal Poly.equal (List.map fs ~f:(fun f -> f.E.phase)) [E.Close_connection; E.Close_database]);
          true)) in
      until clock "creator held at selected native initialization entry" (fun () -> counter kind = 1);
      Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      Eio.Switch.check sw;
      let heartbeat = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Fiber.yield (); true) in
      check "held init releases runtime for scheduler heartbeat" (Eio.Promise.await_exn heartbeat && counter 6 = 0);
      check "creator cannot abandon protected initialization" (not (Eio.Promise.is_resolved creator));
      hold_init kind false;
      check "cancelled creator never publishes a pool" (Eio.Promise.await_exn creator);
      (* Check before enclosing switch exit, not its eventual daemon cleanup. *)
      inventory ~connected:1 ~disconnected:1 ~databases:1;
      Eio.Switch.check sw));
  inventory ~connected:1 ~disconnected:1 ~databases:1

let creator_cancelled_during_cleanup clock =
  reset 1;
  fail_close 1 1;
  Eio.Switch.run (fun sw ->
    let context, resolve_context = Eio.Promise.create () in
    hold_database true;
    Exn.protect ~finally:(fun () -> hold_database false) ~f:(fun () ->
      let creator = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve resolve_context cc;
        try ignore (pool sw 2 0); false with
        | E.Cancelled_with_failures (Eio.Cancel.Cancelled Requested, bt, fs) ->
          check "partial init cancellation backtrace retained" (Stdlib.Printexc.raw_backtrace_length bt > 0);
          check "partial init primary and every close constituent retained"
            (List.length fs = 3 && close_faults fs = 2 &&
             List.equal Poly.equal (List.map fs ~f:(fun f -> f.E.phase)) [E.Connect; E.Close_connection; E.Close_database]);
          true)) in
      until clock "partial init cleanup held at database close" (fun () -> counter 8 = 1);
      Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      Eio.Switch.check sw;
      let heartbeat = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Fiber.yield (); true) in
      check "partial init cleanup stays pending and releases runtime"
        (Eio.Promise.await_exn heartbeat && counter 6 = 0 && not (Eio.Promise.is_resolved creator));
      hold_database false;
      check "cancellation during protected init cleanup is original cancellation" (Eio.Promise.await_exn creator);
      inventory ~connected:2 ~disconnected:1 ~databases:1));
  inventory ~connected:2 ~disconnected:1 ~databases:1

let automatic_close () =
  reset (-1);
  let fs = try
    Eio.Switch.run (fun sw -> ignore (pool sw 2 0); fail_close 2 1);
    failwith "automatic switch cleanup failure swallowed"
  with E.Lifecycle_failure fs -> fs in
  check "automatic close errors reach switch owner" (close_faults fs = 3);
  inventory ~connected:2 ~disconnected:2 ~databases:1

(* The releaser belongs to OUTER sw, not the failed/cancelled pool switch. Both
   request callers are protected, so ONLY the ordinary-context pool daemon can
   latch Bridge cancellation. Release happens before any inner join, even if
   the pre-join cancellation assertion fails. Time is a failure bound, not a
   trigger: native entry and observed interrupt causally order every action. *)
let parent_switch clock cancellation =
  reset (-1);
  Eio.Switch.run (fun outer ->
    let trigger, release_trigger = Eio.Promise.create () in
    let saw_interrupt = ref false in
    let releaser = Eio.Fiber.fork_promise ~sw:outer (fun () ->
      Eio.Promise.await trigger;
      Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
        try until clock "daemon cancellation before protected child join" (fun () -> counter 4 > 0);
          saw_interrupt := true
        with Failure _ -> ())) in
    let running_settled = ref false and queued_settled = ref false in
    let failed = try
      Eio.Cancel.sub (fun cc ->
        Eio.Switch.run (fun sw ->
          let p = pool sw 1 1 in
          hold true;
          Eio.Promise.resolve release_trigger ();
          Eio.Fiber.fork ~sw (fun () -> Eio.Cancel.protect (fun () ->
            let result = E.execute p sql in
            check "running native interruption error retained" (match result with
              | Error (E.Core (Duckdb.Cancelled | Duckdb.Native_error _)) -> true | _ -> false);
            running_settled := true));
          until clock "held work before parent failure" (fun () -> counter 5 = 1);
          Eio.Fiber.fork ~sw (fun () -> Eio.Cancel.protect (fun () ->
            check "parent-failure queued work shutdown" (match E.execute p "SELECT 99" with Error E.Pool_shutdown -> true | _ -> false);
            queued_settled := true));
          Eio.Fiber.yield ();
          if cancellation then (Eio.Cancel.cancel cc Requested; Eio.Fiber.check ()) else Eio.Switch.fail sw Requested));
      false
    with Requested | Eio.Cancel.Cancelled Requested -> true in
    Eio.Promise.await_exn releaser;
    check "parent switch failure propagated" failed;
    check "daemon native interrupt observed WHILE gate held" !saw_interrupt;
    check "protected native and queued producers settled before switch exit" (!running_settled && !queued_settled);
    check "only running SQL reached native entry" (counter 3 = 1);
    check "real engine interruption, not classification alone" (counter 7 = 1));
  inventory ~connected:1 ~disconnected:1 ~databases:1

(* Each gate is a real DuckDB child destructor reached from the synchronous
   transaction callback. While it holds a worker, a separately scheduled
   heartbeat must run, demonstrating that cleanup does not pin the scheduler
   domain. The result path folds a chunk before it is closed; the error callback
   takes the core rollback path before the adapter retires its slot. *)
let held_child_cleanup clock kind name callback cancellation =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 2 0 in
    hold_cleanup kind true;
    Exn.protect ~finally:(fun () -> hold_cleanup kind false) ~f:(fun () ->
      let context, resolve_context = Eio.Promise.create () in
      let owner = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve resolve_context cc;
          if cancellation then (try ignore (E.transaction p ~f:callback); false
            with ex -> cancelled ex)
          else (unwrap (E.transaction p ~f:callback); true))) in
      until clock ("selected " ^ name ^ " entry or completion")
        (fun () -> held_entry kind > 0 || Eio.Promise.is_resolved owner);
      check (name ^ " selected held-entry acknowledged") (held_entry kind = 1);
      check (name ^ " gate entered only after runtime release") (counter 6 = 0);
      check (name ^ " completion remains pending while selected destructor is held")
        (not (Eio.Promise.is_resolved owner));
      let heartbeat = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Fiber.yield (); true) in
      check (name ^ " cleanup leaves scheduler responsive") (Eio.Promise.await_exn heartbeat);
      if cancellation then Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      check (name ^ " remains pending after ordinary cancellation") (held_entry kind = 1 && not (Eio.Promise.is_resolved owner));
      hold_cleanup kind false;
      check (name ^ " owner settles after gate release") (Eio.Promise.await_exn owner);
      unwrap (E.shutdown p)));
  check (name ^ " selected destructor reached") (held_entry kind = 1)

let held_rollback clock cancellation =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 0 in
    hold_cleanup 16 true;
    Exn.protect ~finally:(fun () -> hold_cleanup 16 false) ~f:(fun () ->
      let context, resolve_context = Eio.Promise.create () in
      let owner = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve resolve_context cc;
        if cancellation then (try ignore (E.transaction p ~f:(fun _ -> Error Duckdb.Embedded_nul)); false
          with ex -> cancelled ex)
        else (match E.transaction p ~f:(fun _ -> Error Duckdb.Embedded_nul) with Error (E.Core Duckdb.Embedded_nul) -> true | _ -> false))) in
      until clock "rollback entry or completion" (fun () -> held_entry 16 > 0 || Eio.Promise.is_resolved owner);
      check "rollback selected held-entry acknowledged" (held_entry 16 = 1);
      check "rollback gate entered after runtime release" (counter 6 = 0 && not (Eio.Promise.is_resolved owner));
      check "rollback heartbeat" (Eio.Promise.await_exn (Eio.Fiber.fork_promise ~sw (fun () -> Eio.Fiber.yield (); true)));
      if cancellation then Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      check "rollback held through heartbeat and cancellation"
        (held_entry 16 = 1 && not (Eio.Promise.is_resolved owner));
      hold_cleanup 16 false;
      check "rollback settles after release" (Eio.Promise.await_exn owner);
      unwrap (E.shutdown p)))

let held_disconnect clock cancellation =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 0 in
    hold_cleanup 17 true;
    Exn.protect ~finally:(fun () -> hold_cleanup 17 false) ~f:(fun () ->
      let context, resolve_context = Eio.Promise.create () in
      let owner = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve resolve_context cc;
        if cancellation then (try ignore (E.shutdown p); false with ex -> cancelled ex)
        else (unwrap (E.shutdown p); true))) in
      until clock "disconnect entry or completion" (fun () -> held_entry 17 > 0 || Eio.Promise.is_resolved owner);
      check "disconnect selected held-entry acknowledged" (held_entry 17 = 1);
      check "disconnect gate entered after runtime release" (counter 6 = 0 && not (Eio.Promise.is_resolved owner));
      check "disconnect heartbeat" (Eio.Promise.await_exn (Eio.Fiber.fork_promise ~sw (fun () -> Eio.Fiber.yield (); true)));
      if cancellation then Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      check "disconnect held through heartbeat and cancellation"
        (held_entry 17 = 1 && not (Eio.Promise.is_resolved owner));
      hold_cleanup 17 false;
      check "disconnect settles after release" (Eio.Promise.await_exn owner)))

let child_cleanup_responsiveness clock =
  let result tx =
    let prepared = unwrap (Duckdb.prepare_transaction tx "SELECT 1") in
    let result = unwrap (Duckdb.execute_prepared prepared) in
    unwrap (Duckdb.close_result result); Duckdb.close_prepared prepared in
  let chunk tx =
    let prepared = unwrap (Duckdb.prepare_transaction tx "SELECT 1") in
    let result = unwrap (Duckdb.execute_prepared prepared) in
    ignore (unwrap (Duckdb.fold_chunks result ~init:() ~f:(fun _ () -> Ok (Duckdb.Stop ()) )));
    unwrap (Duckdb.close_result result); Duckdb.close_prepared prepared in
  let prepared tx = let p = unwrap (Duckdb.prepare_transaction tx "SELECT 1") in Duckdb.close_prepared p in
  let appender tx =
    unwrap (Duckdb.execute_transaction tx "CREATE TABLE cleanup_appender(x INTEGER)");
    Duckdb.close_appender (unwrap (Duckdb.open_appender tx "cleanup_appender")) in
  List.iter [9, "result", result; 10, "prepared", prepared; 11, "appender", appender; 15, "chunk", chunk]
    ~f:(fun (kind, name, callback) -> held_child_cleanup clock kind name callback false;
      held_child_cleanup clock kind (name ^ " cancellation") callback true);
  held_rollback clock false; held_rollback clock true;
  held_disconnect clock false; held_disconnect clock true

let saturated_shutdown clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 2 0 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let a = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      let b = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "all pool slots entered native SQL" (fun () -> counter 5 = 2);
      let done_ = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.shutdown p)) in
      until clock "shutdown control interrupts saturated owners" (fun () -> counter 4 = 2);
      check "shutdown control is independent of saturated request permits" (not (Eio.Promise.is_resolved done_));
      hold false;
      ignore (Eio.Promise.await_exn a); ignore (Eio.Promise.await_exn b);
      unwrap (Eio.Promise.await_exn done_)));
  inventory ~connected:2 ~disconnected:2 ~databases:1

let cancelled_shutdown_waiter clock =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 0 in
    hold true;
    Exn.protect ~finally:(fun () -> hold false) ~f:(fun () ->
      let running = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.execute p sql)) in
      until clock "shutdown cancellation running entry" (fun () -> counter 5 = 1);
      let waiter = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Fiber.fork ~sw (fun () -> Eio.Cancel.cancel cc Requested);
        try ignore (E.shutdown p); false with Eio.Cancel.Cancelled Requested -> true)) in
      until clock "cancelled shutdown waiter still starts drain" (fun () -> counter 4 = 1);
      check "cancelled shutdown waiter cannot abandon protected drain" (not (Eio.Promise.is_resolved waiter));
      hold false;
      ignore (Eio.Promise.await_exn running);
      check "cancelled shutdown caller preserves identity" (Eio.Promise.await_exn waiter);
      unwrap (E.shutdown p)));
  inventory ~connected:1 ~disconnected:1 ~databases:1

let cancellation_cleanup clock inject_close =
  reset (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw 1 0 in
    if inject_close then fail_close 1 0;
    let context, resolve_context = Eio.Promise.create () in
    let result = held clock (fun entered ->
      let result = Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve resolve_context cc;
          try ignore (E.execute p sql); failwith "missing cancellation composite"
          with
          | Eio.Cancel.Cancelled Requested when not inject_close -> ()
          | E.Cancelled_with_failures (Eio.Cancel.Cancelled Requested, bt, fs) when inject_close ->
            check "original cancellation trace" (Stdlib.Printexc.raw_backtrace_length bt > 0);
            check "Bridge primary plus actual close failure inside cancellation" (match fs with
              | [{ E.phase = Operation; cause = Raised_failure
                     (Duckdb.Cleanup_exception (Duckdb.Native_error _, Close_fault 1), bt) }] ->
                Stdlib.Printexc.raw_backtrace_length bt > 0
              | _ -> false))) in
      entered ();
      Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      until clock "caller cancellation native interrupt" (fun () -> counter 4 > 0);
      result) in
    Eio.Promise.await_exn result;
    check "cancelled query really interrupted" (counter 7 = 1);
    unwrap (E.shutdown p));
  inventory ~connected:2 ~disconnected:2 ~databases:1

let foundation_selectors env =
  let clock = Eio.Stdenv.clock env in
  ["reuse_and_exception", reuse_and_exception;
   "replacement_failure", (fun () -> replacement_failure clock);
   "core_and_close", (fun () -> primary_and_close false);
   "raised_and_close", (fun () -> primary_and_close true);
   "independent_close", independent_close;
   "partial_creation", partial_creation;
   "already_cancelled_creator", already_cancelled_creator;
   "cancelled_creator_open", (fun () -> cancelled_creator clock 12 false);
   "cancelled_creator_connect", (fun () -> cancelled_creator clock 13 false);
   "cancelled_creator_cleanup", (fun () -> cancelled_creator clock 13 true);
   "creator_cancelled_during_cleanup", (fun () -> creator_cancelled_during_cleanup clock);
   "automatic_close", automatic_close;
   "parent_failure", (fun () -> parent_switch clock false);
   "parent_cancellation", (fun () -> parent_switch clock true);
   "cancellation_cleanup", (fun () -> cancellation_cleanup clock true);
   "ordinary_cancellation", (fun () -> cancellation_cleanup clock false);
   "child_cleanup_responsiveness", (fun () -> child_cleanup_responsiveness clock);
   "saturated_shutdown", (fun () -> saturated_shutdown clock);
   "cancelled_shutdown_waiter", (fun () -> cancelled_shutdown_waiter clock)]

let run_foundation env =
  Stdlib.Printf.printf "foundation backend=%s\n%!" (Eio.Stdenv.backend_id env);
  List.iter (foundation_selectors env) ~f:(fun (name, test) ->
    test (); Stdlib.Printf.printf "foundation %s: PASS\n%!" name)

let run_foundation_if_selected env selector =
  match List.find (foundation_selectors env) ~f:(fun (name, _) -> String.equal selector name) with
  | None -> false
  | Some (name, test) ->
    let live = Duckdb_ffi.live_resources () in
    let fallback = Duckdb_ffi.fallback_reclaims () in
    Stdlib.Printf.printf "foundation backend=%s\n%!" (Eio.Stdenv.backend_id env);
    test ();
    if Duckdb_ffi.live_resources () <> live || Duckdb_ffi.fallback_reclaims () <> fallback then
      failwith "foundation resource baseline not restored";
    Stdlib.Printf.printf "foundation %s: PASS live=%d fallback=%d\n%!" name live fallback;
    true

let () =
  Stdlib.Printexc.record_backtrace true;
  Stdlib.Callback.Safe.register_exception "eio_foundation_close" (Close_fault 0);
  match Array.to_list (Sys.get_argv ()) with
  | [_] ->
    Eio_main.run run_foundation;
    Eio_main.run Cancellation_eio.run;
    Eio_main.run Typed_cases.run
  | [_; selector] ->
    if Eio_main.run (fun env -> run_foundation_if_selected env selector) then ()
    else if Eio_main.run (fun env -> Cancellation_eio.run_if_selected env selector) then ()
    else if Eio_main.run (fun env -> Typed_cases.run_if_selected env selector) then ()
    else invalid_arg ("unknown foundation_eio selector: " ^ selector)
  | _ -> invalid_arg "foundation_eio accepts at most one selector"
