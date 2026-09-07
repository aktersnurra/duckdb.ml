open! Base
module F = Generated_bindings.Bindings (Generated_functions)

let query_int64 sql =
  if String.contains sql '\000' then Error Probe_error.Embedded_nul
  else
    (* CArray owns malloc-backed storage, not a pointer into the OCaml string. *)
    let storage = Ctypes.CArray.of_string sql in
    let response = F.query (Ctypes.CArray.start storage) in
    (* Keep the owner live across the unlocked call, including full GC. *)
    ignore (Sys.opaque_identity storage : char Ctypes.CArray.t);
    Exn.protect
      ~f:(fun () ->
        match F.status response with
        | 0 -> Ok (Array.init (F.count response) ~f:(F.value response))
        | 1 -> Error (Probe_error.Open_failed (F.message response))
        | 2 -> Error Probe_error.Connect_failed
        | 3 -> Error (Probe_error.Query_failed (F.message response))
        | 4 -> Error Probe_error.Unsupported_schema
        | 5 -> Error Probe_error.Allocation_failed
        | _ -> failwith "unexpected native status")
      ~finally:(fun () -> F.destroy response)

let slow = F.slow
