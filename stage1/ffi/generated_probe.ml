open! Base
module F = Generated_bindings.Bindings (Generated_functions)
module Cleanup = Generated_bindings.Cleanup (Generated_cleanup_functions)

let query_int64 sql =
  if String.contains sql '\000' then Error Probe_error.Embedded_nul
  else
    (* Both malloc-backed owners exist before native work or response handoff. *)
    let storage = Ctypes.CArray.of_string sql in
    let slot = Ctypes.CArray.make (Ctypes.ptr Ctypes.void) ~initial:Ctypes.null 1 in
    let sql_pointer = Ctypes.CArray.start storage in
    let slot_pointer = Ctypes.CArray.start slot in
    Exn.protect
      ~f:(fun () ->
        (* In this pinned runtime async Break bypasses ordinary handlers up to
           with_async_exns. Deliver it inside protect so finally still runs. *)
        Stdlib.Sys.with_async_exns (fun () ->
          F.query_into sql_pointer slot_pointer;
          let response = Ctypes.(!@) slot_pointer in
          match F.status response with
          | 0 -> Ok (Array.init (F.count response) ~f:(F.value response))
          | 1 -> Error (Probe_error.Open_failed (F.message response))
          | 2 -> Error Probe_error.Connect_failed
          | 3 -> Error (Probe_error.Query_failed (F.message response))
          | 4 -> Error Probe_error.Unsupported_schema
          | 5 -> Error Probe_error.Allocation_failed
          | _ -> failwith "unexpected native status"))
      ~finally:(fun () ->
        Cleanup.destroy_slot slot_pointer;
        (* Keep both backing allocations live on success AND exceptional exit. *)
        ignore (Sys.opaque_identity storage : char Ctypes.CArray.t);
        ignore (Sys.opaque_identity slot : unit Ctypes.ptr Ctypes.CArray.t))

let slow = F.slow
