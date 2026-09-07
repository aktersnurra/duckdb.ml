type _ Effect.t += Pause : unit Effect.t
let saved : (unit, (unit, Borrowed.error) result) Effect.Deep.continuation option ref = ref None
let run () = Effect.Deep.try_with
  (fun () -> Borrowed.fold "select 42::bigint" ~init:()
    ~f:(fun view () -> Effect.perform Pause; ignore (Borrowed.length view); Borrowed.Stop ())) ()
  { effc = fun (type a) (effect : a Effect.t) -> match effect with
    | Pause -> Some (fun (k : (a, _) Effect.Deep.continuation) -> saved := Some k; Ok ())
    | _ -> None }
