open! Base
module D = Duckdb
module C = D.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u
module A1 = Stdlib.Bigarray.Array1
let ok = function Ok x -> x | Error _ -> failwith "DuckDB operation failed"
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c))
let words f = Stdlib.Gc.full_major (); let before = Stdlib.Gc.allocated_bytes () in f (); (Stdlib.Gc.allocated_bytes () -. before) /. 8.
let sql n = Printf.sprintf
  "SELECT i::BIGINT, CASE WHEN i %% 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(%d) t(i) ORDER BY i" n
let[@zero_alloc] rec sum (v @ local) i n acc = if i = n then acc else sum v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))
(* Words per row, from the difference between two sizes, so fixed costs cancel. *)
let per_row run = let small = words (run 100_000) in let large = words (run 1_000_000) in (large -. small) /. 900_000.

let () =
  connected (fun c ->
    let views n () = ignore (ok (D.Statement.with_prepared c (sql n) ~f:(fun p ->
      D.Statement.fold_chunks p ~init:0L ~f:(fun chunk acc ->
        match C.view chunk 1 D.Scalar.Int64 C.Nullable with
        | C.Rejected e -> Error e
        | C.Opened v -> Ok (D.Continue Int64.(acc + I64.to_int64 (sum v 0 (C.length v) #0L)))))) : int64) in
    let w = per_row views in
    Stdlib.Printf.printf "allocation: column views %.4f words/row\n" w;
    assert (Float.(w < 0.05));
    let collect n () = ignore (ok (D.Statement.with_prepared c (sql n) ~f:(fun p ->
      D.Bulk.collect p ~column:1 (D.Bulk.Int64 D.Scalar.Int64) C.Nullable)) : (int64, _, _) D.Bulk.t) in
    let w = per_row collect in
    Stdlib.Printf.printf "allocation: collect %.4f words/row\n" w;
    assert (Float.(w < 0.05));
    let continue_unit = Ok (D.Continue ()) in
    let rows = D.Request.many D.Fields.[] D.Fields.[int64; nullable int64] ~row:(fun a b -> (a, b)) in
    let typed n () = ok (D.Request.Session.fold c (rows (sql n)) D.Args.[] ~init:() ~f:(fun _ () -> continue_unit)) in
    let w = per_row typed in
    Stdlib.Printf.printf "allocation: typed rows %.2f words/row\n" w;
    assert (Float.(w <= 12.));
    ok (D.execute c "CREATE TABLE ingest(a BIGINT, b BIGINT)");
    let ingest = D.Table.(declare "ingest" Columns.["a", int64; "b", nullable int64] ~row:(fun a b -> (a, b))) in
    (* [columnar n] builds its input before returning the measured thunk, so
       [words] counts only the append. *)
    let columnar n =
      let a = A1.init Bigarray.int64 Bigarray.c_layout n Int64.of_int in
      let m = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i % 10 = 0 then 0 else 1) in
      fun () -> ok (D.Table.with_appender c ingest ~f:(fun ap ->
        D.Table.append_columns ap D.Bulk.Columns.[Int64 (D.Scalar.Int64, a); Nullable (Int64 (D.Scalar.Int64, a), m)])) in
    let w = per_row columnar in
    Stdlib.Printf.printf "allocation: columnar ingest %.4f words/row\n" w;
    assert (Float.(w < 0.05)));
  Stdlib.print_endline "allocation: views, collect and columnar ingest allocate nothing per row; typed rows <= 12 words=ok"
