open! Base
module F = Duckdb_ffi
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Cancelled | Live_children | Native_error of string | Unsupported_statement
  | Data_error of Scalar.error
  | Destination_exists | Unsupported_parquet_type of { column : int; actual : int }
  | Effects_not_allowed | Rollback_failed of error * error
exception Rollback_exception of exn * error
exception Cleanup_exception of error * exn

module Syntax = struct
  let ( let* ) x f = Result.bind x ~f
  let ( let+ ) x f = Result.map x ~f
end
open Syntax

module Config = struct
  type storage = Memory | File of string
  type access = Read_write | Read_only
  type t = { path : string; threads : int; memory_limit_bytes : int; read_only : bool }
  let create ?(threads = 1) ?(memory_limit_bytes = 0) ?(access = Read_write) storage =
    let invalid s = Error (Invalid_configuration s) in
    if threads <= 0 then invalid "threads must be positive"
    else if memory_limit_bytes < 0 then invalid "memory_limit_bytes must be nonnegative (0 = engine default)"
    else match storage, access with
      | Memory, Read_only -> invalid "in-memory databases cannot be read-only"
      | File path, _ when String.is_empty path || String.contains path '\000' || String.contains path ':' ->
        invalid "file path must be nonempty, NUL-free and colon-free"
      | _ ->
        let path = match storage with Memory -> "" | File path -> path in
        let read_only = match access with Read_only -> true | Read_write -> false in
        Ok { path; threads; memory_limit_bytes; read_only }
end

type state = Open | Closing | Closed_state
type gate = { mutex : Stdlib.Mutex.t; changed : Condition.t; mutable state : state; mutable busy : bool }
(* Lock order: owner gate -> request mutex -> native try-guard. Cancellation
   takes only the request mutex and publishes an atomic native latch. Native
   unref/disposal/destruction and controller join happen outside ML locks.
   Worker and sole controller root the admitted tree through selected retirement.
   The controller holds the runtime during its nonblocking native guard entry. *)
type request_state = Fresh | Admitted | Running | Quiescing | Settling | Finished
type request = { interrupt_mutex : Stdlib.Mutex.t; mutable request_state : request_state;
                 mutable cancelled : bool; mutable native_request : F.Native_request.t option;
                 mutable controller : Thread.t option; mutable controller_stop : bool;
                 mutable interrupted : bool;
                 mutable controller_failure : (exn * Stdlib.Printexc.raw_backtrace) option }
type database = { native_database : F.database; database_gate : gate; mutable children : connection list }
and owner = { native_connection : F.connection; parent : database; connection_gate : gate;
              mutable lease : transaction option; mutable request_lease : request option;
              mutable prepared_children : child list; mutable result_owner : child option }
and connection = { owner : owner; request : request option }
and transaction = { connection : connection; mutable active : bool; mutable failure : error option }
and child = { connection : connection; transaction : transaction option;
              mutable child_state : state; cleanup : unit -> unit }

(* Exceptions captured with their backtraces. *)
type raised = exn * Stdlib.Printexc.raw_backtrace
let raised exn : raised = exn, Stdlib.Printexc.get_raw_backtrace ()
let reraise ((exn, backtrace) : raised) = Stdlib.Printexc.raise_with_backtrace exn backtrace
(* Capture inside the runtime boundary: its exceptional C return otherwise
   replaces the original callback backtrace, including Query fold frames. *)
let capture f = Stdlib.Sys.with_async_exns (fun () -> try Ok (f ()) with exn -> Error (raised exn))
(* Also captures what the boundary itself raises on return. *)
let capture_all f = try capture f with exn -> Error (raised exn)
let guarded f = match capture f with Ok value -> value | Error raised -> reraise raised
let attempt f = try Ok (f ()) with exn -> Error (raised exn)

let request_locked request f =
  Stdlib.Mutex.lock request.interrupt_mutex;
  Exn.protect ~finally:(fun () -> Stdlib.Mutex.unlock request.interrupt_mutex)
    ~f:(fun () -> Stdlib.Sys.with_async_exns f)
(* Only exclusively admitted work/cleanup stops/joins; owner close waits for its lease.
   Native storage remains installed and rooted until this join has completed. *)
let join_controller request =
  let controller = request_locked request (fun () ->
    request.controller_stop <- true; request.controller) in
  Option.iter controller ~f:(fun controller ->
    Thread.join controller;
    request_locked request (fun () -> request.controller <- None))
let start_controller owner request native =
  let stopped () = request_locked request (fun () -> request.controller_stop) in
  let deliver_once () =
    match F.Native_request.reserve_delivery native with
    | Ineligible -> ()
    | Reservation_pending -> failwith "sole controller owns native reservation"
    | Reserved ->
      Exn.protect ~finally:(fun () -> F.Native_request.retire_delivery native)
        ~f:(fun () -> match F.Native_request.deliver native with
          | Delivered -> request_locked request (fun () -> request.interrupted <- true)
          | Skipped -> ()
          | Not_reserved -> failwith "selected native reservation lost") in
  let rec loop () = if not (stopped ()) then (deliver_once (); Thread.delay 0.001; loop ()) in
  let work () =
    Exn.protect ~finally:(fun () -> ignore (Sys.opaque_identity owner)) ~f:(fun () ->
      try loop () with exn ->
        let failure = Some (raised exn) in
        request_locked request (fun () ->
          request.controller_failure <- failure;
          request.cancelled <- true;
          F.Native_request.cancel native)) in
  let controller = Some (Thread.create work ()) in
  request_locked request (fun () -> request.controller <- controller)
(* This request-mutex decision orders ordinary cleanup admission against cancel.
   If cancellation won, join first. If ordinary cleanup won, the same controller
   may remain alive, but no USER boundary occurs within rollback/destruction. *)
let admit_cleanup c = match c.request with
  | None -> ()
  | Some request ->
    let cancelled = request_locked request (fun () -> request.cancelled) in
    if cancelled then join_controller request
let checkpoint c = match c.request with
  | None -> Ok ()
  | Some request -> request_locked request (fun () ->
    match request.request_state with
    | Fresh | Admitted | Quiescing | Settling | Finished -> Error Closed
    | Running -> if request.cancelled then Error Cancelled else Ok ())
(* Called with the owner gate held. Revocation is distinct from cancellation:
   cleanup may operate on a live cancelled facade but never a revoked alias. *)
let facade_access c = match c.request with
  | None -> if Option.is_some c.owner.request_lease then Error Busy else Ok ()
  | Some request -> request_locked request (fun () ->
    match request.request_state with
    | Running when Option.exists c.owner.request_lease ~f:(phys_equal request) -> Ok ()
    | Fresh | Admitted | Running | Quiescing | Settling | Finished -> Error Closed)

let gate () = { mutex = Stdlib.Mutex.create (); changed = Condition.create (); state = Open; busy = false }
let locked gate f =
  Stdlib.Mutex.lock gate.mutex;
  Exn.protect ~finally:(fun () -> Stdlib.Mutex.unlock gate.mutex)
    ~f:(fun () -> Stdlib.Sys.with_async_exns f)
let signal gate = Condition.broadcast gate.changed
(* Called with the gate held. *)
let wait_until gate condition = while not (condition ()) do Condition.wait gate.changed gate.mutex done
let idle gate () = not gate.busy
let finish_operation gate = locked gate (fun () -> gate.busy <- false; signal gate)
let begin_discard gate = locked gate (fun () -> gate.state <- Closing; gate.busy <- true)
let mark_closed gate = locked gate (fun () -> gate.state <- Closed_state; gate.busy <- false; signal gate)
let available gate () = match gate.state with Open -> Ok () | Closing | Closed_state -> Error Closed

(* Admission is an ordered list of checks evaluated under the gate. The first
   failure wins; [claim] runs, still under the gate, only when all pass. *)
let all_ok checks = List.fold checks ~init:(Ok ()) ~f:(fun acc check -> Result.bind acc ~f:check)
let require holds error () = if holds () then Ok () else Error error
let admit gate checks ~claim = locked gate (fun () -> let* () = all_ok checks in claim ())
let claim_busy gate () = gate.busy <- true; Ok ()

let protected_operation gate f = Exn.protect ~finally:(fun () -> finish_operation gate) ~f:(fun () -> guarded f)

(* The exact pinned runtime turns asynchronous Break into an ordinary exception
   at the INNER boundary. Cleanup can finish one interrupted idempotent step and
   then re-raise; this is neither masking nor a repeated-interruption promise. *)
let complete_cleanup f =
  match guarded f with
  | result -> result
  | exception Stdlib.Sys.Break ->
    let backtrace = Stdlib.Printexc.get_raw_backtrace () in
    let _ = guarded f in
    Stdlib.Printexc.raise_with_backtrace Stdlib.Sys.Break backtrace

exception Effect_denied
let without_escaping_effects work =
  let denied = ref false in
  let result =
    try Stdlib.Effect.Deep.try_with work ()
      { effc = fun (type a) (_ : a Stdlib.Effect.t) ->
          Some (fun (k : (a, _) Stdlib.Effect.Deep.continuation) ->
            denied := true; Stdlib.Effect.Deep.discontinue k Effect_denied) }
    with Effect_denied -> Error Effects_not_allowed
  in if !denied then Error Effects_not_allowed else result
(* Runs [work] effect-free, then [cleanup] on every exit. A cleanup exception
   is paired with the result error it would otherwise hide. *)
let scope work cleanup =
  let result_error = ref None in
  Exn.protect
    ~finally:(fun () ->
      try complete_cleanup cleanup with exn ->
        let backtrace = Stdlib.Printexc.get_raw_backtrace () in
        let exception_ = match !result_error with None -> exn | Some error -> Cleanup_exception (error, exn) in
        Stdlib.Printexc.raise_with_backtrace exception_ backtrace)
    ~f:(fun () -> guarded (fun () ->
      let result = without_escaping_effects work in
      Result.iter_error result ~f:(fun error -> result_error := Some error);
      result))

(* Runs [setup] on a freshly acquired native owner; any failure releases it. *)
let acquiring ~release setup =
  match Stdlib.Sys.with_async_exns setup with
  | Ok _ as ok -> ok
  | Error _ as error -> release (); error
  | exception exn -> Exn.protect ~f:(fun () -> raise exn) ~finally:release

let native_status code ~message = match F.Status.of_code code with
  | F.Status.Success -> Ok ()
  | F.Status.Unsupported -> Error Unsupported_statement
  | F.Status.Suppressed -> Error Cancelled
  | F.Status.Native_failure -> Error (Native_error (message ()))
let connection_result native =
  native_status (F.connection_status native) ~message:(fun () -> F.connection_message native)
(* [close] releases native resources; [finish] then releases the shell even
   when [close] was interrupted. Inlined so cleanup backtraces name the
   specific close function. *)
let[@inline always] release_native ~close ~finish native =
  Exn.protect ~finally:(fun () -> finish native) ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> close native))
let native_close_database native = release_native ~close:F.close_database ~finish:F.finish_database_close native
let native_close_connection native = release_native ~close:F.close_connection ~finish:F.finish_connection_close native

(* All callers own exclusive operation/transaction admission. Native admission
   decides user/BEGIN/COMMIT against the persistent latch; only rollback is
   cleanup. The native phase ends before diagnostics and result destruction. *)
let raw_control c control =
  Exn.protect ~finally:(fun () -> F.clear_work c.owner.native_connection)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.execute_control c.owner.native_connection control; connection_result c.owner.native_connection))
let raw_begin c begin_attempted =
  begin_attempted := true;
  match raw_control c F.Begin with
  | Error Cancelled as error -> begin_attempted := false; error
  | Error _ as error -> error
  | Ok () -> checkpoint c
let raw_commit c begin_attempted =
  let* () = raw_control c F.Commit in
  (* Known successful commit is durable even if cancellation won before ML
     return. Exceptions before this bookkeeping remain conservatively unknown. *)
  begin_attempted := false;
  checkpoint c
let rollback_if_begun c begin_attempted = if !begin_attempted then raw_control c F.Rollback else Ok ()
(* BEGIN, [body], COMMIT. [begin_attempted] tells the caller whether a rollback is owed. *)
let in_native_transaction c begin_attempted body =
  let* () = checkpoint c in
  let* () = raw_begin c begin_attempted in
  let* value = body () in
  let* () = checkpoint c in
  let+ () = raw_commit c begin_attempted in
  value
let raw_execute c sql =
  let* () = checkpoint c in
  Exn.protect ~finally:(fun () -> F.clear_work c.owner.native_connection)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.execute c.owner.native_connection sql false;
      let* () = connection_result c.owner.native_connection in
      checkpoint c))

(* A failed primary outcome and its rollback are both retained. *)
type failure = Failed of error | Raised of raised
let combine failure rolled_back = match failure, rolled_back with
  | Failed primary, Ok (Ok ()) -> Error primary
  | Raised primary, Ok (Ok ()) -> reraise primary
  | Failed primary, Ok (Error secondary) -> Error (Rollback_failed (primary, secondary))
  | Raised (primary, backtrace), Ok (Error secondary) ->
    Stdlib.Printexc.raise_with_backtrace (Rollback_exception (primary, secondary)) backtrace
  | Failed primary, Error (secondary, backtrace) ->
    Stdlib.Printexc.raise_with_backtrace (Cleanup_exception (primary, secondary)) backtrace
  | Raised (primary, backtrace), Error (secondary, _) ->
    Stdlib.Printexc.raise_with_backtrace (Exn.Finally (primary, secondary)) backtrace
(* Runs [work]; any error or exception rolls back. A rollback that fails or
   raises also discards the owner before the combined outcome is reported. *)
let settle ~rollback ~discard work =
  let recover failure =
    let rolled_back = attempt rollback in
    match rolled_back with
    | Ok (Ok ()) -> combine failure rolled_back
    | Ok (Error _) | Error _ -> Exn.protect ~finally:discard ~f:(fun () -> combine failure rolled_back) in
  match capture_all work with
  | Ok (Ok value) -> Ok value
  | Ok (Error error) -> recover (Failed error)
  | Error raised -> recover (Raised raised)

let open_database config =
  let native = F.database_owner () in
  acquiring ~release:(fun () -> native_close_database native) (fun () ->
    F.open_database native config.Config.path config.threads config.memory_limit_bytes config.read_only;
    let+ () = native_status (F.database_status native) ~message:(fun () -> F.database_message native) in
    { native_database = native; database_gate = gate (); children = [] })
let connect db =
  let db_gate = db.database_gate in
  let* () = admit db_gate [ available db_gate; require (idle db_gate) Busy ] ~claim:(claim_busy db_gate) in
  protected_operation db_gate (fun () ->
    let native = F.connection_owner db.native_database in
    acquiring ~release:(fun () -> native_close_connection native) (fun () ->
      F.connect native;
      let+ () = connection_result native in
      let owner = { native_connection = native; parent = db; connection_gate = gate (); lease = None;
                    request_lease = None; prepared_children = []; result_owner = None } in
      let c = { owner; request = None } in
      locked db_gate (fun () -> db.children <- c :: db.children);
      c))
let unregister c = locked c.owner.parent.database_gate (fun () ->
  c.owner.parent.children <- List.filter c.owner.parent.children ~f:(fun child -> not (phys_equal child.owner c.owner)))
let transaction_connection tx = tx.connection
let native_connection c = c.owner.native_connection
let poison_transaction tx error = locked tx.connection.owner.connection_gate (fun () ->
  if Option.is_none tx.failure then tx.failure <- Some error)
let poisoned tx = match tx.failure with Some error -> Error error | None -> Ok ()

let token_active = function None -> true | Some tx -> tx.active
let lease_matches owner tx = match owner.lease, tx with
  | None, None -> true
  | Some current, Some supplied -> phys_equal current supplied
  | Some _, None | None, Some _ -> false
let result_free owner ~holder = match owner.result_owner with
  | None -> true
  | Some current -> Option.exists holder ~f:(phys_equal current)
(* One exclusive operation: the token or child must be live, the owner open
   and reachable through this facade, and nothing else may hold it. *)
let admit_operation c ~live ~tx ~holder work =
  let gate = c.owner.connection_gate in
  let* () = admit gate
    [ require live Closed
    ; available gate
    ; (fun () -> facade_access c)
    ; require (fun () -> idle gate () && lease_matches c.owner tx && result_free c.owner ~holder) Busy ]
    ~claim:(claim_busy gate) in
  protected_operation gate work
let with_admission c tx work =
  admit_operation c ~live:(fun () -> token_active tx) ~tx ~holder:None (fun () ->
    let* () = checkpoint c in
    work ())
let child_open (child : child) = match child.child_state with Open -> true | Closing | Closed_state -> false
let child_operation ?(cleanup = false) (child : child) ~allow_result work =
  let c = child.connection in
  admit_operation c ~tx:child.transaction ~holder:(Option.some_if allow_result child)
    ~live:(fun () -> child_open child && token_active child.transaction)
    (fun () ->
      if cleanup then (admit_cleanup c; work ())
      else let* () = checkpoint c in work ())

let register_child connection transaction ~cleanup =
  let child = { connection; transaction; cleanup; child_state = Open } in
  locked connection.owner.connection_gate (fun () -> connection.owner.prepared_children <- child :: connection.owner.prepared_children);
  child
let child_is_closed (child : child) = locked child.connection.owner.connection_gate (fun () ->
  match child.child_state with Closed_state -> true | Open | Closing -> false)
let unregister_child (child : child) = locked child.connection.owner.connection_gate (fun () ->
  child.child_state <- Closed_state;
  child.connection.owner.prepared_children <- List.filter child.connection.owner.prepared_children
    ~f:(fun other -> not (phys_equal child other)))
let reserve_result (child : child) = locked child.connection.owner.connection_gate (fun () -> child.connection.owner.result_owner <- Some child)
let release_result (child : child) = locked child.connection.owner.connection_gate (fun () ->
  match child.connection.owner.result_owner with
  | Some owner when phys_equal child owner -> child.connection.owner.result_owner <- None
  | None | Some _ -> ())
let destroy_children c predicate =
  let children = locked c.owner.connection_gate (fun () -> List.filter c.owner.prepared_children ~f:predicate) in
  let rec destroy = function
    | [] -> ()
    | child :: rest ->
      Exn.protect ~finally:(fun () -> unregister_child child; destroy rest)
        ~f:(fun () -> complete_cleanup child.cleanup) in
  destroy children
let force_close_child (child : child) =
  let gate = child.connection.owner.connection_gate in
  (* A transaction's BEGIN/settlement uses the lease rather than busy.
     Only a still-active token may close its own child inside its callback;
     revoked tokens leave destruction to settlement before waiting scopes. *)
  let foreign_lease () = match child.connection.owner.lease with
    | None -> false
    | Some tx -> not (tx.active && Option.exists child.transaction ~f:(phys_equal tx)) in
  let destroy = locked gate (fun () ->
    match child.child_state with
    | Closed_state -> false
    | Open | Closing ->
      child.child_state <- Closing;
      wait_until gate (fun () -> idle gate () && not (foreign_lease ()));
      match child.child_state with
      | Closed_state -> false
      | Open | Closing -> gate.busy <- true; true) in
  if destroy then
    Exn.protect ~finally:(fun () -> unregister_child child; finish_operation gate)
      ~f:(fun () -> complete_cleanup (fun () -> admit_cleanup child.connection; child.cleanup ()))
(* Join before removing cancellation access or native ownership. Zero tickets
   alone is not foreign completion; the caller also owns drained admission. *)
let detach_request request =
  join_controller request;
  let native = request_locked request (fun () ->
    let native = request.native_request in
    request.native_request <- None;
    native) in
  Option.iter native ~f:(fun native ->
    match F.Native_request.try_uninstall native with
    | Uninstalled | Not_installed ->
      (match F.Native_request.dispose native with Ok () -> () | Error Still_installed -> assert false)
    | Uninstall_contended | Native_work_pending | Delivery_pending ->
      (* Never free pending state; retain the root and report the invariant bug. *)
      request_locked request (fun () -> request.native_request <- Some native);
      failwith "Resource native detach requires completed exclusive work")
let detach_owner_request c =
  let request = locked c.owner.connection_gate (fun () -> c.owner.request_lease) in
  Option.iter request ~f:detach_request
let destroy_connection c =
  let request = locked c.owner.connection_gate (fun () -> c.owner.request_lease) in
  Option.iter request ~f:join_controller;
  Exn.protect
    ~finally:(fun () -> mark_closed c.owner.connection_gate; unregister c)
    ~f:(fun () ->
      Exn.protect ~finally:(fun () -> detach_owner_request c; native_close_connection c.owner.native_connection)
        ~f:(fun () -> destroy_children c (fun _ -> true)))
let destroy_database db =
  Exn.protect ~finally:(fun () -> mark_closed db.database_gate)
    ~f:(fun () -> native_close_database db.native_database)

(* Manual close: a completed close succeeds again; [refuse] may veto an open owner. *)
let close_once gate ~refuse ~destroy =
  let+ first = locked gate (fun () ->
    match gate.state with
    | Closed_state -> Ok false
    | Closing -> Error Busy
    | Open ->
      let+ () = refuse () in
      gate.state <- Closing; gate.busy <- true; true) in
  if first then destroy ()
(* Scoped close: revoke admission, wait for [quiescent], then claim the owner
   once. [snapshot] is read under that same claim. *)
let force_close gate ~quiescent ~snapshot =
  locked gate (fun () ->
    match gate.state with
    | Closed_state -> None
    | Open | Closing ->
      gate.state <- Closing;
      wait_until gate quiescent;
      match gate.state with
      | Closed_state -> None
      | Open | Closing -> gate.busy <- true; Some (snapshot ()))

let close_connection c =
  let gate = c.owner.connection_gate in
  match c.request with
  | Some _ -> locked gate (fun () -> let* () = facade_access c in Error Busy)
  | None ->
    let unleased () =
      idle gate () && Option.is_none c.owner.request_lease
      && Option.is_none c.owner.lease && Option.is_none c.owner.result_owner in
    close_once gate ~destroy:(fun () -> destroy_connection c) ~refuse:(fun () ->
      all_ok [ require unleased Busy
             ; require (fun () -> List.is_empty c.owner.prepared_children) Live_children ])
let close_database db =
  let gate = db.database_gate in
  close_once gate ~destroy:(fun () -> destroy_database db) ~refuse:(fun () ->
    all_ok [ require (idle gate) Busy; require (fun () -> List.is_empty db.children) Live_children ])
let reject_nul sql = if String.contains sql '\000' then Error Embedded_nul else Ok ()
let data result = Result.map_error result ~f:(fun error -> Data_error error)
let execute c sql =
  let* () = reject_nul sql in
  with_admission c None (fun () -> raw_execute c sql)
let execute_transaction tx sql =
  let* () = reject_nul sql in
  with_admission tx.connection (Some tx) (fun () -> raw_execute tx.connection sql)

let force_close_connection c =
  let gate = c.owner.connection_gate in
  let quiescent () = idle gate () && Option.is_none c.owner.lease && Option.is_none c.owner.request_lease in
  Option.iter (force_close gate ~quiescent ~snapshot:Fn.id) ~f:(fun () -> destroy_connection c)
let force_close_database db =
  let gate = db.database_gate in
  Option.iter (force_close gate ~quiescent:(idle gate) ~snapshot:(fun () -> db.children)) ~f:(fun children ->
    (* Revoke every child before waiting for any one child. Existing transactions
       can finish rollback internally; user operations are no longer admitted. *)
    let revoke c = locked c.owner.connection_gate (fun () ->
      match c.owner.connection_gate.state with
      | Open -> c.owner.connection_gate.state <- Closing
      | Closing | Closed_state -> ()) in
    Exn.protect ~finally:(fun () -> finish_operation gate) ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      List.iter children ~f:revoke;
      List.iter children ~f:force_close_connection;
      destroy_database db)))
let with_database config ~f =
  let* db = open_database config in
  scope (fun () -> f db) (fun () -> force_close_database db)
let with_connection db ~f =
  let* c = connect db in
  scope (fun () -> f c) (fun () -> force_close_connection c)

let with_transaction c ~f =
  let gate = c.owner.connection_gate in
  let tx = { connection = c; active = true; failure = None } in
  let* () = admit gate
    [ (fun () -> facade_access c)
    ; (fun () -> checkpoint c)
    ; available gate
    ; require (fun () -> idle gate () && Option.is_none c.owner.lease && Option.is_none c.owner.result_owner) Busy ]
    ~claim:(fun () -> c.owner.lease <- Some tx; Ok ()) in
  let begin_attempted = ref false in
  let revoke_and_drain () =
    locked gate (fun () -> tx.active <- false; wait_until gate (idle gate));
    admit_cleanup c;
    destroy_children c (fun child -> Option.exists child.transaction ~f:(phys_equal tx)) in
  let release () = locked gate (fun () -> c.owner.lease <- None; signal gate) in
  let rollback () = complete_cleanup (fun () -> revoke_and_drain (); rollback_if_begun c begin_attempted) in
  let discard () = begin_discard gate; release (); complete_cleanup (fun () -> destroy_connection c) in
  Exn.protect ~finally:release ~f:(fun () ->
    settle ~rollback ~discard (fun () ->
      in_native_transaction c begin_attempted (fun () ->
        let result = without_escaping_effects (fun () -> f tx) in
        revoke_and_drain ();
        let* value = result in
        let+ () = poisoned tx in
        value)))

let with_child_snapshot (child : child) work =
  match child.transaction with
  | Some _ -> work ()
  | None ->
    let c = child.connection in
    (* child_operation already owns exclusive admission. No public token or
       callback can use this internal transaction; materialization precedes COMMIT. *)
    let begin_attempted = ref false in
    settle
      ~rollback:(fun () -> complete_cleanup (fun () -> admit_cleanup c; rollback_if_begun c begin_attempted))
      ~discard:(fun () -> complete_cleanup (fun () -> destroy_connection c))
      (fun () -> in_native_transaction c begin_attempted (fun () ->
        let* () = checkpoint c in
        work ()))

module Bridge = struct
  type nonrec request = request
  type settlement = Pending | Settled

  let create () =
    { interrupt_mutex = Stdlib.Mutex.create (); request_state = Fresh; cancelled = false; native_request = None;
      controller = None; controller_stop = false; interrupted = false; controller_failure = None }

  let cancel request =
    request_locked request (fun () ->
      match request.request_state with
      | Finished -> Error Closed
      | Fresh | Admitted | Running | Quiescing | Settling ->
        request.cancelled <- true;
        Option.iter request.native_request ~f:F.Native_request.cancel;
        Ok ())

  let settlement request =
    request_locked request (fun () ->
      match request.request_state with
      | Finished -> Settled
      | Fresh | Admitted | Running | Quiescing | Settling -> Pending)

  let consume request =
    request_locked request (fun () ->
      match request.request_state with
      | Finished -> Error Closed
      | Admitted | Running | Quiescing | Settling -> Error Busy
      | Fresh -> request.request_state <- Admitted; Ok ())

  let run request c ~f =
    let* () = consume request in
    let gate = c.owner.connection_gate in
    let installed = ref false in
    let facade = { owner = c.owner; request = Some request } in
    let admit_request () =
      let unleased () =
        idle gate () && Option.is_none c.owner.request_lease
        && Option.is_none c.owner.lease && Option.is_none c.owner.result_owner in
      admit gate
        [ (fun () -> facade_access c)
        ; available gate
        ; require unleased Busy
        ; require (fun () -> List.is_empty c.owner.prepared_children) Live_children ]
        ~claim:(fun () -> request_locked request (fun () ->
          if request.cancelled then Error Cancelled
          else (c.owner.request_lease <- Some request; installed := true; Ok ()))) in
    let bind_native () =
      (* The lease is already exclusive. Allocation failure is inside [scope],
         so even a request with no native state is revoked and released. *)
      let native = F.Native_request.create () in
      let root = Some native in
      request_locked request (fun () -> request.native_request <- root);
      let installation = F.Native_request.prepare_install c.owner.native_connection native in
      let+ () = request_locked request (fun () ->
        if request.cancelled then F.Native_request.cancel native;
        match F.Native_request.try_install_prepared installation with
        | Installed ->
          request.request_state <- Running;
          if request.cancelled then Error Cancelled else Ok ()
        | Connection_closed -> Error Closed
        | Install_contended | Connection_leased | Connection_active -> Error Busy
        | Request_used -> assert false) in
      start_controller c.owner request native in
    let cleanup () =
      if !installed then (
        locked gate (fun () ->
          request_locked request (fun () -> request.request_state <- Quiescing);
          wait_until gate (fun () -> idle gate () && Option.is_none c.owner.lease));
        join_controller request;
        request_locked request (fun () -> request.request_state <- Settling);
        Exn.protect
          ~finally:(fun () ->
            detach_request request;
            if request_locked request (fun () -> request.interrupted) then (
              begin_discard gate;
              destroy_connection c))
          ~f:(fun () -> destroy_children c (fun child ->
            Option.exists child.connection.request ~f:(phys_equal request)));
        Option.iter (request_locked request (fun () -> request.controller_failure)) ~f:reraise) in
    (* Publishes the terminal state and reports whether cancellation latched.
       The body uses it to classify the outcome; [finally] repeats it for
       exceptional exits. Classification and latch share the request mutex, and
       cleanup failures keep their original diagnostics, never become Cancelled. *)
    let finish () =
      locked gate (fun () -> request_locked request (fun () ->
        if !installed then (c.owner.request_lease <- None; installed := false);
        request.request_state <- Finished;
        signal gate;
        request.cancelled)) in
    Exn.protect ~finally:(fun () -> ignore (finish () : bool)) ~f:(fun () ->
      let result = scope (fun () ->
        let* () = admit_request () in
        let* () = bind_native () in
        f facade) cleanup in
      let cancelled = finish () in
      match result with
      | Ok _ when cancelled -> Error Cancelled
      | Ok _ | Error _ -> result)
end
