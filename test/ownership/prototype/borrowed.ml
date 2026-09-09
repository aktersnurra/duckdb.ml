open! Base
module F = Borrowed_ffi
(* No global field modality: extracting the owner from a local view stays local. *)
type view = { owner : F.owner }
type error = Embedded_nul | Native_error of string | Unsupported_schema | Effects_not_allowed
type access_error = Out_of_bounds of int
type 'a step = Continue of 'a | Stop of 'a
let length (view @ local) = F.length view.owner
let get (view @ local) i =
  if i < 0 || i >= length view then Error (Out_of_bounds i)
  else if F.valid view.owner i then Ok (Some (F.box (F.value view.owner i)))
  else Ok None
let copy (view @ local) =
  let rec loop i acc =
    if i < 0 then acc
    else match get view i with
      | Ok value -> loop (i - 1) (value :: acc)
      | Error _ -> assert false
  in loop (length view - 1) [] [@nontail]
exception Effect_denied
let without_escaping_effects work =
  let denied = ref false in
  let result =
    try Stdlib.Effect.Deep.try_with work ()
      { effc = fun (type a) (_ : a Stdlib.Effect.t) ->
          Some (fun (k : (a, _) Stdlib.Effect.Deep.continuation) ->
            denied := true;
            (* Deep discontinue reinstalls this handler while unwinding. *)
            Stdlib.Effect.Deep.discontinue k Effect_denied) }
    with Effect_denied -> Error Effects_not_allowed
  in
  if !denied then Error Effects_not_allowed else result
let fold sql ~init ~f =
  if String.contains sql '\000' then Error Embedded_nul
  else
    let owner = F.create () in
    Exn.protect ~finally:(fun () -> F.close owner) ~f:(fun () ->
      Stdlib.Sys.with_async_exns (fun () -> without_escaping_effects (fun () ->
        F.prepare owner sql;
        let error () =
          if F.status owner = 3 then Error Unsupported_schema
          else Error (Native_error (F.message owner))
        in
        if F.status owner <> 0 then error ()
        else
          let rec loop acc =
            match F.next owner with
            | 0 ->
              (* This local record, not a foreign pointer disguised as an array,
                 is the only capability handed to user code. *)
              let view = stack_ { owner } in
              (match f view acc with
               | Continue acc -> loop acc
               | Stop acc -> Ok acc)
            | 1 -> Ok acc
            | _ -> error ()
          in loop init)))
