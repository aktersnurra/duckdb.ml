open! Base
module F = Duckdb_ffi
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Live_children | Native_error of string | Unsupported_statement
  | Data_error of Scalar.error
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
type database = { native_database : F.database; database_gate : gate; mutable children : connection list }
and connection = { native_connection : F.connection; parent : database; connection_gate : gate;
                   mutable lease : transaction option; mutable prepared_children : child list;
                   mutable result_owner : child option }
and transaction = { connection : connection; mutable active : bool }
and child = { connection : connection; transaction : transaction option;
              mutable child_state : state; cleanup : unit -> unit }
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
    ~f:(fun () -> Stdlib.Sys.with_async_exns f)

(* The exact pinned runtime turns asynchronous Break into an ordinary exception
   at the INNER boundary. Cleanup can finish one interrupted idempotent step and
   then re-raise; this is neither masking nor a repeated-interruption promise. *)
let complete_cleanup f =
  match Stdlib.Sys.with_async_exns f with
  | result -> result
  | exception Stdlib.Sys.Break ->
    let _ = Stdlib.Sys.with_async_exns f in
    raise Stdlib.Sys.Break
let native_close_database native =
  Exn.protect ~finally:(fun () -> F.finish_database_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_database native))
let native_close_connection native =
  Exn.protect ~finally:(fun () -> F.finish_connection_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_connection native))
let connection_result native = match F.connection_status native with
  | 0 -> Ok () | 2 -> Error Unsupported_statement | _ -> Error (Native_error (F.connection_message native))
let raw_execute c sql control =
  Exn.protect ~finally:(fun () -> F.clear_work c.native_connection)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.execute c.native_connection sql control; connection_result c.native_connection))
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
          let c = { native_connection = native; parent = db; connection_gate = gate (); lease = None;
                    prepared_children = []; result_owner = None } in
          locked db.database_gate (fun () -> db.children <- c :: db.children);
          Ok c)) with
      | Ok c -> Ok c
      | Error error -> native_close_connection native; Error error
      | exception exn -> Exn.protect ~f:(fun () -> raise exn) ~finally:(fun () -> native_close_connection native)))
let unregister c = locked c.parent.database_gate (fun () ->
  c.parent.children <- List.filter c.parent.children ~f:(fun child -> not (phys_equal child c)))
let transaction_connection tx = tx.connection
let native_connection c = c.native_connection
let with_admission c tx work =
  let admission = locked c.connection_gate (fun () ->
    if Option.exists tx ~f:(fun tx -> not tx.active) then Error Closed
    else Result.bind (available c.connection_gate) ~f:(fun () ->
      let lease_matches = match c.lease, tx with
        | None, None -> true | Some current, Some supplied -> phys_equal current supplied
        | _ -> false in
      if c.connection_gate.busy || Option.is_some c.result_owner || not lease_matches then Error Busy
      else (c.connection_gate.busy <- true; Ok ()))) in
  Result.bind admission ~f:(fun () -> protected_operation c.connection_gate work)
let register_child connection transaction ~cleanup =
  let child = { connection; transaction; cleanup; child_state = Open } in
  locked connection.connection_gate (fun () -> connection.prepared_children <- child :: connection.prepared_children);
  child
let child_is_closed (child : child) = locked child.connection.connection_gate (fun () -> (match child.child_state with Closed_state -> true | _ -> false))
let unregister_child (child : child) = locked child.connection.connection_gate (fun () ->
  child.child_state <- Closed_state;
  child.connection.prepared_children <- List.filter child.connection.prepared_children
    ~f:(fun other -> not (phys_equal child other)))
let reserve_result (child : child) = locked child.connection.connection_gate (fun () -> child.connection.result_owner <- Some child)
let release_result (child : child) = locked child.connection.connection_gate (fun () ->
  match child.connection.result_owner with
  | Some owner when phys_equal child owner -> child.connection.result_owner <- None
  | None | Some _ -> ())
let child_operation (child : child) ~allow_result work =
  let c = child.connection in
  let admission = locked c.connection_gate (fun () ->
    if (match child.child_state with Open -> false | _ -> true) || Option.exists child.transaction ~f:(fun tx -> not tx.active) then Error Closed
    else Result.bind (available c.connection_gate) ~f:(fun () ->
      let lease_matches = match c.lease, child.transaction with
        | None, None -> true | Some current, Some supplied -> phys_equal current supplied
        | _ -> false in
      let result_matches = match c.result_owner with
        | None -> true | Some owner -> allow_result && phys_equal child owner in
      if c.connection_gate.busy || not lease_matches || not result_matches then Error Busy
      else (c.connection_gate.busy <- true; Ok ()))) in
  Result.bind admission ~f:(fun () -> protected_operation c.connection_gate work)
let destroy_children c predicate =
  let children = locked c.connection_gate (fun () -> List.filter c.prepared_children ~f:predicate) in
  let rec destroy = function
    | [] -> ()
    | child :: rest ->
      Exn.protect ~finally:(fun () -> unregister_child child; destroy rest)
        ~f:(fun () -> complete_cleanup child.cleanup) in
  destroy children
let force_close_child (child : child) =
  let gate = child.connection.connection_gate in
  let destroy = locked gate (fun () ->
    match child.child_state with
    | Closed_state -> false
    | Open | Closing ->
      child.child_state <- Closing;
      (* A transaction's BEGIN/settlement uses the lease rather than busy.
         Only a still-active token may close its own child inside its callback;
         revoked tokens leave destruction to settlement before waiting scopes. *)
      let foreign_lease () = match child.connection.lease with
        | None -> false
        | Some tx -> not (tx.active && Option.exists child.transaction ~f:(phys_equal tx)) in
      while gate.busy || foreign_lease () do Condition.wait gate.changed gate.mutex done;
      match child.child_state with Closed_state -> false
      | Open | Closing -> gate.busy <- true; true) in
  if destroy then
    Exn.protect ~finally:(fun () -> unregister_child child; finish_operation gate)
      ~f:(fun () -> complete_cleanup child.cleanup)
let destroy_connection c =
  Exn.protect
    ~finally:(fun () -> locked c.connection_gate (fun () ->
      c.connection_gate.state <- Closed_state; c.connection_gate.busy <- false; signal c.connection_gate);
      unregister c)
    ~f:(fun () ->
      Exn.protect ~finally:(fun () -> native_close_connection c.native_connection)
        ~f:(fun () -> destroy_children c (fun _ -> true)))
let destroy_database db =
  Exn.protect
    ~finally:(fun () -> locked db.database_gate (fun () ->
      db.database_gate.state <- Closed_state; db.database_gate.busy <- false; signal db.database_gate))
    ~f:(fun () -> native_close_database db.native_database)
let close_connection c =
  let choice = locked c.connection_gate (fun () ->
    match c.connection_gate.state with
    | Closed_state -> Ok false
    | Closing -> Error Busy
    | Open ->
      if c.connection_gate.busy || Option.is_some c.lease || Option.is_some c.result_owner then Error Busy
      else if not (List.is_empty c.prepared_children) then Error Live_children
      else (c.connection_gate.state <- Closing; c.connection_gate.busy <- true; Ok true)) in
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
  else Result.bind (admit c.connection_gate (fun () -> Option.is_some c.lease || Option.is_some c.result_owner)) ~f:(fun () ->
    protected_operation c.connection_gate (fun () -> raw_execute c sql false))
let execute_transaction tx sql =
  if String.contains sql '\000' then Error Embedded_nul
  else
    let c = tx.connection in
    let admission = locked c.connection_gate (fun () ->
      if not tx.active then Error Closed
      else Result.bind (available c.connection_gate) ~f:(fun () ->
        if c.connection_gate.busy || Option.is_some c.result_owner then Error Busy
        else (c.connection_gate.busy <- true; Ok ()))) in
    Result.bind admission ~f:(fun () -> protected_operation c.connection_gate (fun () -> raw_execute c sql false))

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
        match !result_error with None -> raise exn | Some error -> raise (Cleanup_exception (error, exn)))
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      let result = without_escaping_effects work in
      (match result with Error error -> result_error := Some error | Ok _ -> ());
      result))
let force_close_connection c =
  let destroy = locked c.connection_gate (fun () ->
    match c.connection_gate.state with
    | Closed_state -> false
    | Open | Closing ->
      c.connection_gate.state <- Closing;
      while c.connection_gate.busy || Option.is_some c.lease do
        Condition.wait c.connection_gate.changed c.connection_gate.mutex
      done;
      match c.connection_gate.state with
      | Closed_state -> false
      | Open | Closing -> c.connection_gate.busy <- true; true) in
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
        List.iter children ~f:(fun c -> locked c.connection_gate (fun () ->
          match c.connection_gate.state with Open -> c.connection_gate.state <- Closing | _ -> ()));
        List.iter children ~f:force_close_connection;
        destroy_database db))
let with_database config ~f =
  Result.bind (open_database config) ~f:(fun db -> scope (fun () -> f db) (fun () -> force_close_database db))
let with_connection db ~f =
  Result.bind (connect db) ~f:(fun c -> scope (fun () -> f c) (fun () -> force_close_connection c))
let with_transaction c ~f =
  let tx = { connection = c; active = true } in
  let admission = locked c.connection_gate (fun () ->
    Result.bind (available c.connection_gate) ~f:(fun () ->
      if c.connection_gate.busy || Option.is_some c.lease || Option.is_some c.result_owner then Error Busy
      else (c.lease <- Some tx; Ok ()))) in
  Result.bind admission ~f:(fun () ->
    let revoke_and_drain () = locked c.connection_gate (fun () ->
      tx.active <- false;
      while c.connection_gate.busy do Condition.wait c.connection_gate.changed c.connection_gate.mutex done);
      destroy_children c (fun child -> Option.exists child.transaction ~f:(phys_equal tx)) in
    let release () = locked c.connection_gate (fun () -> c.lease <- None; signal c.connection_gate) in
    let rollback () =
      complete_cleanup (fun () -> revoke_and_drain (); raw_execute c "ROLLBACK" true) in
    let discard () =
      locked c.connection_gate (fun () -> c.connection_gate.state <- Closing);
      release (); complete_cleanup (fun () -> force_close_connection c)
    in
    Exn.protect ~finally:release ~f:(fun () ->
      let outcome =
        try Ok (Stdlib.Sys.with_async_exns (fun () ->
          match raw_execute c "BEGIN TRANSACTION" true with
          | Error error -> Error error
          | Ok () ->
            let result = without_escaping_effects (fun () -> f tx) in
            revoke_and_drain ();
            match result with
            | Error error -> Error error
            | Ok value -> Result.map (raw_execute c "COMMIT" true) ~f:(fun () -> value)))
        with exn -> Error exn
      in
      match outcome with
      | Ok (Ok value) -> Ok value
      | Ok (Error _) | Error _ ->
        let rolled_back = try Ok (rollback ()) with exn -> Error exn in
        let restore () = match outcome, rolled_back with
          | Ok (Error primary), Ok (Ok ()) -> Error primary
          | Error primary, Ok (Ok ()) -> raise primary
          | Ok (Error primary), Ok (Error secondary) -> Error (Rollback_failed (primary, secondary))
          | Error primary, Ok (Error secondary) -> raise (Rollback_exception (primary, secondary))
          | Ok (Error primary), Error secondary -> raise (Cleanup_exception (primary, secondary))
          | Error primary, Error secondary -> raise (Exn.Finally (primary, secondary))
          | Ok (Ok _), _ -> assert false
        in
        match rolled_back with
        | Ok (Ok ()) -> restore ()
        | Ok (Error _) | Error _ -> Exn.protect ~finally:discard ~f:restore)
)
