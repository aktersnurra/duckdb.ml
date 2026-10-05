open! Base
open Resource
open Syntax
module F = Duckdb_ffi
module S = Scalar
type prepared = { native : F.prepared; child : child; connection : connection; sql : string;
                  parameter_types : int array;
                  bound : bool array; mutable result : query_result option;
                  mutable validated_epoch : int option }
and query_result = { prepared : prepared; mutable closed : bool }
type chunk = Borrowed_chunk.t
type 'a step = Continue of 'a | Stop of 'a

(* Parameter types observed by [observe] are known to be current while the
   schema epoch stays at the returned value: only when no schema change became
   visible during it, and only in a fresh snapshot (no explicit transaction,
   whose snapshot may predate later changes). *)
let stable_epoch ~fresh observe =
  let before = F.schema_epoch () in
  let+ () = observe () in
  if fresh && F.schema_epoch () = before then Some before else None

(* Held-runtime metadata is admitted as a synchronous batch, not separately
   interruptible calls. Checkpoint again before publishing its owned output. *)
let status native = native_status (F.prepared_status native) ~message:(fun () -> F.prepared_message native)
let settled c native = let* () = status native in checkpoint c
let native_close c native =
  admit_cleanup c;
  release_native ~close:F.close_prepared ~finish:F.finish_prepared_close native
let native_close_result c native =
  admit_cleanup c;
  release_native ~close:F.close_result ~finish:F.finish_result_close native
let revoke_result p =
  Option.iter p.result ~f:(fun r -> r.closed <- true);
  p.result <- None;
  release_result p.child
let destroy_result r =
  Exn.protect ~finally:(fun () ->
    r.closed <- true; r.prepared.result <- None; release_result r.prepared.child)
    ~f:(fun () -> native_close_result r.prepared.connection r.prepared.native)

(* The parent owns this cleanup even if the caller drops every alias. *)
let register c tx native ~cached ~sql ~parameter_types ~validated_epoch =
  let self = ref None in
  let cleanup () =
    Exn.protect ~finally:(fun () -> Option.iter !self ~f:revoke_result)
      ~f:(fun () -> native_close c native) in
  let child = if cached then register_cached_child c ~cleanup else register_child c tx ~cleanup in
  let bound = Array.create ~len:(Array.length parameter_types) false in
  let p = { native; child; connection = c; sql; parameter_types; bound; result = None; validated_epoch } in
  self := Some p;
  p
let prepare_on ?(cached = false) c tx sql =
  let* () = reject_nul sql in
  with_admission c tx (fun () ->
    let native = F.prepared_owner (native_connection c) in
    acquiring ~release:(fun () -> native_close c native) (fun () ->
      let* validated_epoch = stable_epoch ~fresh:(Option.is_none tx) (fun () ->
        F.prepare native sql;
        settled c native) in
      let parameter_types = Array.init (F.parameter_count native) ~f:(fun i -> F.parameter_type native (i + 1)) in
      let+ () = checkpoint c in
      register c tx native ~cached ~sql ~parameter_types ~validated_epoch))
let prepare c sql = prepare_on c None sql
let prepare_cached c sql = prepare_on ~cached:true c None sql
let prepare_transaction tx sql = prepare_on (transaction_connection tx) (Some tx) sql

let without_result ?(cleanup = false) p work = child_operation ~cleanup p.child ~allow_result:true (fun () ->
  if Option.is_some p.result then Error Live_children else work ())
let close_prepared p =
  if child_is_closed p.child then Ok ()
  else without_result ~cleanup:true p (fun () ->
    Exn.protect ~finally:(fun () -> unregister_child p.child)
      ~f:(fun () -> native_close p.connection p.native; Ok ()))
let parameter_count p = child_operation p.child ~allow_result:true (fun () -> Ok (Array.length p.bound))
let reset p = without_result p (fun () ->
  (* A failed/interrupted reset leaves no binding marked usable. *)
  Array.fill p.bound ~pos:0 ~len:(Array.length p.bound) false;
  F.reset p.native;
  settled p.connection p.native)

let bind_value : type a. prepared -> int -> a S.t -> a -> unit = fun p index typ value ->
  let id = S.native_id typ in
  match S.repr typ with
  | S.Integer { encode; _ } -> F.bind_int64 p.native index id (encode value)
  | S.Floating { encode; _ } -> F.bind_float p.native index id (encode value)
  | S.Bytes -> F.bind_string p.native index id value
(* Unresolved parameters accept whichever witness the caller supplies. *)
let accepts actual typ = actual = F.Type_id.invalid || actual = F.Type_id.any || actual = S.native_id typ
let bind_scalar : type b. prepared -> int -> b S.t -> b option -> (unit, error) result = fun p index typ value ->
  without_result p (fun () ->
    let count = Array.length p.bound in
    if index < 1 || index > count then Error (Data_error (S.Index { index; length = count }))
    else
      let actual = p.parameter_types.(index - 1) in
      let* () =
        if accepts actual typ then Ok ()
        else Error (Data_error (S.Type_mismatch { index; expected = S.name typ; actual })) in
      p.bound.(index - 1) <- false;
      Exn.protect ~finally:(fun () -> F.clear_prepared_input p.native)
        ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
          (match value with None -> F.bind_null p.native index | Some x -> bind_value p index typ x);
          let+ () = settled p.connection p.native in
          p.bound.(index - 1) <- true)))

(* User encoders run before connection admission. *)
let bind : type a n. prepared -> int -> (a, n) Codec.t -> a -> (unit, error) result = fun p index codec value ->
  let encoded encode value = Result.map_error (encode value) ~f:(fun reason ->
    Data_error (S.Encode_rejected { index; reason })) in
  match codec with
  | Codec.Non_null (Codec.Plan plan) ->
    let* b = encoded plan.encode value in bind_scalar p index plan.scalar (Some b)
  | Codec.Nullable (Codec.Plan plan) ->
    match value with
    | None -> bind_scalar p index plan.scalar None
    | Some v -> let* b = encoded plan.encode v in bind_scalar p index plan.scalar (Some b)

let check_parameter_schema p =
  let fresh = F.prepared_owner (native_connection p.connection) in
  let unchanged () =
    F.parameter_count fresh = Array.length p.parameter_types
    && Array.for_alli p.parameter_types ~f:(fun i typ -> F.parameter_type fresh (i + 1) = typ) in
  scope (fun () ->
    let* () = checkpoint p.connection in
    F.prepare fresh p.sql;
    let* () = settled p.connection fresh in
    if unchanged () then checkpoint p.connection else Error (Data_error S.Parameter_schema_changed))
    (fun () -> native_close p.connection fresh)
(* How execution established that its parameter types are current. *)
type validation =
  | No_parameters  (* nothing a schema change could convert *)
  | Checked        (* re-prepared in this execution's snapshot *)
  | Skipped of int (* epoch unchanged since validation; snapshot not yet established *)
(* Re-prepares only when a schema change may have become visible since the
   last validation. Called inside the execution's snapshot. *)
let validate_parameter_schema p =
  let current = F.schema_epoch () in
  if Array.is_empty p.parameter_types then Ok No_parameters
  else if Option.equal Int.equal p.validated_epoch (Some current) then Ok (Skipped current)
  else
    let fresh = Option.is_none (child_transaction p.child) in
    let+ validated = stable_epoch ~fresh (fun () -> check_parameter_schema p) in
    Option.iter validated ~f:(fun epoch -> p.validated_epoch <- Some epoch);
    Checked
(* The engine snapshot may begin only at execution. After a skipped check, a
   change that became visible meanwhile (other than this statement's own) is
   checked in that same snapshot; a mismatch fails before publication and the
   snapshot owner rolls back. *)
let recheck_after_execution p = function
  | No_parameters | Checked -> Ok ()
  | Skipped epoch ->
    if F.schema_epoch () = epoch || F.prepared_changes_schema p.native then Ok ()
    else
      (* Only a cached statement lent to an explicit transaction skips there; its
         effects stay in that transaction, so the transaction must not commit. *)
      let checked = check_parameter_schema p in
      Result.iter_error checked ~f:(fun error -> Option.iter (child_transaction p.child) ~f:(fun tx ->
        poison_transaction tx error));
      checked
let execute_prepared p = without_result p (fun () ->
  match Array.findi p.bound ~f:(fun _ bound -> not bound) with
  | Some (i, _) -> Error (Data_error (S.Unbound_parameter (i + 1)))
  | None ->
    let execute () =
      let* validation = validate_parameter_schema p in
      let* () = checkpoint p.connection in
      F.execute_prepared p.native;
      let* () = settled p.connection p.native in
      recheck_after_execution p validation in
    let publish () =
      let+ () = checkpoint p.connection in
      let r = { prepared = p; closed = false } in
      p.result <- Some r;
      reserve_result p.child;
      r in
    let close () = native_close_result p.connection p.native in
    match capture_all (fun () -> let* () = with_child_snapshot p.child execute in publish ()) with
    | Ok (Ok _ as published) -> published
    | Ok (Error _ as error) -> close (); error
    | Error raised -> Exn.protect ~finally:close ~f:(fun () -> reraise raised))
let close_result r =
  if r.closed || child_is_closed r.prepared.child then Ok ()
  else child_operation ~cleanup:true r.prepared.child ~allow_result:true (fun () ->
    if not r.closed then destroy_result r;
    Ok ())
let scoped prepare ~f =
  let* p = prepare () in
  scope (fun () -> f p) (fun () -> force_close_child p.child)
let with_prepared c sql ~f = scoped (fun () -> prepare c sql) ~f
let with_prepared_transaction tx sql ~f = scoped (fun () -> prepare_transaction tx sql) ~f

let chunk_length = Borrowed_chunk.length
let column = Borrowed_chunk.column
(* The loop keeps explicit matches: each borrowed chunk is stack-allocated and
   must not be captured by a heap closure. *)
let result_checkpoint r = checkpoint r.prepared.connection
let fold_internal r validate ~init ~f =
  let c = r.prepared.connection and native = r.prepared.native in
  let finish acc = Result.map (checkpoint c) ~f:(fun () -> acc) in
  child_operation r.prepared.child ~allow_result:true (fun () ->
    if r.closed then Error Closed
    else scope (fun () ->
      let rec loop acc =
        match checkpoint c with
        | Error e -> Error e
        | Ok () ->
          match F.next_chunk native with
          | F.Exhausted -> finish acc
          | F.Fetch_failed -> Result.bind (status native) ~f:(fun () -> Error (Native_error "DuckDB fetch failed"))
          | F.Chunk ->
            match checkpoint c with
            | Error e -> Error e
            | Ok () ->
              let chunk = stack_ { Borrowed_chunk.native } in
              if chunk_length chunk = 0 then loop acc
              else match f chunk acc with
                | Error e -> Error e
                | Ok (Stop acc) -> finish acc
                | Ok (Continue acc) -> loop acc in
      let* () = checkpoint c in
      let* () = validate native in
      loop init)
      (fun () -> destroy_result r))
let fold_chunks r ~init ~f = fold_internal r (fun _ -> Ok ()) ~init ~f
let fold_validated r ~validate ~init ~f =
  fold_internal r (fun native -> validate (F.prepared_column_types native)) ~init ~f
let select_schema p = without_result p (fun () ->
  if F.prepared_kind p.native <> F.Statement_kind.select || not (Array.is_empty p.bound) then
    Error Unsupported_statement
  else
    let types = F.prepared_column_types p.native in
    let+ () = checkpoint p.connection in
    types)

let child p = p.child
let parameter_types p = p.parameter_types
let column_types p = child_operation p.child ~allow_result:true (fun () ->
  let types = F.prepared_column_types p.native in
  let+ () = checkpoint p.connection in
  types)
