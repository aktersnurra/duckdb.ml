open! Base
module F = Duckdb_ffi
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Cancelled | Live_children | Native_error of string | Unsupported_statement
  | Data_error of Scalar.error
  | Destination_exists | Unsupported_parquet_type of { column : int; actual : int }
  | Effects_not_allowed | Rollback_failed of error * error
exception Rollback_exception of exn * error
exception Cleanup_exception of error * exn
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
      | _ -> Ok { path = (match storage with Memory -> "" | File p -> p);
                   threads; memory_limit_bytes; read_only = (match access with Read_only -> true | Read_write -> false) }
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
  let work () =
    Exn.protect ~finally:(fun () -> ignore (Sys.opaque_identity owner)) ~f:(fun () ->
      try
        let rec loop () =
          if not (request_locked request (fun () -> request.controller_stop)) then (
            (match F.Native_request.reserve_delivery native with
             | Ineligible -> ()
             | Reservation_pending -> failwith "sole controller owns native reservation"
             | Reserved ->
               Exn.protect ~finally:(fun () -> F.Native_request.retire_delivery native)
                 ~f:(fun () -> match F.Native_request.deliver native with
                   | Delivered -> request_locked request (fun () -> request.interrupted <- true)
                   | Skipped -> ()
                   | Not_reserved -> failwith "selected native reservation lost"));
            Thread.delay 0.001;
            loop ()) in
        loop ()
      with exn ->
        let failure = Some (exn, Stdlib.Printexc.get_raw_backtrace ()) in
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
    if not (match request.request_state with Running -> true | _ -> false) then Error Closed
    else if Option.exists c.owner.request_lease ~f:(phys_equal request) then Ok ()
    else Error Closed)
let gate () = { mutex = Stdlib.Mutex.create (); changed = Condition.create (); state = Open; busy = false }
let locked gate f =
  Stdlib.Mutex.lock gate.mutex;
  Exn.protect ~finally:(fun () -> Stdlib.Mutex.unlock gate.mutex)
    ~f:(fun () -> Stdlib.Sys.with_async_exns f)
let signal gate = Condition.broadcast gate.changed
let finish_operation gate = locked gate (fun () -> gate.busy <- false; signal gate)
let available gate = match gate.state with Open -> Ok () | Closing | Closed_state -> Error Closed
let admit gate extra = locked gate (fun () ->
  Result.bind (available gate) ~f:(fun () ->
    if gate.busy || extra () then Error Busy else (gate.busy <- true; Ok ())))
let protected_operation gate f =
  Exn.protect ~finally:(fun () -> finish_operation gate)
    ~f:(fun () ->
      (* Capture inside the runtime boundary: its exceptional C return otherwise
         replaces the original callback backtrace, including Query fold frames. *)
      match Stdlib.Sys.with_async_exns (fun () ->
        try Ok (f ()) with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())) with
      | Ok result -> result
      | Error (exn, backtrace) -> Stdlib.Printexc.raise_with_backtrace exn backtrace)

(* The exact pinned runtime turns asynchronous Break into an ordinary exception
   at the INNER boundary. Cleanup can finish one interrupted idempotent step and
   then re-raise; this is neither masking nor a repeated-interruption promise. *)
let complete_cleanup f =
  let call () =
    match Stdlib.Sys.with_async_exns (fun () ->
      try Ok (f ()) with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())) with
    | Ok result -> result
    | Error (exn, backtrace) -> Stdlib.Printexc.raise_with_backtrace exn backtrace in
  match call () with
  | result -> result
  | exception Stdlib.Sys.Break ->
    let backtrace = Stdlib.Printexc.get_raw_backtrace () in
    let _ = call () in
    Stdlib.Printexc.raise_with_backtrace Stdlib.Sys.Break backtrace
let native_close_database native =
  Exn.protect ~finally:(fun () -> F.finish_database_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_database native))
let native_close_connection native =
  Exn.protect ~finally:(fun () -> F.finish_connection_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_connection native))
let connection_result native = match F.connection_status native with
  | 0 -> Ok () | 2 -> Error Unsupported_statement | 3 -> Error Cancelled
  | _ -> Error (Native_error (F.connection_message native))
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
  Result.bind (raw_control c F.Commit) ~f:(fun () ->
    (* Known successful commit is durable even if cancellation won before ML
       return. Exceptions before this bookkeeping remain conservatively unknown. *)
    begin_attempted := false;
    checkpoint c)
let raw_execute c sql =
  Result.bind (checkpoint c) ~f:(fun () ->
    Exn.protect ~finally:(fun () -> F.clear_work c.owner.native_connection)
      ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
        F.execute c.owner.native_connection sql false;
        Result.bind (connection_result c.owner.native_connection) ~f:(fun () -> checkpoint c))))
let open_database config =
  let native = F.database_owner () in
  match Stdlib.Sys.with_async_exns (fun () ->
    F.open_database native config.Config.path config.threads config.memory_limit_bytes config.read_only;
    if F.database_status native = 0 then
      Ok { native_database = native; database_gate = gate (); children = [] }
    else Error (Native_error (F.database_message native))) with
  | Ok db -> Ok db
  | Error error -> native_close_database native; Error error
  | exception exn -> Exn.protect ~f:(fun () -> raise exn) ~finally:(fun () -> native_close_database native)
let connect db =
  Result.bind (admit db.database_gate (fun () -> false)) ~f:(fun () ->
    protected_operation db.database_gate (fun () ->
      let native = F.connection_owner db.native_database in
      match Stdlib.Sys.with_async_exns (fun () ->
        F.connect native;
        Result.bind (connection_result native) ~f:(fun () ->
          let c = { owner = { native_connection = native; parent = db; connection_gate = gate (); lease = None;
                    request_lease = None; prepared_children = []; result_owner = None }; request = None } in
          locked db.database_gate (fun () -> db.children <- c :: db.children);
          Ok c)) with
      | Ok c -> Ok c
      | Error error -> native_close_connection native; Error error
      | exception exn -> Exn.protect ~f:(fun () -> raise exn) ~finally:(fun () -> native_close_connection native)))
let unregister c = locked c.owner.parent.database_gate (fun () ->
  c.owner.parent.children <- List.filter c.owner.parent.children ~f:(fun child -> not (phys_equal child.owner c.owner)))
let transaction_connection tx = tx.connection
let native_connection c = c.owner.native_connection
let poison_transaction tx error = locked tx.connection.owner.connection_gate (fun () ->
  if Option.is_none tx.failure then tx.failure <- Some error)
let with_admission c tx work =
  let admission = locked c.owner.connection_gate (fun () ->
    if Option.exists tx ~f:(fun tx -> not tx.active) then Error Closed
    else Result.bind (available c.owner.connection_gate) ~f:(fun () -> Result.bind (facade_access c) ~f:(fun () ->
      let lease_matches = match c.owner.lease, tx with
        | None, None -> true | Some current, Some supplied -> phys_equal current supplied
        | _ -> false in
      if c.owner.connection_gate.busy || Option.is_some c.owner.result_owner || not lease_matches then Error Busy
      else (c.owner.connection_gate.busy <- true; Ok ())))) in
  Result.bind admission ~f:(fun () -> protected_operation c.owner.connection_gate (fun () ->
    Result.bind (checkpoint c) ~f:work))
let register_child connection transaction ~cleanup =
  let child = { connection; transaction; cleanup; child_state = Open } in
  locked connection.owner.connection_gate (fun () -> connection.owner.prepared_children <- child :: connection.owner.prepared_children);
  child
let child_is_closed (child : child) = locked child.connection.owner.connection_gate (fun () -> (match child.child_state with Closed_state -> true | _ -> false))
let unregister_child (child : child) = locked child.connection.owner.connection_gate (fun () ->
  child.child_state <- Closed_state;
  child.connection.owner.prepared_children <- List.filter child.connection.owner.prepared_children
    ~f:(fun other -> not (phys_equal child other)))
let reserve_result (child : child) = locked child.connection.owner.connection_gate (fun () -> child.connection.owner.result_owner <- Some child)
let release_result (child : child) = locked child.connection.owner.connection_gate (fun () ->
  match child.connection.owner.result_owner with
  | Some owner when phys_equal child owner -> child.connection.owner.result_owner <- None
  | None | Some _ -> ())
let child_operation ?(cleanup = false) (child : child) ~allow_result work =
  let c = child.connection in
  let admission = locked c.owner.connection_gate (fun () ->
    if (match child.child_state with Open -> false | _ -> true) || Option.exists child.transaction ~f:(fun tx -> not tx.active) then Error Closed
    else Result.bind (available c.owner.connection_gate) ~f:(fun () -> Result.bind (facade_access c) ~f:(fun () ->
      let lease_matches = match c.owner.lease, child.transaction with
        | None, None -> true | Some current, Some supplied -> phys_equal current supplied
        | _ -> false in
      let result_matches = match c.owner.result_owner with
        | None -> true | Some owner -> allow_result && phys_equal child owner in
      if c.owner.connection_gate.busy || not lease_matches || not result_matches then Error Busy
      else (c.owner.connection_gate.busy <- true; Ok ())))) in
  Result.bind admission ~f:(fun () -> protected_operation c.owner.connection_gate (fun () ->
    if cleanup then admit_cleanup c;
    Result.bind (if cleanup then Ok () else checkpoint c) ~f:work))
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
  let destroy = locked gate (fun () ->
    match child.child_state with
    | Closed_state -> false
    | Open | Closing ->
      child.child_state <- Closing;
      (* A transaction's BEGIN/settlement uses the lease rather than busy.
         Only a still-active token may close its own child inside its callback;
         revoked tokens leave destruction to settlement before waiting scopes. *)
      let foreign_lease () = match child.connection.owner.lease with
        | None -> false
        | Some tx -> not (tx.active && Option.exists child.transaction ~f:(phys_equal tx)) in
      while gate.busy || foreign_lease () do Condition.wait gate.changed gate.mutex done;
      match child.child_state with Closed_state -> false
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
    ~finally:(fun () -> locked c.owner.connection_gate (fun () ->
      c.owner.connection_gate.state <- Closed_state; c.owner.connection_gate.busy <- false; signal c.owner.connection_gate);
      unregister c)
    ~f:(fun () ->
      Exn.protect ~finally:(fun () -> detach_owner_request c; native_close_connection c.owner.native_connection)
        ~f:(fun () -> destroy_children c (fun _ -> true)))
let destroy_database db =
  Exn.protect
    ~finally:(fun () -> locked db.database_gate (fun () ->
      db.database_gate.state <- Closed_state; db.database_gate.busy <- false; signal db.database_gate))
    ~f:(fun () -> native_close_database db.native_database)
let close_connection c =
  match c.request with
  | Some _ -> locked c.owner.connection_gate (fun () ->
    Result.bind (facade_access c) ~f:(fun () -> Error Busy))
  | None ->
  let choice = locked c.owner.connection_gate (fun () ->
    match c.owner.connection_gate.state with
    | Closed_state -> Ok false
    | Closing -> Error Busy
    | Open ->
      if c.owner.connection_gate.busy || Option.is_some c.owner.request_lease || Option.is_some c.owner.lease || Option.is_some c.owner.result_owner then Error Busy
      else if not (List.is_empty c.owner.prepared_children) then Error Live_children
      else (c.owner.connection_gate.state <- Closing; c.owner.connection_gate.busy <- true; Ok true)) in
  Result.map choice ~f:(fun destroy -> if destroy then destroy_connection c)
let close_database db =
  let choice = locked db.database_gate (fun () ->
    match db.database_gate.state with
    | Closed_state -> Ok false
    | Closing -> Error Busy
    | Open ->
      if db.database_gate.busy then Error Busy
      else if not (List.is_empty db.children) then Error Live_children
      else (db.database_gate.state <- Closing; db.database_gate.busy <- true; Ok true)) in
  Result.map choice ~f:(fun destroy -> if destroy then destroy_database db)
let execute c sql =
  if String.contains sql '\000' then Error Embedded_nul
  else with_admission c None (fun () -> raw_execute c sql)
let execute_transaction tx sql =
  if String.contains sql '\000' then Error Embedded_nul
  else with_admission tx.connection (Some tx) (fun () -> raw_execute tx.connection sql)

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
let scope work cleanup =
  let result_error = ref None in
  Exn.protect
    ~finally:(fun () ->
      try complete_cleanup cleanup with exn ->
        let backtrace = Stdlib.Printexc.get_raw_backtrace () in
        let exception_ = match !result_error with None -> exn | Some error -> Cleanup_exception (error, exn) in
        Stdlib.Printexc.raise_with_backtrace exception_ backtrace)
    ~f:(fun () ->
      match Stdlib.Sys.with_async_exns (fun () ->
        try
          let result = without_escaping_effects work in
          (match result with Error error -> result_error := Some error | Ok _ -> ());
          Ok result
        with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())) with
      | Ok result -> result
      | Error (exn, backtrace) -> Stdlib.Printexc.raise_with_backtrace exn backtrace)
let force_close_connection c =
  let destroy = locked c.owner.connection_gate (fun () ->
    match c.owner.connection_gate.state with
    | Closed_state -> false
    | Open | Closing ->
      c.owner.connection_gate.state <- Closing;
      while c.owner.connection_gate.busy || Option.is_some c.owner.lease || Option.is_some c.owner.request_lease do
        Condition.wait c.owner.connection_gate.changed c.owner.connection_gate.mutex
      done;
      match c.owner.connection_gate.state with
      | Closed_state -> false
      | Open | Closing -> c.owner.connection_gate.busy <- true; true) in
  if destroy then destroy_connection c
let force_close_database db =
  let children = locked db.database_gate (fun () ->
    match db.database_gate.state with
    | Closed_state -> None
    | Open | Closing ->
      db.database_gate.state <- Closing;
      while db.database_gate.busy do Condition.wait db.database_gate.changed db.database_gate.mutex done;
      match db.database_gate.state with
      | Closed_state -> None
      | Open | Closing -> db.database_gate.busy <- true; Some db.children) in
  match children with
  | None -> ()
  | Some children ->
    (* Revoke every child before waiting for any one child. Existing transactions
       can finish rollback internally; user operations are no longer admitted. *)
    Exn.protect
      ~finally:(fun () -> finish_operation db.database_gate)
      ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
        List.iter children ~f:(fun c -> locked c.owner.connection_gate (fun () ->
          match c.owner.connection_gate.state with Open -> c.owner.connection_gate.state <- Closing | _ -> ()));
        List.iter children ~f:force_close_connection;
        destroy_database db))
let with_database config ~f =
  Result.bind (open_database config) ~f:(fun db -> scope (fun () -> f db) (fun () -> force_close_database db))
let with_connection db ~f =
  Result.bind (connect db) ~f:(fun c -> scope (fun () -> f c) (fun () -> force_close_connection c))
let with_transaction c ~f =
  let tx = { connection = c; active = true; failure = None } in
  let admission = locked c.owner.connection_gate (fun () ->
    Result.bind (facade_access c) ~f:(fun () -> Result.bind (checkpoint c) ~f:(fun () -> Result.bind (available c.owner.connection_gate) ~f:(fun () ->
      if c.owner.connection_gate.busy || Option.is_some c.owner.lease || Option.is_some c.owner.result_owner then Error Busy
      else (c.owner.lease <- Some tx; Ok ()))))) in
  Result.bind admission ~f:(fun () ->
    let begin_attempted = ref false in
    let revoke_and_drain () = locked c.owner.connection_gate (fun () ->
      tx.active <- false;
      while c.owner.connection_gate.busy do Condition.wait c.owner.connection_gate.changed c.owner.connection_gate.mutex done);
      admit_cleanup c;
      destroy_children c (fun child -> Option.exists child.transaction ~f:(phys_equal tx)) in
    let release () = locked c.owner.connection_gate (fun () -> c.owner.lease <- None; signal c.owner.connection_gate) in
    let rollback () =
      complete_cleanup (fun () -> revoke_and_drain ();
        if !begin_attempted then raw_control c F.Rollback else Ok ()) in
    let discard () =
      locked c.owner.connection_gate (fun () ->
        c.owner.connection_gate.state <- Closing;
        c.owner.connection_gate.busy <- true);
      release (); complete_cleanup (fun () -> destroy_connection c)
    in
    Exn.protect ~finally:release ~f:(fun () ->
      let outcome =
        try Stdlib.Sys.with_async_exns (fun () -> try Ok (
          match Result.bind (checkpoint c) ~f:(fun () ->
            raw_begin c begin_attempted) with
          | Error error -> Error error
          | Ok () ->
            let result = without_escaping_effects (fun () -> f tx) in
            revoke_and_drain ();
            match result, tx.failure with
            | Error error, _ -> Error error
            | Ok _, Some error -> Error error
            | Ok value, None -> Result.map (Result.bind (checkpoint c) ~f:(fun () -> raw_commit c begin_attempted)) ~f:(fun () -> value))
          with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ()))
        with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())
      in
      match outcome with
      | Ok (Ok value) -> Ok value
      | Ok (Error _) | Error _ ->
        let rolled_back = try Ok (rollback ()) with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ()) in
        let restore () = match outcome, rolled_back with
          | Ok (Error primary), Ok (Ok ()) -> Error primary
          | Error (primary, backtrace), Ok (Ok ()) -> Stdlib.Printexc.raise_with_backtrace primary backtrace
          | Ok (Error primary), Ok (Error secondary) -> Error (Rollback_failed (primary, secondary))
          | Error (primary, backtrace), Ok (Error secondary) -> Stdlib.Printexc.raise_with_backtrace (Rollback_exception (primary, secondary)) backtrace
          | Ok (Error primary), Error (secondary, backtrace) -> Stdlib.Printexc.raise_with_backtrace (Cleanup_exception (primary, secondary)) backtrace
          | Error (primary, backtrace), Error (secondary, _) -> Stdlib.Printexc.raise_with_backtrace (Exn.Finally (primary, secondary)) backtrace
          | Ok (Ok _), _ -> assert false
        in
        match rolled_back with
        | Ok (Ok ()) -> restore ()
        | Ok (Error _) | Error _ -> Exn.protect ~finally:discard ~f:restore)
)

let with_child_snapshot (child : child) work =
  match child.transaction with
  | Some _ -> work ()
  | None ->
    let c = child.connection in
    (* child_operation already owns exclusive admission. No public token or
       callback can use this internal transaction; materialization precedes COMMIT. *)
    let begin_attempted = ref false in
    let outcome =
      try Stdlib.Sys.with_async_exns (fun () -> try Ok (
        Result.bind (checkpoint c) ~f:(fun () ->
          Result.bind (raw_begin c begin_attempted) ~f:(fun () ->
            Result.bind (checkpoint c) ~f:(fun () ->
              Result.bind (work ()) ~f:(fun value ->
                Result.map (Result.bind (checkpoint c) ~f:(fun () -> raw_commit c begin_attempted)) ~f:(fun () -> value))))))
        with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ()))
      with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ()) in
    match outcome with
    | Ok (Ok value) -> Ok value
    | Ok (Error _) | Error _ ->
      let rolled_back =
        try Ok (complete_cleanup (fun () ->
          admit_cleanup c;
          if !begin_attempted then raw_control c F.Rollback else Ok ()))
        with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ()) in
      let restore () = match outcome, rolled_back with
        | Ok (Error primary), Ok (Ok ()) -> Error primary
        | Error (primary, backtrace), Ok (Ok ()) -> Stdlib.Printexc.raise_with_backtrace primary backtrace
        | Ok (Error primary), Ok (Error secondary) -> Error (Rollback_failed (primary, secondary))
        | Error (primary, backtrace), Ok (Error secondary) -> Stdlib.Printexc.raise_with_backtrace (Rollback_exception (primary, secondary)) backtrace
        | Ok (Error primary), Error (secondary, backtrace) -> Stdlib.Printexc.raise_with_backtrace (Cleanup_exception (primary, secondary)) backtrace
        | Error (primary, backtrace), Error (secondary, _) -> Stdlib.Printexc.raise_with_backtrace (Exn.Finally (primary, secondary)) backtrace
        | Ok (Ok _), _ -> assert false in
      match rolled_back with
      | Ok (Ok ()) -> restore ()
      | Ok (Error _) | Error _ ->
        Exn.protect ~finally:(fun () -> complete_cleanup (fun () -> destroy_connection c)) ~f:restore

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
      | Fresh ->
        request.request_state <- Admitted;
        Ok ())

  let run request c ~f =
    Result.bind (consume request) ~f:(fun () ->
      let request_is_installed = ref false in
      let facade = { owner = c.owner; request = Some request } in
      let admit_request () =
        locked c.owner.connection_gate (fun () ->
          match facade_access c with
          | Error _ as error -> error
          | Ok () ->
            match available c.owner.connection_gate with
            | Error _ as error -> error
            | Ok () ->
              if c.owner.connection_gate.busy
                 || Option.is_some c.owner.request_lease
                 || Option.is_some c.owner.lease
                 || Option.is_some c.owner.result_owner
              then Error Busy
              else if not (List.is_empty c.owner.prepared_children) then Error Live_children
              else request_locked request (fun () ->
                if request.cancelled then Error Cancelled
                else (
                  c.owner.request_lease <- Some request;
                  request_is_installed := true;
                  Ok ()))) in
      let bind_native () =
        (* The lease is already exclusive. Allocation failure is inside [scope],
           so even a request with no native state is revoked and released. *)
        let native = F.Native_request.create () in
        let root = Some native in
        request_locked request (fun () -> request.native_request <- root);
        let installation = F.Native_request.prepare_install c.owner.native_connection native in
        let result = request_locked request (fun () ->
          if request.cancelled then F.Native_request.cancel native;
          match F.Native_request.try_install_prepared installation with
          | Installed ->
            request.request_state <- Running;
            if request.cancelled then Error Cancelled else Ok ()
          | Connection_closed -> Error Closed
          | Install_contended | Connection_leased | Connection_active -> Error Busy
          | Request_used -> assert false) in
        Result.map result ~f:(fun () -> start_controller c.owner request native) in
      let cleanup () =
        if !request_is_installed then (
          locked c.owner.connection_gate (fun () ->
            request_locked request (fun () -> request.request_state <- Quiescing);
            while c.owner.connection_gate.busy || Option.is_some c.owner.lease do
              Condition.wait c.owner.connection_gate.changed c.owner.connection_gate.mutex
            done);
          join_controller request;
          request_locked request (fun () -> request.request_state <- Settling);
          Exn.protect ~finally:(fun () ->
            detach_request request;
            if request_locked request (fun () -> request.interrupted) then (
              locked c.owner.connection_gate (fun () ->
                c.owner.connection_gate.state <- Closing; c.owner.connection_gate.busy <- true);
              destroy_connection c))
            ~f:(fun () -> destroy_children c (fun child ->
              Option.exists child.connection.request ~f:(phys_equal request)));
          match request_locked request (fun () -> request.controller_failure) with
          | None -> ()
          | Some (exn, backtrace) -> Stdlib.Printexc.raise_with_backtrace exn backtrace) in
      let release () =
        locked c.owner.connection_gate (fun () ->
          if !request_is_installed then c.owner.request_lease <- None;
          request_locked request (fun () -> request.request_state <- Finished);
          signal c.owner.connection_gate) in
      (* Terminal classification and latch publication share the request mutex.
         Cleanup failures keep their original diagnostics, never become Cancelled. *)
      Exn.protect ~finally:release ~f:(fun () ->
        let result =
          scope
            (fun () -> Result.bind (admit_request ()) ~f:(fun () ->
              Result.bind (bind_native ()) ~f:(fun () -> f facade)))
            cleanup
        in
        locked c.owner.connection_gate (fun () ->
          request_locked request (fun () ->
            if !request_is_installed then (
              c.owner.request_lease <- None;
              request_is_installed := false);
            request.request_state <- Finished;
            signal c.owner.connection_gate;
            match result with
            | Ok _ when request.cancelled -> Error Cancelled
            | Ok _ | Error _ -> result))))
end
