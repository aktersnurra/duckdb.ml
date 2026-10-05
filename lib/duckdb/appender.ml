open! Base
open Resource
open Syntax
module F = Duckdb_ffi
module S = Scalar
type cell = Cell : 'a S.field * 'a -> cell
type appender = { native : F.appender; child : child; tx : transaction;
                  mutable types : int array; mutable nullable : bool array; mutable failure : error option }
let status native = native_status (F.appender_status native) ~message:(fun () -> F.appender_message native)
let connection a = transaction_connection a.tx
(* The first failure sticks to the appender; every failure poisons the transaction. *)
let poison a e =
  let first = Option.value a.failure ~default:e in
  a.failure <- Some first;
  poison_transaction a.tx e;
  Error first
let or_poison a = function Ok () -> Ok () | Error e -> poison a e
let interrupted = Native_error "Appender operation or scope interrupted; transaction must roll back"
let destroy c native =
  admit_cleanup c;
  (* Resource retries a cleanup interrupted by one Break. The first attempt
     may already have finished the native shell; never read status after that. *)
  if F.appender_is_closed native then Ok () else
  Exn.protect ~finally:(fun () -> F.finish_appender_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.close_appender native false; status native))

(* The parent owns this cleanup even if the caller drops every alias. *)
let register c tx native ~types ~nullable =
  let self = ref None in
  let child = register_child c (Some tx) ~cleanup:(fun () ->
    let e = Native_error "Unclosed appender discarded at scope exit" in
    (match !self with None -> poison_transaction tx e | Some a -> ignore (poison a e));
    Exn.protect ~finally:(fun () -> Option.iter !self ~f:(fun a -> release_result a.child))
      ~f:(fun () -> ignore (destroy c native))) in
  let a = { native; child; tx; types; nullable; failure = None } in
  self := Some a;
  reserve_result child;
  a
let open_appender tx ?(schema = "main") table =
  let* () = reject_nul schema in
  let* () = reject_nul table in
  if String.is_empty schema || String.is_empty table then Error (Invalid_configuration "empty appender identifier")
  else
    let c = transaction_connection tx in
    with_admission c (Some tx) (fun () ->
      let native = F.appender_owner (native_connection c) in
      match acquiring ~release:(fun () -> ignore (destroy c native)) (fun () ->
        F.create_appender native schema table;
        let* () = status native in
        let* () = checkpoint c in
        let types = F.appender_types native and nullable = F.appender_nullable native in
        let+ () = checkpoint c in
        register c tx native ~types ~nullable) with
      | Ok _ as opened -> opened
      | Error e as error -> poison_transaction tx e; error
      | exception exn ->
        let backtrace = Stdlib.Printexc.get_raw_backtrace () in
        poison_transaction tx interrupted;
        Stdlib.Printexc.raise_with_backtrace exn backtrace)

let encode : type a. a S.t -> a option -> F.append_cell = fun typ value ->
  let id = S.native_id typ in
  match value with
  | None -> id, true, 0L, 0., ""
  | Some value ->
    match S.repr typ with
    | S.Integer { encode; _ } -> id, false, encode value, 0., ""
    | S.Floating { encode; _ } -> id, false, 0L, encode value, ""
    | S.Bytes -> id, false, 0L, 0., value
let validate_cell a row column (Cell (field, value)) =
  let apply : type b. b S.t -> b option -> (F.append_cell, error) result = fun typ value ->
    let actual = a.types.(column) in
    if actual <> S.native_id typ then
      Error (Data_error (S.Type_mismatch { index = column; expected = S.name typ; actual }))
    else if Option.is_none value && not a.nullable.(column) then Error (Data_error (S.Null { column; row }))
    else Ok (encode typ value) in
  match field with S.Required typ -> apply typ (Some value) | S.Nullable typ -> apply typ value
let validate_row a row cells =
  let expected = Array.length a.types and actual = List.length cells in
  if actual <> expected then Error (Data_error (S.Column_count { expected; actual }))
  else
    let+ cells = Result.all (List.mapi cells ~f:(validate_cell a row)) in
    Array.of_list cells

let operation a f = child_operation a.child ~allow_result:true (fun () ->
  match a.failure with
  | Some e -> Error e
  | None ->
    match Stdlib.Sys.with_async_exns f with
    | result -> or_poison a (let* () = result in checkpoint (connection a))
    | exception exn -> ignore (poison a interrupted); raise exn)
let append_rows a rows = operation a (fun () ->
  let* rows = Result.all (List.mapi rows ~f:(validate_row a)) in
  Exn.protect ~finally:(fun () -> F.clear_appender_input a.native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      let* () = checkpoint (connection a) in
      F.append_rows a.native (Array.of_list rows);
      status a.native)))
let flush_appender a = operation a (fun () -> F.flush_appender a.native; status a.native)
let close_appender a =
  if child_is_closed a.child then Ok ()
  else child_operation ~cleanup:true a.child ~allow_result:true (fun () ->
    let c = connection a in
    Exn.protect ~finally:(fun () -> release_result a.child; unregister_child a.child) ~f:(fun () ->
      ignore (or_poison a (checkpoint c));
      (* Flush is user work. Cancellation racing its return must join
         before the distinct clear/destroy cleanup, even after success. *)
      let flush () = match a.failure with
        | Some e -> Error e
        | None -> F.flush_appender a.native; let* () = status a.native in checkpoint c in
      let destroyed = ref (Ok ()) in
      match Exn.protect ~finally:(fun () -> destroyed := destroy c a.native)
              ~f:(fun () -> Stdlib.Sys.with_async_exns flush) with
      | flushed ->
        (match a.failure with
         | Some e -> Error e
         | None -> or_poison a (let* () = flushed in let* () = !destroyed in checkpoint c))
      | exception exn -> ignore (poison a interrupted); raise exn))
let with_appender_transaction tx ?schema table ~f =
  let* a = open_appender tx ?schema table in
  let work () =
    match f a with
    | Error e -> ignore (poison a e); Error e
    | Ok x -> let+ () = close_appender a in x in
  (* Scope can turn a caught effect denial into an error after work returned.
     Even a manually closed child must poison settlement on that outcome.
     Capture before crossing the runtime primitive: otherwise it replaces the
     source callback backtrace, even though Resource.scope retained it. *)
  match capture_all (fun () -> scope work (fun () -> force_close_child a.child)) with
  | Ok (Ok _ as ok) -> ok
  | Ok (Error e as error) -> poison_transaction tx e; error
  | Error raised -> poison_transaction tx interrupted; reraise raised
let with_appender c ?schema table ~f =
  with_transaction c ~f:(fun tx -> with_appender_transaction tx ?schema table ~f)

let child a = a.child
let types a = a.types
let select_columns a ~names ~indices = operation a (fun () ->
  F.appender_select_columns a.native names indices;
  let+ () = status a.native in
  a.types <- F.appender_types a.native;
  a.nullable <- F.appender_nullable a.native)
