(* Typed requests through the Async adapter: the generic instance and the
   cancellable submit forms. *)
open! Core
open! Async
module A = Duckdb_async
module D = Duckdb
module R = D.Request
module Q = A.Request
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let request_ok = function
  | Ok x -> x
  | Error (Q.Request { context; _ }) ->
    failwith ("unexpected request error in " ^ match context with D.Error.Query sql -> sql | _ -> "non-query context")
  | Error (Q.Adapter _) -> failwith "unexpected adapter failure"
let require name condition = if not condition then failwith name
let notes = D.Table.(declare "notes" Columns.[ "value", int64; "note", nullable string ] ~row:(fun v n -> (v, n)))
let create = R.exec D.Fields.[] "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)"
let values = R.many D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT value FROM notes WHERE value >= ? ORDER BY value"
let one_note = R.one D.Fields.[int64] D.Fields.[nullable string] ~row:Fn.id "SELECT note FROM notes WHERE value = ?"
let maybe = R.zero_or_one D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT value FROM notes WHERE value = ?"
let insert = R.exec D.Fields.[int64; nullable string] "INSERT INTO notes VALUES (?, ?)"

(* The generic instance fits code written over any backend. *)
module Count (B : R.CONNECTION) = struct let all owner = B.collect owner values D.Args.[0L] end
module Async_count = Count (Q.Generic)

let main () =
  A.create (ok (A.Limits.create ~connections:1 ~queue_capacity:2)) (ok (D.Config.create Memory)) >>= fun pool ->
  let pool = ok pool in
  Q.exec pool create D.Args.[] >>| request_ok >>= fun () ->
  Q.ingest pool notes [ [D.Args.[1L; Some "a"]; D.Args.[2L; None]] ] ~flush:true >>| request_ok >>= fun () ->
  Q.collect pool values D.Args.[0L] >>| request_ok >>= fun all ->
  require "collect" (List.equal Int64.equal all [1L; 2L]);
  Async_count.all pool >>| request_ok >>= fun generic ->
  require "generic instance" (List.equal Int64.equal generic all);
  Q.find pool one_note D.Args.[1L] >>| request_ok >>= fun note ->
  require "find" (Option.equal String.equal note (Some "a"));
  Q.find_opt pool maybe D.Args.[9L] >>| request_ok >>= fun missing ->
  require "find_opt" (Option.is_none missing);
  Q.fold pool values D.Args.[0L] ~init:0 ~f:(fun _ n ->
    require "callback cannot submit" (match Q.submit_exec pool insert D.Args.[3L; None] with
      | Error A.Reentrant_call -> true | _ -> false);
    Ok (D.Continue (n + 1))) >>| request_ok >>= fun n ->
  require "fold" (n = 2);
  Q.find pool one_note D.Args.[42L] >>= fun absent ->
  require "Row_count is a request error" (match absent with
    | Error (Q.Request { cause = D.Error.Row_count { actual = `Zero; _ }; _ }) -> true | _ -> false);
  Q.with_transaction pool ~f:(fun tx ->
    Result.bind (R.Session.exec tx insert D.Args.[3L; Some "c"]) ~f:(fun () ->
      R.Session.find tx one_note D.Args.[99L]) [@nontail]) >>= fun rolled ->
  require "transaction rolls back on request error" (Result.is_error rolled);
  Q.collect pool values D.Args.[0L] >>| request_ok >>= fun remaining ->
  require "rollback left no row" (List.length remaining = 2);
  (* Cancellable form: a queued typed request is removed by the existing cancel. *)
  let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
  let busy = ok (A.transaction pool ~f:(fun _ ->
    Stdlib.Atomic.set entered true;
    while not (Stdlib.Atomic.get release) do Core_unix.nanosleep 0.001 |> ignore done;
    Ok ())) in
  let rec until_entered () =
    if Stdlib.Atomic.get entered then return () else after (Time_float.Span.of_ms 1.) >>= until_entered in
  until_entered () >>= fun () ->
  let queued = ok (Q.submit_find pool one_note D.Args.[1L]) in
  require "cancel queued typed request" (match A.cancel queued with Ok A.Requested -> true | _ -> false);
  Stdlib.Atomic.set release true;
  ok (A.completion queued) >>= fun cancelled ->
  require "queued typed request cancelled" (match cancelled with Error (A.Expected A.Cancelled) -> true | _ -> false);
  ok (A.completion busy) >>| ok >>= fun () ->
  ok (A.shutdown pool) >>| ok >>| fun () ->
  require "resources released" (Duckdb_ffi.live_resources () = 0);
  print_endline "async request: generic instance ops/errors/transaction/ingest, reentrancy, cancellable submit=ok"

let () = Thread_safe.block_on_async_exn main
