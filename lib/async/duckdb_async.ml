module Gate_mutex = Mutex
open! Core
open! Async
module W = Worker_owner

type error =
  | Invalid_connections of int
  | Invalid_queue_capacity of int
  | Queue_full
  | Pool_shutdown
  | Cancelled
  | Reentrant_call
  | Core of Duckdb.error
  | Offload_unavailable of Core.Error.t

type exception_info = { exception_ : exn; backtrace : Stdlib.Printexc.raw_backtrace }
type failure =
  | Expected of error
  | Raised of exception_info
  | During_cleanup of { primary : failure; cleanup : failure }
  | During_cancellation of failure
exception Request_failed of failure
module Limits = struct
  type t = { connections : int; queue_capacity : int }
  let create ~connections ~queue_capacity =
    if connections <= 0 then Error (Invalid_connections connections)
    else if queue_capacity < 0 then Error (Invalid_queue_capacity queue_capacity)
    else Ok { connections; queue_capacity }
end

type lifecycle = Accepting | Stopping | Stopped
type request_state = Queued | Dispatched | Settling | Finished
type execution = Awaiting_entry | Executing | Returned
type execution_gate = { mutex : Gate_mutex.t; mutable execution : execution; mutable cancelled : bool }
type slot_state = Idle | Leased | Needs_close | Closing | Needs_connect | Connecting | Closed | Close_failed
type _ operation =
  | Execute : string -> unit operation
  | Transaction : (Duckdb.transaction -> ('a, Duckdb.error) result) -> 'a operation
  | Query : string * 'row Duckdb.Row.t -> 'row list operation
  | Fold_rows : string * 'row Duckdb.Row.t * 'a * ('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> 'a operation
  | Ingest : string option * string * Duckdb.cell list list list * bool -> unit operation
  | Parquet_fold_rows : string list * 'row Duckdb.Row.t * 'a * ('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> 'a operation
  | Parquet_export : string * string -> unit operation

type t =
  { limits : Limits.t
  ; database : W.database
  ; maintenance : In_thread.Helper_thread.t
  ; mutable helpers : In_thread.Helper_thread.t list
  ; slots : slot list
  ; queue : packed Doubly_linked.t
  ; monitor : Monitor.t
  ; shutdown_result : (unit, failure) result Ivar.t
  ; mutable shutdown_observer : Monitor.t option
  ; mutable lifecycle : lifecycle
  ; mutable maintenance_busy : bool
  ; mutable lifecycle_result : (unit, failure) result
  }
and slot =
  { helper : In_thread.Helper_thread.t
  ; mutable owner : W.slot option
  ; mutable state : slot_state
  ; mutable lease : packed option
  ; mutable cleanup_result : (unit, failure) result
  }
and 'a request =
  { pool : t
  ; observer : Monitor.t
  ; result : ('a, failure) result Ivar.t
  ; gate : execution_gate
  ; mutable state : request_state
  ; mutable node : packed Doubly_linked.Elt.t option
  ; mutable operation : 'a operation option
  ; mutable bridge : Duckdb.Bridge.request option
  ; mutable outcome : ('a, failure) result option
  }
and packed = Pack : 'a request -> packed

type cancel_ack = Requested | Already_finished
let capture f =
  try f () with exception_ ->
    let backtrace = Stdlib.Printexc.get_raw_backtrace () in
    Error (Raised { exception_; backtrace })
let core f = capture (fun () -> Result.map_error (f ()) ~f:(fun e -> Expected (Core e)))
let combine primary cleanup =
  match primary, cleanup with
  | result, Ok () -> result
  | Ok _, Error e -> Error e
  | Error primary, Error cleanup -> Error (During_cleanup { primary; cleanup })
let rec first_exception = function
  | Expected _ -> None
  | Raised info -> Some info
  | During_cancellation f -> first_exception f
  | During_cleanup { primary; cleanup } ->
    (match first_exception primary with Some _ as e -> e | None -> first_exception cleanup)
let notify observer = function
  | Ok _ -> ()
  | Error failure ->
    (match first_exception failure with
     | None -> ()
     | Some info ->
       let exn = match failure with Raised _ -> info.exception_ | _ -> Request_failed failure in
       (* Scheduling notification keeps user error handlers out of accounting. *)
       Scheduler.within ~monitor:observer (fun () ->
         Monitor.send_exn observer ~backtrace:(`This info.backtrace) exn))
let offload helper work =
  match capture (fun () -> Ok (In_thread.run ~thread:helper (fun () -> capture work))) with
  | Ok d -> d
  | Error failure -> return (Error failure)
let under_producer pool f =
  ignore (Scheduler.within_v ~monitor:pool.monitor f : unit option)
let with_gate gate f =
  Gate_mutex.lock gate.mutex;
  Exn.protect ~f ~finally:(fun () -> Gate_mutex.unlock gate.mutex)
let latched r = with_gate r.gate (fun () -> r.gate.cancelled)
let latch r =
  with_gate r.gate (fun () -> r.gate.cancelled <- true);
  Option.iter r.bridge ~f:(fun bridge -> ignore (Duckdb.Bridge.cancel bridge : (unit, Duckdb.error) result))
let classify r result =
  if not (latched r) then result
  else match result with
    | Ok _ | Error (Expected Cancelled) | Error (Expected (Core Duckdb.Cancelled)) -> Error (Expected Cancelled)
    | Error failure -> Error (During_cancellation failure)
let finish (r : _ request) result =
  r.state <- Finished;
  r.operation <- None;
  r.bridge <- None;
  r.outcome <- None;
  Ivar.fill_exn r.result (classify r result);
  notify r.observer (Option.value_exn (Ivar.peek r.result))
let finish_lease slot =
  match slot.lease with
  | None -> ()
  | Some (Pack r) ->
    slot.lease <- None;
    finish r (Option.value_exn r.outcome)
let add_lease_cleanup slot result =
  Option.iter slot.lease ~f:(fun (Pack r) ->
    r.outcome <- Some (combine (Option.value_exn r.outcome) result))
let release_helpers helpers =
  List.fold helpers ~init:(Ok ()) ~f:(fun result helper ->
    combine result (capture (fun () -> In_thread.Helper_thread.finished_with helper; Ok ())))

(* Only scheduler producers mutate these states. A request worker touches its
   short execution gate, its captured operation, and its opaque owner only. *)
let rec stop pool =
  match pool.lifecycle with
  | Stopping | Stopped -> ()
  | Accepting ->
    pool.lifecycle <- Stopping;
    let rec clear () =
      match Doubly_linked.remove_first pool.queue with
      | None -> ()
      | Some (Pack r) -> r.node <- None; finish r (Error (Expected Pool_shutdown)); clear () in
    clear ();
    List.iter pool.slots ~f:(fun slot ->
      Option.iter slot.lease ~f:(fun (Pack r) -> latch r);
      match slot.state with
      | Idle -> slot.state <- Needs_close
      | Needs_connect -> slot.state <- Closed; finish_lease slot
      | Leased | Needs_close | Closing | Connecting | Closed | Close_failed -> ());
    pump pool
and lifecycle_failure pool failure =
  pool.lifecycle_result <- combine pool.lifecycle_result (Error failure);
  stop pool;
  (* A failed continuation may have settled a descriptor after stop began. *)
  pump pool
and slot_failure pool slot failure =
  slot.cleanup_result <- combine slot.cleanup_result (Error failure);
  stop pool;
  pump pool
and pump pool =
  if not pool.maintenance_busy then (
    match List.find pool.slots ~f:(fun s -> match s.state with Needs_close | Needs_connect -> true | _ -> false) with
    | Some slot -> maintenance_job pool slot
    | None ->
      if (match pool.lifecycle with Stopping -> true | _ -> false)
         && List.for_all pool.slots ~f:(fun s -> match s.state with Closed | Close_failed -> true | _ -> false)
      then (
        pool.maintenance_busy <- true;
        don't_wait_for (offload pool.maintenance (fun () -> core (fun () -> W.close_database pool.database)) >>| fun result ->
          (* Completion order may differ from acquisition order. Keep one bounded
             ledger per descriptor and fold it only after all slots settle. *)
          pool.lifecycle_result <- List.fold pool.slots ~init:pool.lifecycle_result
            ~f:(fun result slot -> combine result slot.cleanup_result);
          pool.lifecycle_result <- combine pool.lifecycle_result result;
          pool.lifecycle_result <- combine pool.lifecycle_result (release_helpers pool.helpers);
          pool.helpers <- [];
          pool.maintenance_busy <- false;
          pool.lifecycle <- Stopped;
          Ivar.fill_exn pool.shutdown_result pool.lifecycle_result;
          Option.iter pool.shutdown_observer ~f:(fun monitor -> notify monitor pool.lifecycle_result))))
and maintenance_job pool slot =
  pool.maintenance_busy <- true;
  match slot.state with
  | Needs_close ->
    slot.state <- Closing;
    let owner = Option.value_exn slot.owner in
    don't_wait_for (offload pool.maintenance (fun () -> core (fun () -> W.close_slot owner)) >>| fun result ->
      pool.maintenance_busy <- false;
      add_lease_cleanup slot result;
      (match result with
       | Error failure -> slot.state <- Close_failed; slot_failure pool slot failure; finish_lease slot
       | Ok () ->
         slot.owner <- None;
         (match pool.lifecycle with
          | Accepting -> slot.state <- Needs_connect
          | Stopping | Stopped -> slot.state <- Closed; finish_lease slot));
      pump pool)
  | Needs_connect ->
    slot.state <- Connecting;
    don't_wait_for (offload pool.maintenance (fun () -> core (fun () -> W.connect pool.database)) >>| fun result ->
      pool.maintenance_busy <- false;
      (match result with
       | Error failure ->
         slot.state <- Closed;
         add_lease_cleanup slot (Error failure);
         slot_failure pool slot failure;
         finish_lease slot
       | Ok owner ->
         slot.owner <- Some owner;
         (match pool.lifecycle with
          | Accepting -> slot.state <- Idle; finish_lease slot; dispatch_waiting pool
          | Stopping | Stopped -> slot.state <- Needs_close));
      pump pool)
  | Idle | Leased | Closing | Connecting | Closed | Close_failed -> assert false
and dispatch_waiting pool =
  match pool.lifecycle with
  | Stopping | Stopped -> ()
  | Accepting ->
    List.iter pool.slots ~f:(fun slot ->
      match slot.state with
      | Idle ->
        (match Doubly_linked.remove_first pool.queue with
         | None -> ()
         | Some (Pack r) -> r.node <- None; dispatch pool slot r)
      | Leased | Needs_close | Closing | Needs_connect | Connecting | Closed | Close_failed -> ())
and dispatch : type a. t -> slot -> a request -> unit = fun pool slot r ->
  slot.state <- Leased;
  slot.lease <- Some (Pack r);
  r.state <- Dispatched;
  let bridge = Duckdb.Bridge.create () in
  r.bridge <- Some bridge;
  let owner = Option.value_exn slot.owner in
  let operation = Option.value_exn r.operation in
  r.operation <- None;
  let gate = r.gate in
  let work () =
    let enter = with_gate gate (fun () ->
      match gate.execution with
      | Awaiting_entry -> if gate.cancelled then false else (gate.execution <- Executing; true)
      | Executing | Returned -> assert false) in
    let result =
      if not enter then Error (Expected Cancelled)
      else
        let run : a operation -> (a, Duckdb.error) result = function
          | Execute sql -> W.execute owner bridge sql
          | Transaction f -> W.transaction owner bridge ~f
          | Query (sql, row) -> W.query owner bridge sql row
          | Fold_rows (sql, row, init, f) -> W.fold_rows owner bridge sql row ~init ~f
          | Ingest (schema, table, batches, flush) -> W.ingest owner bridge ~schema ~table ~batches ~flush
          | Parquet_fold_rows (names, row, init, f) -> W.parquet_fold_rows owner bridge names row ~init ~f
          | Parquet_export (query, destination) -> W.parquet_export owner bridge ~query ~destination in
        core (fun () -> run operation) in
    with_gate gate (fun () -> gate.execution <- Returned);
    result in
  don't_wait_for (offload slot.helper work >>| fun result ->
    r.state <- Settling;
    r.outcome <- Some result;
    let reusable = match operation, result, pool.lifecycle with
      | Execute _, Ok (), Accepting -> not (latched r)
      | _ -> false in
    if reusable then (slot.state <- Idle; finish_lease slot; dispatch_waiting pool)
    else (slot.state <- Needs_close; pump pool))

let reserve limits =
  let held = ref [] in
  let acquire () =
    match capture (fun () -> Result.map_error (In_thread.Helper_thread.create_now ()) ~f:(fun e -> Expected (Offload_unavailable e))) with
    | Error _ as error -> error
    | Ok helper -> held := helper :: !held; Ok helper in
  let result =
    Result.bind (acquire ()) ~f:(fun maintenance ->
      let rec loop remaining requests =
        if remaining = 0 then Ok (maintenance, List.rev requests)
        else Result.bind (acquire ()) ~f:(fun helper -> loop (remaining - 1) (helper :: requests)) in
      loop limits.Limits.connections []) in
  match result with
  | Ok _ -> result
  | Error _ -> combine result (release_helpers (List.rev !held))
let initialize maintenance request_helpers config =
  offload maintenance (fun () ->
    match core (fun () -> W.open_database config) with
    | Error _ as error -> error
    | Ok database ->
      let acquired = ref [] in
      let rec connect = function
        | [] -> Ok (database, List.rev !acquired)
        | helper :: rest ->
          (match core (fun () -> W.connect database) with
           | Error _ as error -> error
           | Ok owner -> acquired := (helper, owner) :: !acquired; connect rest) in
      let result = connect request_helpers in
      match result with
      | Ok _ -> result
      | Error _ ->
        let result = List.fold (List.rev !acquired) ~init:result ~f:(fun result (_, owner) ->
          combine result (core (fun () -> W.close_slot owner))) in
        combine result (core (fun () -> W.close_database database)))
let create limits config =
  let monitor = Monitor.create () in
  let completion = Ivar.create () in
  (* No resource is published until all N connections have been acquired. *)
  let pool_ref = ref None in
  Monitor.detach_and_iter_errors monitor ~f:(fun exn ->
    let backtrace = match exn with
      | Monitor.Monitor_exn error ->
        Option.value (Monitor.Monitor_exn.backtrace error) ~default:(Stdlib.Printexc.get_callstack 0)
      | _ -> Stdlib.Printexc.get_callstack 0 in
    let failure = Raised { exception_ = Monitor.extract_exn exn; backtrace } in
    match !pool_ref with
    | Some pool -> lifecycle_failure pool failure
    | None -> if not (Ivar.is_full completion) then Ivar.fill_exn completion (Error failure));
  ignore (Scheduler.within_v ~monitor (fun () ->
    match reserve limits with
    | Error failure -> Ivar.fill_exn completion (Error failure)
    | Ok (maintenance, requests) ->
      don't_wait_for (initialize maintenance requests config >>| function
        | Error failure -> Ivar.fill_exn completion (combine (Error failure) (release_helpers (maintenance :: requests)))
        | Ok (database, acquired) ->
          let pool =
            { limits; database; maintenance; helpers = maintenance :: requests
            ; slots = List.map acquired ~f:(fun (helper, owner) -> { helper; owner = Some owner; state = Idle; lease = None; cleanup_result = Ok () })
            ; queue = Doubly_linked.create (); monitor; shutdown_result = Ivar.create ()
            ; shutdown_observer = None; lifecycle = Accepting; maintenance_busy = false; lifecycle_result = Ok () } in
          pool_ref := Some pool;
          Ivar.fill_exn completion (Ok pool))) : unit option);
  Ivar.read completion
let admit pool operation =
  if W.is_in_callback () then Error Reentrant_call
  else match pool.lifecycle with
    | Stopping | Stopped -> Error Pool_shutdown
    | Accepting ->
      let idle = if Doubly_linked.is_empty pool.queue then List.find pool.slots ~f:(fun s -> match s.state with Idle -> true | _ -> false) else None in
      if Option.is_none idle && Doubly_linked.length pool.queue >= pool.limits.queue_capacity then Error Queue_full
      else (
        let r = { pool; observer = Monitor.current (); result = Ivar.create ()
          ; gate = { mutex = Gate_mutex.create (); execution = Awaiting_entry; cancelled = false }
          ; state = Queued; node = None; operation = Some operation; bridge = None; outcome = None } in
        under_producer pool (fun () -> match idle with
          | Some slot -> dispatch pool slot r
          | None -> r.node <- Some (Doubly_linked.insert_last pool.queue (Pack r)));
        Ok r)
let execute pool sql = admit pool (Execute sql)
let transaction pool ~f = admit pool (Transaction f)
let query pool sql row = admit pool (Query (sql, row))
let fold_rows pool sql row ~init ~f = admit pool (Fold_rows (sql, row, init, f))
let ingest pool ~schema ~table ~batches ~flush = admit pool (Ingest (schema, table, batches, flush))
let parquet_fold_rows pool names row ~init ~f = admit pool (Parquet_fold_rows (names, row, init, f))
let parquet_export pool ~query ~destination = admit pool (Parquet_export (query, destination))
let completion r = if W.is_in_callback () then Error Reentrant_call else Ok (Ivar.read r.result)
let cancel (r : _ request) =
  if W.is_in_callback () then Error Reentrant_call
  else match r.state with
    | Finished -> Ok Already_finished
    | Queued ->
      under_producer r.pool (fun () ->
        Doubly_linked.remove r.pool.queue (Option.value_exn r.node);
        r.node <- None;
        latch r;
        finish r (Error (Expected Cancelled)));
      Ok Requested
    | Dispatched | Settling -> latch r; Ok Requested
let shutdown pool =
  if W.is_in_callback () then Error Reentrant_call
  else (
    if Option.is_none pool.shutdown_observer then (
      let observer = Monitor.current () in
      pool.shutdown_observer <- Some observer;
      Option.iter (Ivar.peek pool.shutdown_result) ~f:(notify observer));
    under_producer pool (fun () -> stop pool);
    Ok (Ivar.read pool.shutdown_result))
