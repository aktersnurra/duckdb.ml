open! Base
open Resource
open Failure
open Syntax
module F = Duckdb_ffi
module S = Scalar
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
let interrupted = Native "Appender operation or scope interrupted; transaction must roll back"
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
    let e = Native "Unclosed appender discarded at scope exit" in
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

let operation a f = child_operation a.child ~allow_result:true (fun () ->
  match a.failure with
  | Some e -> Error e
  | None ->
    match Stdlib.Sys.with_async_exns f with
    | result -> or_poison a (let* () = result in checkpoint (connection a))
    | exception exn -> ignore (poison a interrupted); raise exn)
let native a = a.native
let nullable a column = a.nullable.(column)
let append_staged a ~null =
  Exn.protect ~finally:(fun () -> F.clear_stage a.native) ~f:(fun () ->
    operation a (fun () ->
      match null with
      | Some (column, row) -> Error (Null { column; row })
      | None ->
        let* () = checkpoint (connection a) in
        F.append_staged a.native;
        status a.native))
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

let child a = a.child
let types a = a.types
let select_columns a ~names ~indices = operation a (fun () ->
  F.appender_select_columns a.native names indices;
  let+ () = status a.native in
  a.types <- F.appender_types a.native;
  a.nullable <- F.appender_nullable a.native)
