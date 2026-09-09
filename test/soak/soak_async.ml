open! Core
open! Async
module A = Duckdb_async

let fail name = failwith ("stage5 async invariant: " ^ name)
let require name value = if not value then fail name
let ok = function Ok value -> value | Error _ -> fail "unexpected adapter error"
let completion request = ok (A.completion request)
let config () = ok (Duckdb.Config.create Duckdb.Config.Memory)
let limits ~queue_capacity = ok (A.Limits.create ~connections:1 ~queue_capacity)
let control = Sys.getenv "STAGE5_CONTROL"
let controlled name = Option.exists control ~f:(String.equal name)
let rec await predicate =
  if predicate () then Deferred.unit
  else Scheduler.yield () >>= fun () -> await predicate
let gate entered release =
  Stdlib.Atomic.set entered true;
  while not (Stdlib.Atomic.get release) do Stdlib.Domain.cpu_relax () done
let cancelled = function
  | Error (A.Expected A.Cancelled) | Error (A.During_cancellation _) -> true
  | _ -> false
let shutdown pool = ok (A.shutdown pool)
let with_pool ?(queue_capacity = 1) f =
  A.create (limits ~queue_capacity) (config ()) >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> shutdown pool >>| ignore) (fun () -> f pool)
let protected_gate release f =
  Monitor.protect ~finally:(fun () -> Stdlib.Atomic.set release true; Deferred.unit) f

let queued_cancel () = with_pool (fun pool ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let running = ok (A.transaction pool ~f:(fun _ -> gate entered release; Ok ())) in
  protected_gate release (fun () ->
    await (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let queued = ok (A.execute pool "SELECT 1") in
    (if controlled "capacity" then Deferred.unit
     else (require "queued cancellation acknowledged" (match A.cancel queued with Ok A.Requested -> true | _ -> false);
           completion queued >>| fun result -> require "queued cancellation settles" (cancelled result)))
    >>= fun () ->
    let replacement = A.execute pool "SELECT 2" in
    require "replacement admitted while A remains held" (match replacement with Ok request -> not (Deferred.is_determined (completion request)) | Error _ -> false);
    Stdlib.Atomic.set release true;
    completion running >>= fun _ ->
    (match replacement with Ok request -> completion request >>| fun result -> require "replacement completes after A" (Result.is_ok result) | Error _ -> Deferred.unit)))

let callback_cancel () = with_pool (fun pool ->
  completion (ok (A.execute pool "CREATE TABLE stage5_callback(i INTEGER)")) >>= fun created ->
  require "callback table created" (Result.is_ok created);
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let request = ok (A.transaction pool ~f:(fun tx ->
    match Duckdb.execute_transaction tx "INSERT INTO stage5_callback VALUES (1)" with
    | Error error -> Error error
    | Ok () -> gate entered release; Ok ())) in
  protected_gate release (fun () ->
    await (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    require "callback cancellation acknowledged" (match A.cancel request with Ok A.Requested -> true | _ -> false);
    if controlled "release" then require "release invariant" false;
    Stdlib.Atomic.set release true;
    completion request >>= fun result ->
    require "callback cancellation settles" (cancelled result);
    let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
    completion (ok (A.query pool "SELECT count(*)::BIGINT FROM stage5_callback" rows)) >>= fun count ->
    require "callback cancellation suppresses commit" (match count with Ok [0L, ()] -> true | _ -> false);
    completion (ok (A.execute pool "SELECT 1")) >>| fun next -> require "callback cancellation retires before reuse" (Result.is_ok next)))

let terminal_race () = with_pool (fun pool ->
  let request = ok (A.execute pool "SELECT 42") in
  let acknowledgement = A.cancel request in
  completion request >>| fun result ->
  require "terminal race permits success or original cancellation" (Result.is_ok result || cancelled result);
  require "terminal race acknowledgement is documented" (match acknowledgement with Ok A.Requested | Ok A.Already_finished -> true | Error _ -> false))

let repeated_cancel () = with_pool (fun pool ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let request = ok (A.transaction pool ~f:(fun _ -> gate entered release; Ok ())) in
  protected_gate release (fun () ->
    await (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    require "first terminal cancellation acknowledged" (match A.cancel request with Ok A.Requested -> true | _ -> false);
    require "repeated terminal cancellation acknowledged" (match A.cancel request with Ok A.Requested -> true | _ -> false);
    Stdlib.Atomic.set release true;
    completion request >>= fun result ->
    require "terminal outcome is original cancellation" (cancelled result);
    require "post-terminal cancellation is inert" (match A.cancel request with Ok A.Already_finished -> true | _ -> false);
    completion (ok (A.execute pool "SELECT 1")) >>| fun next -> require "post-terminal cancellation cannot reach B" (Result.is_ok next)))

let stale_reuse () = with_pool (fun pool ->
  let a_entered = Stdlib.Atomic.make false and a_release = Stdlib.Atomic.make false in
  let a = ok (A.transaction pool ~f:(fun _ -> gate a_entered a_release; Ok ())) in
  protected_gate a_release (fun () ->
    await (fun () -> Stdlib.Atomic.get a_entered) >>= fun () ->
    require "A cancellation acknowledged" (match A.cancel a with Ok A.Requested -> true | _ -> false);
    Stdlib.Atomic.set a_release true;
    completion a >>= fun a_result ->
    require "A cancellation settled" (cancelled a_result);
    let b_entered = Stdlib.Atomic.make false and b_release = Stdlib.Atomic.make false in
    let b = ok (A.transaction pool ~f:(fun _ -> gate b_entered b_release; Ok ())) in
    protected_gate b_release (fun () ->
      await (fun () -> Stdlib.Atomic.get b_entered) >>= fun () ->
      require "post-terminal A cancellation is inert" (match A.cancel a with Ok A.Already_finished -> true | _ -> false);
      Stdlib.Atomic.set b_release true;
      completion b >>| fun b_result -> require "held B receives zero stale-A effect" (Result.is_ok b_result))))

let shutdown_active () = with_pool (fun pool ->
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let active = ok (A.transaction pool ~f:(fun _ -> gate entered release; Ok ())) in
  protected_gate release (fun () ->
    await (fun () -> Stdlib.Atomic.get entered) >>= fun () ->
    let queued = ok (A.execute pool "SELECT 1") in
    let first = shutdown pool and observer = shutdown pool in
    require "shared shutdown deferred" (phys_equal first observer);
    require "shutdown remains live while callback is blocked" (not (Deferred.is_determined first));
    completion queued >>= fun queued_result ->
    require "queued shutdown named" (match queued_result with Error (A.Expected A.Pool_shutdown) -> true | _ -> false);
    if controlled "release" then require "release invariant" false;
    Stdlib.Atomic.set release true;
    first >>= fun shutdown_result ->
    require "active shutdown settles" (Result.is_ok shutdown_result);
    completion active >>| fun _ ->
    require "Async observer abandonment is not cancellation" (Deferred.is_determined observer)))

let shared_shutdown () = with_pool (fun pool ->
  let first = shutdown pool and second = shutdown pool in
  require "shared shutdown observers" (phys_equal first second);
  first >>| fun result -> require "shared shutdown outcome" (Result.is_ok result))

let typed_then_shutdown () = with_pool (fun pool ->
  let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
  completion (ok (A.query pool "SELECT 42::BIGINT" rows)) >>= fun result ->
  require "typed result is owned" (match result with Ok [42L, ()] -> true | _ -> false);
  shutdown pool >>= fun stopped ->
  require "typed shutdown settles" (Result.is_ok stopped);
  require "typed post-shutdown rejection" (match A.query pool "SELECT 1::BIGINT" rows with Error A.Pool_shutdown -> true | _ -> false);
  Deferred.unit)

let run_episode scenario =
  let before_live = Duckdb_ffi.live_resources () and before_fallback = Duckdb_ffi.fallback_reclaims () in
  let action = match scenario with
    | Soak_support.Queued_cancel -> queued_cancel | Running_callback_cancel -> callback_cancel
    | Terminal_race -> terminal_race | Repeated_cancel -> repeated_cancel | Stale_reuse -> stale_reuse
    | Shutdown_active -> shutdown_active | Shutdown_shared -> shared_shutdown | Typed_then_shutdown -> typed_then_shutdown in
  action () >>= fun () ->
  let assert_baseline () =
    require "resource baseline restored" (Duckdb_ffi.live_resources () = before_live && Duckdb_ffi.fallback_reclaims () = before_fallback) in
  if not (controlled "accounting") then (assert_baseline (); Deferred.unit)
  else
    let db = ok (Duckdb.open_database (config ())) in
    let connection = ok (Duckdb.connect db) in
    Monitor.protect
      ~finally:(fun () -> ok (Duckdb.close_connection connection); ok (Duckdb.close_database db); Deferred.unit)
      (fun () -> assert_baseline (); Deferred.unit)

let run_deferred ~seed ~episodes =
  let config = { Soak_support.seed; episodes } in
  Deferred.List.iteri (Array.to_list (Soak_support.schedule config)) ~how:`Sequential
    ~f:(fun episode scenario ->
      Stdlib.Printf.printf "MODEL adapter=async seed=%d episode=%d scenario=%s source=test/soak/soak_async.ml\n%!"
        seed episode (Soak_support.scenario_name scenario);
      run_episode scenario >>| fun () ->
      Soak_support.report ~adapter:"async" config ~episode scenario ~detail:"episode=public-api baseline=restored")

let run ~seed ~episodes =
  don't_wait_for (Monitor.try_with (fun () -> run_deferred ~seed ~episodes) >>= function
    | Ok () -> Shutdown.exit 0
    | Error error -> Stdlib.prerr_endline (Exn.to_string error); Shutdown.exit 1)

let () =
  match Soak_support.parse_config (Sys.get_argv ()) with
  | Error message -> Stdlib.prerr_endline message; Stdlib.exit 2
  | Ok { seed; episodes } ->
    run ~seed ~episodes;
    never_returns (Scheduler.go ())
