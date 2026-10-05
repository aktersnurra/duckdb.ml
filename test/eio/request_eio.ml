(* Typed requests through the Eio adapter's generic instance. *)
open! Base
module E = Duckdb_eio
module D = Duckdb
module R = D.Request
module Q = E.Request
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let request_ok = function
  | Ok x -> x
  | Error (Q.Request { context; _ }) ->
    failwith ("unexpected request error in " ^ match context with D.Error.Query sql -> sql | _ -> "non-query context")
  | Error (Q.Adapter _) -> failwith "unexpected adapter error"
let require name condition = if not condition then failwith name
let notes = D.Table.(declare "notes" Columns.[ "value", int64; "note", nullable string ] ~row:(fun v n -> (v, n)))
let create = R.exec D.Fields.[] "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)"
let values = R.many D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT value FROM notes WHERE value >= ? ORDER BY value"
let one_note = R.one D.Fields.[int64] D.Fields.[nullable string] ~row:Fn.id "SELECT note FROM notes WHERE value = ?"
let insert = R.exec D.Fields.[int64; nullable string] "INSERT INTO notes VALUES (?, ?)"

module Count (B : R.CONNECTION) = struct let all owner = B.collect owner values D.Args.[0L] end
module Eio_count = Count (Q.Generic)

let () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let pool = ok (E.create ~sw (ok (E.limits ~connections:1 ~queue_capacity:2)) (ok (D.Config.create Memory))) in
      request_ok (Q.exec pool create D.Args.[]);
      request_ok (Q.ingest pool notes [ [D.Args.[1L; Some "a"]; D.Args.[2L; None]] ] ~flush:false);
      require "collect" (List.equal Int64.equal (request_ok (Q.collect pool values D.Args.[0L])) [1L; 2L]);
      require "generic instance" (List.equal Int64.equal (request_ok (Eio_count.all pool)) [1L; 2L]);
      require "find" (Option.equal String.equal (request_ok (Q.find pool one_note D.Args.[1L])) (Some "a"));
      require "fold" (request_ok (Q.fold pool values D.Args.[0L] ~init:0 ~f:(fun _ n ->
        require "callback cannot reenter" (match Q.exec pool insert D.Args.[3L; None] with
          | Error (Q.Adapter E.Reentrant_call) -> true | _ -> false);
        Ok (D.Continue (n + 1)))) = 2);
      require "Row_count is a request error" (match Q.find pool one_note D.Args.[42L] with
        | Error (Q.Request { cause = D.Error.Row_count { actual = `Zero; _ }; _ }) -> true | _ -> false);
      require "transaction rolls back on request error" (Result.is_error (Q.with_transaction pool ~f:(fun tx ->
        Result.bind (R.Session.exec tx insert D.Args.[3L; None]) ~f:(fun () -> R.Session.find tx one_note D.Args.[99L]) [@nontail])));
      require "rollback left no row" (List.length (request_ok (Q.collect pool values D.Args.[0L])) = 2);
      (* A typed request waiting for the only connection is cancelled with its fiber. *)
      let entered = Stdlib.Atomic.make false and release = Stdlib.Atomic.make false in
      Eio.Fiber.both
        (fun () ->
          ok (E.transaction pool ~f:(fun _ ->
            Stdlib.Atomic.set entered true;
            while not (Stdlib.Atomic.get release) do Unix.sleepf 0.001 done;
            Ok ())))
        (fun () ->
          while not (Stdlib.Atomic.get entered) do Eio_unix.sleep 0.001 done;
          let outcome = Eio.Fiber.first
            (fun () -> ignore (Q.find pool one_note D.Args.[1L]); `Finished)
            (fun () -> Eio.Fiber.yield (); `Abandoned) in
          require "queued typed request abandoned" (Poly.equal outcome `Abandoned);
          Stdlib.Atomic.set release true);
      ok (E.shutdown pool);
      require "resources released" (Duckdb_ffi.live_resources () = 0);
      Stdlib.print_endline "eio request: generic instance ops/errors/transaction/ingest, reentrancy, fiber cancellation=ok"))
