let owned () = Borrowed.fold "select 42::bigint" ~init:[]
  ~f:(fun view _ -> Borrowed.Stop (Borrowed.copy view))
let aliases () = Borrowed.fold "select 42::bigint" ~init:0
  ~f:(fun view _ -> let alias = view in
    Borrowed.Stop (Borrowed.length view + Borrowed.length alias))
let transfer (copy : int64 option list) = Stdlib.Domain.join
  (Stdlib.Domain.Safe.spawn (fun () -> List.length copy))
let saved = ref None
let store_copy () = Borrowed.fold "select 42::bigint" ~init:()
  ~f:(fun view () -> saved := Some (Borrowed.copy view); Borrowed.Stop ())
let capture_copy () = Borrowed.fold "select 42::bigint" ~init:(fun () -> 0)
  ~f:(fun view _ -> let copy = Borrowed.copy view in
    Borrowed.Stop (fun () -> List.length copy))
let close_own_handle () = let owner = Borrowed_ffi.create () in
  Borrowed_ffi.close owner; Borrowed_ffi.close owner
