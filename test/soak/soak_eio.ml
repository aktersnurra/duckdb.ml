open! Base
module E = Duckdb_eio
exception Requested
let fail name = failwith ("stage5 eio invariant: " ^ name)
let require name value = if not value then fail name
let unwrap = function Ok value -> value | Error _ -> fail "unexpected adapter error"
let control = Sys.getenv "STAGE5_CONTROL"
let controlled name = Option.exists control ~f:(String.equal name)
let config () = unwrap (Duckdb.Config.create Duckdb.Config.Memory)
let pool sw = unwrap (E.create ~sw (unwrap (E.limits ~connections:1 ~queue_capacity:1)) (config ()))
let gate entered release =
  Stdlib.Atomic.set entered true;
  while not (Stdlib.Atomic.get release) do Stdlib.Domain.cpu_relax () done
let rec await entered = if Stdlib.Atomic.get entered then () else (Eio.Fiber.yield (); await entered)
let cancelled = function Eio.Cancel.Cancelled Requested -> true | _ -> false
let with_pool f = Eio.Switch.run (fun sw -> let p = pool sw in f sw p)
let protected_gate release f = Exn.protect ~finally:(fun () -> Stdlib.Atomic.set release true) ~f

let queued_cancel () = with_pool (fun sw p ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  protected_gate release (fun () ->
    let running = Eio.Fiber.fork_promise ~sw (fun () -> E.transaction p ~f:(fun _ -> gate entered release; Ok ())) in
    await entered;
    let context, publish = Eio.Promise.create () in
    let queued = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc -> Eio.Promise.resolve publish cc; try ignore (E.execute p "SELECT 1"); false with ex -> cancelled ex)) in
    Eio.Fiber.yield ();
    if not (controlled "capacity") then (
      Eio.Cancel.cancel (Eio.Promise.await context) Requested;
      require "queued cancellation settles" (Eio.Promise.await_exn queued));
    let replacement = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "SELECT 2") in
    Eio.Fiber.yield ();
    require "replacement admitted while A remains held" (not (Eio.Promise.is_resolved replacement));
    Stdlib.Atomic.set release true;
    ignore (Eio.Promise.await_exn running);
    require "replacement completes after A" (Result.is_ok (Eio.Promise.await_exn replacement));
    unwrap (E.shutdown p)))

let callback_cancel () = with_pool (fun sw p ->
  unwrap (E.execute p "CREATE TABLE stage5_callback(i INTEGER)");
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  protected_gate release (fun () ->
    let context, publish = Eio.Promise.create () in
    let request = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc;
      try ignore (E.transaction p ~f:(fun tx ->
        match Duckdb.execute_transaction tx "INSERT INTO stage5_callback VALUES (1)" with
        | Error error -> Error error | Ok () -> gate entered release; Ok ())); false
      with ex -> cancelled ex)) in
    await entered;
    Eio.Cancel.cancel (Eio.Promise.await context) Requested;
    if controlled "release" then require "release invariant" false;
    Stdlib.Atomic.set release true;
    require "callback cancellation settles" (Eio.Promise.await_exn request);
    let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
    require "callback cancellation suppresses commit" (match E.query p "SELECT count(*)::BIGINT FROM stage5_callback" rows with Ok [0L, ()] -> true | _ -> false);
    require "callback cancellation settles before reuse" (Result.is_ok (E.execute p "SELECT 1"));
    unwrap (E.shutdown p)))

let terminal_race () = with_pool (fun sw p ->
  let context, publish = Eio.Promise.create () in
  let request = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc;
      try `Returned (E.execute p "SELECT 42") with
      | Eio.Cancel.Cancelled Requested -> `Cancelled)) in
  let caller = Eio.Promise.await context in
  Eio.Cancel.cancel caller Requested;
  (match Eio.Promise.await_exn request with
   | `Cancelled -> ()
   | `Returned (Ok ()) ->
     (* A fast foreign return may settle before cancellation.  Only this success
        branch observes that its cancellation context is already terminal. *)
     (try Eio.Cancel.cancel caller Requested with Invalid_argument _ -> ())
   | `Returned (Error _) -> fail "terminal race must not classify adapter error as cancellation");
  unwrap (E.shutdown p))

let repeated_cancel () = with_pool (fun sw p ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  protected_gate release (fun () ->
    let context, publish = Eio.Promise.create () in
    let request = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc -> Eio.Promise.resolve publish cc; try ignore (E.transaction p ~f:(fun _ -> gate entered release; Ok ())); false with ex -> cancelled ex)) in
    await entered;
    let caller = Eio.Promise.await context in
    Eio.Cancel.cancel caller Requested; Eio.Cancel.cancel caller Requested;
    Stdlib.Atomic.set release true;
    require "repeated cancellation preserves original caller" (Eio.Promise.await_exn request);
    require "post-terminal cancellation cannot reach B" (Result.is_ok (E.execute p "SELECT 1"));
    unwrap (E.shutdown p)))

let stale_reuse () = with_pool (fun sw p ->
  let a_entered = Stdlib.Atomic.make false and a_release = Stdlib.Atomic.make false in
  protected_gate a_release (fun () ->
    let context, publish = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc; try ignore (E.transaction p ~f:(fun _ -> gate a_entered a_release; Ok ())); false with ex -> cancelled ex)) in
    await a_entered;
    let a_context = Eio.Promise.await context in
    Eio.Cancel.cancel a_context Requested;
    Stdlib.Atomic.set a_release true;
    require "A cancellation settles" (Eio.Promise.await_exn a);
    let b_entered = Stdlib.Atomic.make false and b_release = Stdlib.Atomic.make false in
    protected_gate b_release (fun () ->
      let b = Eio.Fiber.fork_promise ~sw (fun () -> E.transaction p ~f:(fun _ -> gate b_entered b_release; Ok ())) in
      await b_entered;
      (try Eio.Cancel.cancel a_context Requested with Invalid_argument _ -> ());
      (try Eio.Cancel.cancel a_context Requested with Invalid_argument _ -> ());
      Stdlib.Atomic.set b_release true;
      require "held B receives zero delayed-A effect" (Result.is_ok (Eio.Promise.await_exn b));
      unwrap (E.shutdown p))))

let shutdown_active () = with_pool (fun sw p ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  protected_gate release (fun () ->
    let active = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.protect (fun () -> E.transaction p ~f:(fun _ -> gate entered release; Ok ()))) in
    await entered;
    let queued = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "SELECT 1") in
    let context, publish = Eio.Promise.create () in
    let waiter = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc;
      if controlled "waiter" then Eio.Cancel.protect (fun () -> Eio.Fiber.yield (); true)
      else try ignore (E.shutdown p); false with ex -> cancelled ex)) in
    Eio.Cancel.cancel (Eio.Promise.await context) Requested;
    let progress, acknowledge = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Fiber.yield (); Eio.Promise.resolve acknowledge ());
    Eio.Promise.await progress;
    require "cancelled shutdown waiter remains pending while A held" (not (Eio.Promise.is_resolved waiter));
    if controlled "release" then require "release invariant" false;
    Stdlib.Atomic.set release true;
    ignore (Eio.Promise.await_exn active);
    require "queued request sees shutdown" (match Eio.Promise.await_exn queued with Error E.Pool_shutdown -> true | _ -> false);
    require "cancelled shutdown waiter preserves identity" (Eio.Promise.await_exn waiter)))

let shared_shutdown () = with_pool (fun sw p ->
  let first = Eio.Fiber.fork_promise ~sw (fun () -> E.shutdown p) in
  let second = Eio.Fiber.fork_promise ~sw (fun () -> E.shutdown p) in
  require "shared shutdown first settles" (Result.is_ok (Eio.Promise.await_exn first));
  require "shared shutdown second settles" (Result.is_ok (Eio.Promise.await_exn second)))

let typed_then_shutdown () = with_pool (fun _ p ->
  let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
  require "typed owned result" (match E.query p "SELECT 42::BIGINT" rows with Ok [42L, ()] -> true | _ -> false);
  unwrap (E.shutdown p);
  require "typed post-shutdown rejection" (match E.query p "SELECT 1::BIGINT" rows with Error E.Pool_shutdown -> true | _ -> false))

let run_episode scenario =
  let live = Duckdb_ffi.live_resources () and fallback = Duckdb_ffi.fallback_reclaims () in
  (match scenario with
   | Soak_support.Queued_cancel -> queued_cancel () | Running_callback_cancel -> callback_cancel ()
   | Terminal_race -> terminal_race () | Repeated_cancel -> repeated_cancel () | Stale_reuse -> stale_reuse ()
   | Shutdown_active -> shutdown_active () | Shutdown_shared -> shared_shutdown () | Typed_then_shutdown -> typed_then_shutdown ());
  let assert_baseline () = require "resource baseline restored" (Duckdb_ffi.live_resources () = live && Duckdb_ffi.fallback_reclaims () = fallback) in
  if not (controlled "accounting") then assert_baseline ()
  else
    let db = unwrap (Duckdb.open_database (config ())) in
    let connection = unwrap (Duckdb.connect db) in
    Exn.protect ~finally:(fun () -> unwrap (Duckdb.close_connection connection); unwrap (Duckdb.close_database db)) ~f:assert_baseline

let run ~seed ~episodes =
  let config = { Soak_support.seed; episodes } in
  Array.iteri (Soak_support.schedule config) ~f:(fun episode scenario ->
    Stdlib.Printf.printf "MODEL adapter=eio seed=%d episode=%d scenario=%s source=test/soak/soak_eio.ml\n%!" seed episode (Soak_support.scenario_name scenario);
    run_episode scenario;
    Soak_support.report ~adapter:"eio" config ~episode scenario ~detail:"episode=public-api baseline=restored")

let () = match Soak_support.parse_config (Sys.get_argv ()) with
  | Ok { seed; episodes } -> Eio_main.run (fun _ -> run ~seed ~episodes)
  | Error message -> Stdlib.prerr_endline message; Stdlib.exit 2
