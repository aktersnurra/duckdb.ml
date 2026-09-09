open! Base
module W = Worker_owner

type phase = Operation | Connect | Close_connection | Close_database
type cause = Core_failure of Duckdb.error | Raised_failure of exn * Stdlib.Printexc.raw_backtrace
type failure = { phase : phase; cause : cause }
type error =
  | Invalid_connections of int
  | Invalid_queue_capacity of int
  | Queue_full
  | Pool_shutdown
  | Reentrant_call
  | Core of Duckdb.error
  | Lifecycle_errors of failure list
exception Lifecycle_failure of failure list
exception Cancelled_with_failures of exn * Stdlib.Printexc.raw_backtrace * failure list

type limits = { connections : int; queue_capacity : int }
type lifecycle = Accepting | Stopping | Stopped
type request_state = Admitted | Waiting of Eio.Cancel.t | Running | Settled
exception Remove_waiter
type request = {
  bridge : Duckdb.Bridge.request;
  mutable cancelled : bool;
  mutable state : request_state;
  settlement : unit Eio.Promise.t;
}
type t = {
  sw : Eio.Switch.t;
  limits : limits;
  database : W.database;
  permits : Eio.Semaphore.t;
  lock : Eio.Mutex.t;
  idle : W.slot Queue.t;
  mutable owned : int;
  mutable lifecycle : lifecycle;
  mutable active : request list;
  mutable failures : failure list;
  stopping : unit Eio.Promise.t;
  resolve_stopping : unit Eio.Promise.u;
  shutdown_done : (unit, failure list) result Eio.Promise.t;
  resolve_shutdown : (unit, failure list) result Eio.Promise.u;
}
type 'a completion = Finished of ('a, failure list) result | Rejected

let limits ~connections ~queue_capacity =
  if connections <= 0 then Error (Invalid_connections connections)
  else if queue_capacity < 0 then Error (Invalid_queue_capacity queue_capacity)
  else Ok { connections; queue_capacity }

let protected f = Eio.Cancel.protect f
let locked t f = Eio.Mutex.use_rw ~protect:true t.lock f
let raised phase ex = { phase; cause = Raised_failure (ex, Stdlib.Printexc.get_raw_backtrace ()) }
let capture phase f =
  try Result.map_error (f ()) ~f:(fun e -> [{ phase; cause = Core_failure e }])
  with ex -> Error [raised phase ex]
(* Capture on the worker, BEFORE the runtime hands control back to the scheduler.
   The outer capture separately covers dispatch/offload failure. *)
let offload phase f =
  try Eio_unix.run_in_systhread (fun () -> capture phase f)
  with ex -> Error [raised phase ex]
let errors = function Ok _ -> [] | Error failures -> failures
let propagate_cancellation cancellation bt failures =
  let ordinary = List.for_all failures ~f:(function
    | { phase = Operation; cause = Core_failure (Duckdb.Cancelled | Duckdb.Native_error _) } -> true
    | _ -> false) in
  if ordinary then Exn.raise_with_original_backtrace cancellation bt
  else Exn.raise_with_original_backtrace (Cancelled_with_failures (cancellation, bt, failures)) bt
let deliver = function
  | Ok value -> Ok value
  | Error [{ phase = Operation; cause = Core_failure e }] -> Error (Core e)
  | Error ({ phase = Operation; cause = Raised_failure ((Eio.Cancel.Cancelled _ as ex), bt) } :: cleanup) ->
    propagate_cancellation ex bt cleanup
  | Error [{ phase = Operation; cause = Raised_failure (ex, bt) }] -> Exn.raise_with_original_backtrace ex bt
  | Error failures ->
    if List.exists failures ~f:(fun f -> match f.cause with Raised_failure _ -> true | Core_failure _ -> false)
    then raise (Lifecycle_failure failures)
    else Error (Lifecycle_errors failures)
let cancel request =
  request.cancelled <- true;
  match request.state with
  | Admitted | Settled -> ()
  | Waiting cc -> Eio.Cancel.cancel cc Remove_waiter
  | Running ->
    match Duckdb.Bridge.cancel request.bridge with Ok () | Error Duckdb.Closed -> () | Error _ -> ()
let is_accepting t = locked t (fun () -> Poly.equal t.lifecycle Accepting)
let start_shutdown t failures =
  let start = locked t (fun () ->
    t.failures <- t.failures @ failures;
    match t.lifecycle with
    | Accepting -> t.lifecycle <- Stopping; true
    | Stopping | Stopped -> false) in
  if start then Eio.Promise.resolve t.resolve_stopping ()

let close_slots slots database =
  let failures = List.concat_map slots ~f:(fun slot -> errors (offload Close_connection (fun () -> W.close_slot slot))) in
  failures @ errors (offload Close_database (fun () -> W.close_database database))

let drain t =
  start_shutdown t [];
  let requests = locked t (fun () -> t.active) in
  List.iter requests ~f:cancel;
  List.iter requests ~f:(fun request -> Eio.Promise.await request.settlement);
  (* Cancelling Waiting removes its semaphore entry, so queued producers can
     settle without unrelated native work. Acquiring all permits joins native
     work AND retirement/replacement cleanup, including a permit handoff that
     won the race against waiter removal. *)
  for _ = 1 to t.limits.connections do Eio.Semaphore.acquire t.permits done;
  let slots = locked t (fun () ->
    let slots = Queue.to_list t.idle in Queue.clear t.idle; slots) in
  let cleanup = close_slots slots t.database in
  let result = locked t (fun () ->
    t.failures <- t.failures @ cleanup;
    t.lifecycle <- Stopped;
    match t.failures with [] -> Ok () | failures -> Error failures) in
  Eio.Promise.resolve t.resolve_shutdown result;
  result

let create ~sw limits config =
  if W.is_in_callback () then Error Reentrant_call
  else Eio.Cancel.sub (fun caller ->
    Eio.Switch.check sw;
    protected (fun () ->
      let check_context () =
        try Eio.Cancel.check caller; Eio.Switch.check sw; Ok ()
        with ex -> Error [raised Operation ex] in
      (* Check after cleanup as well: cancellation during a protected close must
         retain the original caller exception and every initialization/close fault. *)
      let failed failures =
        match check_context () with
        | Ok () -> deliver (Error failures)
        | Error cancellation -> deliver (Error (cancellation @ failures)) in
      match offload Operation (fun () -> W.open_database config) with
      | Error failures -> failed failures
      | Ok database ->
        let acquired = ref [] in
        let rec open_slots n =
          if n = 0 then Ok ()
          else match offload Connect (fun () -> W.connect database) with
            | Ok slot -> acquired := slot :: !acquired; open_slots (n - 1)
            | Error failures -> Error failures
        in
        match open_slots limits.connections with
        | Error failures -> failed (failures @ close_slots !acquired database)
        | Ok () ->
          (* The caller sub-context is distinct from the supplied switch and
             remains observable while this fiber is inside protection. *)
          match check_context () with
          | Error failures -> deliver (Error (failures @ close_slots !acquired database))
          | Ok () ->
            let stopping, resolve_stopping = Eio.Promise.create () in
            let shutdown_done, resolve_shutdown = Eio.Promise.create () in
            let pool = {
              sw; limits; database; permits = Eio.Semaphore.make limits.connections;
              lock = Eio.Mutex.create (); idle = Queue.of_list (List.rev !acquired);
              owned = 0; lifecycle = Accepting; active = []; failures = [];
              stopping; resolve_stopping; shutdown_done; resolve_shutdown;
            } in
            (* Register the sole ordinary-context drain before publication. It
               enters protection only after its trigger, so switch cancellation
               wakes it before Switch.await_idle joins protected producers. *)
            Eio.Fiber.fork_daemon ~sw (fun () ->
              let automatic =
                try Eio.Promise.await pool.stopping; false
                with Eio.Cancel.Cancelled _ -> true in
              let result = protected (fun () -> drain pool) in
              (match automatic, result with
               | true, Error failures -> raise (Lifecycle_failure failures)
               | _ -> ());
              `Stop_daemon);
            (* Fork can schedule other fibers. Once registered, only the daemon
               owns disposal; a cancelled creator joins it instead of publishing. *)
            match check_context () with
            | Ok () -> Ok pool
            | Error failures ->
              start_shutdown pool [];
              deliver (Error (failures @ errors (Eio.Promise.await pool.shutdown_done)))))

let submit : type a. t -> reuse:bool -> (W.slot -> Duckdb.Bridge.request -> (a, Duckdb.error) result) -> (a, error) result =
 fun t ~reuse run ->
  if W.is_in_callback () then Error Reentrant_call
  else (
    Eio.Fiber.check ();
    let admitted = locked t (fun () ->
      match t.lifecycle with
      | Stopping | Stopped -> Error Pool_shutdown
      | Accepting ->
        if t.owned >= t.limits.connections && t.owned - t.limits.connections >= t.limits.queue_capacity
        then Error Queue_full
        else (t.owned <- t.owned + 1; Ok ())) in
    match admitted with
    | Error e -> Error e
    | Ok () ->
      let settlement, resolve_settlement = Eio.Promise.create () in
      let request = { bridge = Duckdb.Bridge.create (); cancelled = false; state = Admitted; settlement } in
      let completion, resolve = Eio.Promise.create () in
      locked t (fun () -> t.active <- request :: t.active);
      (* Admission through fork is scheduler-local and non-yielding except for
         uncontended locks. If sw has already failed, settle without forking. *)
      let finish result =
        locked t (fun () ->
          request.state <- Settled;
          t.active <- List.filter t.active ~f:(fun r -> not (phys_equal r request));
          t.owned <- t.owned - 1);
        Eio.Promise.resolve resolve result;
        Eio.Promise.resolve resolve_settlement () in
      if Option.is_some (Eio.Switch.get_error t.sw) then finish Rejected
      else Eio.Fiber.fork ~sw:t.sw (fun () ->
        protected (fun () ->
          let permit = ref false in
          let slot = ref None in
          let outcome =
            try
              (* Only admission waiting is cancellable; the producer itself and
                 all native ownership/settlement remain protected. Eio's semaphore
                 atomically arbitrates removal vs permit handoff. If handoff wins,
                 remember/release that permit but check cancellation before lease. *)
              Eio.Cancel.sub (fun cc ->
                request.state <- Waiting cc;
                if request.cancelled then raise Remove_waiter;
                Eio.Semaphore.acquire t.permits;
                permit := true;
                request.state <- Running);
              if request.cancelled || not (is_accepting t) then Rejected
              else (
                let owner = locked t (fun () -> Option.value_exn (Queue.dequeue t.idle)) in
                slot := Some owner;
                Finished (offload Operation (fun () -> run owner request.bridge)))
            with
            | Remove_waiter | Eio.Cancel.Cancelled Remove_waiter -> Rejected
            | ex -> Finished (Error [raised Operation ex]) in
          let reusable = match outcome with
            | Finished (Ok _) -> reuse && not request.cancelled
            | _ -> false in
          let cleanup = match !slot with
            | None -> []
            | Some owner ->
              let returned = reusable && locked t (fun () ->
                if Poly.equal t.lifecycle Accepting then (Queue.enqueue t.idle owner; true) else false) in
              if returned then []
              else (
                let failures = errors (offload Close_connection (fun () -> W.close_slot owner)) in
                if not (List.is_empty failures) then start_shutdown t failures;
                if not (is_accepting t) then failures
                else match offload Connect (fun () -> W.connect t.database) with
                  | Error replacement -> start_shutdown t replacement; failures @ replacement
                  | Ok candidate ->
                    let returned = locked t (fun () ->
                      if Poly.equal t.lifecycle Accepting then (Queue.enqueue t.idle candidate; true) else false) in
                    if returned then failures
                    else (
                      let cleanup = errors (offload Close_connection (fun () -> W.close_slot candidate)) in
                      start_shutdown t cleanup;
                      failures @ cleanup)) in
          let settled = match outcome, cleanup with
            | result, [] -> result
            | Finished (Error primary), cleanup -> Finished (Error (primary @ cleanup))
            | (Finished (Ok _) | Rejected), _ -> Finished (Error cleanup) in
          (* No native fault can bypass these scheduler-only settlement steps. *)
          if !permit then Eio.Semaphore.release t.permits;
          finish settled));
      try
        let result = Eio.Promise.await completion in
        Eio.Fiber.check ();
        match result with Rejected -> Error Pool_shutdown | Finished result -> deliver result
      with Eio.Cancel.Cancelled _ as cancellation ->
        let bt = Stdlib.Printexc.get_raw_backtrace () in
        cancel request;
        let settled = protected (fun () -> Eio.Promise.await completion) in
        let failures = match settled with Rejected -> [] | Finished result -> errors result in
        propagate_cancellation cancellation bt failures)

let execute t sql = submit t ~reuse:true (fun slot request -> W.execute slot request sql)
let transaction t ~f = submit t ~reuse:false (fun slot request -> W.transaction slot request ~f)
(* Complete typed requests conservatively retire their slot after every outcome.
   Their worker owners materialize all output before [submit] settles. *)
let query t sql row = submit t ~reuse:false (fun slot request -> W.query slot request sql row)
let fold_rows t sql row ~init ~f =
  submit t ~reuse:false (fun slot request -> W.fold_rows slot request sql row ~init ~f)
let ingest t ~schema ~table ~batches ~flush =
  submit t ~reuse:false (fun slot request -> W.ingest slot request ~schema ~table ~batches ~flush)
let parquet_fold_rows t names row ~init ~f =
  submit t ~reuse:false (fun slot request -> W.parquet_fold_rows slot request names row ~init ~f)
let parquet_export t ~query ~destination =
  submit t ~reuse:false (fun slot request -> W.parquet_export slot request ~query ~destination)
let shutdown t =
  if W.is_in_callback () then Error Reentrant_call
  else (
    start_shutdown t [];
    try
      Eio.Fiber.check ();
      let result = Eio.Promise.await t.shutdown_done in
      Eio.Fiber.check ();
      deliver result
    with Eio.Cancel.Cancelled _ as cancellation ->
      let bt = Stdlib.Printexc.get_raw_backtrace () in
      let result = protected (fun () -> Eio.Promise.await t.shutdown_done) in
      propagate_cancellation cancellation bt (errors result))
