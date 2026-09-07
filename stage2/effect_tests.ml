open! Base
module B = Borrowed
module E = Stdlib.Effect
module D = E.Deep
type _ E.t += Pause : unit E.t
let outer_calls = ref 0
let outer f = D.try_with f () { effc = fun (type a) (effect : a E.t) ->
  match effect with
  | Pause -> Some (fun (k : (a, _) D.continuation) ->
      Int.incr outer_calls; D.continue k ())
  | _ -> None }
let expect_denied f =
  outer_calls := 0;
  let result = outer (fun () -> B.fold "select 42::bigint" ~init:() ~f) in
  (* Initially red: Sys.with_async_exns raises Effect.Unhandled rather than
     reporting the structured error; without it an outer handler could suspend. *)
  assert (!outer_calls = 0);
  (match result with Error B.Effects_not_allowed -> () | _ -> assert false);
  assert (Borrowed_ffi.live_resources () = 0)
let () =
  expect_denied (fun view () -> E.perform Pause; ignore (B.length view); B.Stop ());
  expect_denied (fun view () ->
    (try E.perform Pause with _ -> ());
    (try E.perform Pause with _ -> ());
    assert (B.length view = 1); B.Stop ());
  let finalizers = ref 0 in
  expect_denied (fun view () ->
    Exn.protect ~f:(fun () -> ignore (B.length view);
      try E.perform Pause with _ -> ())
      ~finally:(fun () -> Int.incr finalizers; E.perform Pause);
    B.Stop ());
  assert (!finalizers = 1);
  (* Preserve callback-produced wrapper exceptions rather than masking them. *)
  (try ignore (outer (fun () -> B.fold "select 42::bigint" ~init:()
     ~f:(fun _ () -> Exn.protect ~f:(fun () -> E.perform Pause)
       ~finally:(fun () -> E.perform Pause); B.Stop ()))); assert false
   with Exn.Finally (_, _) -> ());
  assert (!outer_calls = 0);
  assert (Borrowed_ffi.live_resources () = 0);
  (* An inner handler without borrowed captures may handle its own effects. *)
  outer_calls := 0;
  let result = outer (fun () -> B.fold "select 42::bigint" ~init:0 ~f:(fun view _ ->
    let n = D.try_with (fun () -> E.perform Pause; 7) ()
      { effc = fun (type a) (effect : a E.t) -> match effect with
        | Pause -> Some (fun (k : (a, _) D.continuation) -> D.continue k ())
        | _ -> None } in
    B.Stop (n + B.length view))) in
  assert (Result.equal Int.equal Poly.equal result (Ok 8));
  assert (!outer_calls = 0);
  assert (Borrowed_ffi.live_resources () = 0);
  Stdlib.print_endline "effects: outer non-delivery/catch-reperform/cleanup/nested-handler=ok"
