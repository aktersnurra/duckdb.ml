open! Base
module D = Duckdb
module A1 = Stdlib.Bigarray.Array1
let ok = function Ok x -> x | Error (e : D.Error.t) -> failwith (match e.cause with Native s -> s | _ -> "error")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let sql = "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::DOUBLE END, i::INTEGER % 3 = 0, \
           CASE WHEN i % 7 = 0 THEN NULL ELSE 's' || i END FROM range(5000) t(i) ORDER BY i"
let collect c column kind nulls = ok (D.Statement.with_prepared c sql ~f:(fun p -> D.Bulk.collect p ~column kind nulls))

(* Non-null BIGINT: every value, no mask; nullable DOUBLE: 0 at NULL rows. *)
let () =
  connected (fun c ->
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect c 0 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null in
    assert (A1.dim data = 5000);
    for i = 0 to 4999 do assert (Int64.equal data.{i} (Int64.of_int i)) done;
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = collect c 1 D.Bulk.Float64 D.Statement.Column.Nullable in
    assert (A1.dim data = 5000 && A1.dim mask = 5000);
    for i = 0 to 4999 do
      if i % 10 = 0 then (assert (mask.{i} = 0); assert (Float.equal data.{i} 0.))
      else (assert (mask.{i} = 1); assert (Float.equal data.{i} (Float.of_int i)))
    done;
    let { D.Bulk.data; _ } = collect c 2 D.Bulk.Bool D.Statement.Column.Non_null in
    assert (A1.dim data = 5000);
    for i = 0 to 4999 do assert (data.{i} = if i % 3 = 0 then 1 else 0) done);
  Stdlib.print_endline "bulk: collect int64, nullable float64 and bool across chunks=ok"

(* Strings, and a NULL in a non-null collect reported with its absolute row. *)
let () =
  connected (fun c ->
    let (D.Bulk.Strings_opt values) = ok (D.Statement.with_prepared c sql ~f:(fun p ->
      D.Bulk.collect_strings p ~column:3 D.Scalar.String D.Statement.Column.Nullable)) in
    assert (Array.length values = 5000);
    for i = 0 to 4999 do
      assert (Option.equal String.equal values.(i) (if i % 7 = 0 then None else Some ("s" ^ Int.to_string i)))
    done;
    let (D.Bulk.Strings values) = ok (D.Statement.with_prepared c "SELECT 's' || i FROM range(5000) t(i) ORDER BY i" ~f:(fun p ->
      D.Bulk.collect_strings p ~column:0 D.Scalar.String D.Statement.Column.Non_null)) in
    assert (Array.length values = 5000);
    assert (String.equal values.(4321) "s4321");
    let (D.Bulk.Strings blobs) = ok (D.Statement.with_prepared c "SELECT ('b' || i)::BLOB FROM range(5000) t(i) ORDER BY i" ~f:(fun p ->
      D.Bulk.collect_strings p ~column:0 D.Scalar.Blob D.Statement.Column.Non_null)) in
    assert (Array.length blobs = 5000 && String.equal blobs.(4999) "b4999");
    (match D.Statement.with_prepared c sql ~f:(fun p ->
      D.Bulk.collect p ~column:1 D.Bulk.Float64 D.Statement.Column.Non_null) with
     | Error { cause = Null { column = 1; row = 0 }; _ } -> ()
     | _ -> failwith "expected Null at row 0");
    (* A NULL past the first chunk: its row counts the rows of earlier chunks. *)
    let late = "SELECT CASE WHEN i = 3000 THEN NULL ELSE i::DOUBLE END FROM range(5000) t(i) ORDER BY i" in
    (match D.Statement.with_prepared c late ~f:(fun p ->
      D.Bulk.collect p ~column:0 D.Bulk.Float64 D.Statement.Column.Non_null) with
     | Error { cause = Null { column = 0; row = 3000 }; _ } -> ()
     | _ -> failwith "expected Null at row 3000");
    match D.Statement.with_prepared c late ~f:(fun p ->
      D.Bulk.collect_strings p ~column:0 D.Scalar.String D.Statement.Column.Non_null) with
    | Error { cause = Type_mismatch _; _ } -> ()
    | _ -> failwith "expected Type_mismatch");
  Stdlib.print_endline "bulk: strings and absolute NULL rows=ok"

(* Empty results collect to empty arrays. *)
let () =
  connected (fun c ->
    let { D.Bulk.data; _ } = ok (D.Statement.with_prepared c "SELECT 1::BIGINT WHERE false" ~f:(fun p ->
      D.Bulk.collect p ~column:0 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null)) in
    assert (A1.dim data = 0);
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = ok (D.Statement.with_prepared c "SELECT 1::DOUBLE WHERE false" ~f:(fun p ->
      D.Bulk.collect p ~column:0 D.Bulk.Float64 D.Statement.Column.Nullable)) in
    assert (A1.dim data = 0 && A1.dim mask = 0);
    match ok (D.Statement.with_prepared c "SELECT 'x' WHERE false" ~f:(fun p ->
      D.Bulk.collect_strings p ~column:0 D.Scalar.String D.Statement.Column.Nullable)) with
    | D.Bulk.Strings_opt values -> assert (Array.length values = 0));
  Stdlib.print_endline "bulk: empty result=ok"

(* A destination shorter than the chunk, or a position past its room, raises. *)
let () =
  connected (fun c ->
    let raised = ok (D.Statement.with_prepared c "SELECT i::BIGINT, i::DOUBLE FROM range(10) t(i)" ~f:(fun p ->
      D.Statement.fold_chunks p ~init:0 ~f:(fun chunk raised ->
        let raises f = match f () with () -> false | exception Invalid_argument _ -> true in
        match D.Statement.Column.view chunk 0 D.Scalar.Int64 D.Statement.Column.Nullable with
        | D.Statement.Column.Rejected e -> Error e
        | D.Statement.Column.Opened v ->
          let n = D.Statement.Column.length v in
          let kind = D.Bulk.Int64 D.Scalar.Int64 in
          let short = A1.create Stdlib.Bigarray.int64 Stdlib.Bigarray.c_layout (n - 1) in
          let exact = A1.create Stdlib.Bigarray.int64 Stdlib.Bigarray.c_layout n in
          let mask = A1.create Stdlib.Bigarray.int8_unsigned Stdlib.Bigarray.c_layout (n - 1) in
          let count = List.count ~f:Fn.id [
            raises (fun () -> D.Bulk.blit v kind ~into:short ~pos:0);
            raises (fun () -> D.Bulk.blit v kind ~into:exact ~pos:1);
            raises (fun () -> D.Bulk.blit v kind ~into:exact ~pos:(-1));
            raises (fun () -> D.Bulk.blit_validity v ~into:mask ~pos:0) ] in
          D.Bulk.blit v kind ~into:exact ~pos:0;
          for i = 0 to n - 1 do assert (Int64.equal exact.{i} (Int64.of_int i)) done;
          Ok (Continue (raised + count))))) in
    assert (raised = 4));
  Stdlib.print_endline "bulk: blit into a too-short destination raises Invalid_argument=ok"

(* Column index and exact type are checked before any chunk, so empty results
   are rejected too; non-empty collects reject the same way. *)
let () =
  connected (fun c ->
    let empty = "SELECT 1::BIGINT WHERE false" and full = "SELECT i::BIGINT FROM range(5000) t(i)" in
    let collect_in sql ~column kind = D.Statement.with_prepared c sql ~f:(fun p ->
      D.Bulk.collect p ~column kind D.Statement.Column.Nullable) in
    let is_index = function
      | Error { D.Error.cause = Index { index = 5; length = 1 }; _ } -> true | _ -> false in
    let is_mismatch expected = function
      | Error { D.Error.cause = Type_mismatch { index = 0; expected = e; actual = "BIGINT" }; _ } -> String.equal e expected
      | _ -> false in
    List.iter [ empty; full ] ~f:(fun sql ->
      assert (is_index (collect_in sql ~column:5 (D.Bulk.Int64 D.Scalar.Int64)));
      assert (is_mismatch "DOUBLE" (collect_in sql ~column:0 D.Bulk.Float64));
      assert (is_mismatch "INTEGER" (collect_in sql ~column:0 (D.Bulk.Int32 D.Scalar.Int32)));
      assert (is_mismatch "TIMESTAMPTZ" (collect_in sql ~column:0 (D.Bulk.Int64 D.Scalar.Timestamp_tz)));
      let strings_in ~column = D.Statement.with_prepared c sql ~f:(fun p ->
        D.Bulk.collect_strings p ~column D.Scalar.String D.Statement.Column.Non_null) in
      (match strings_in ~column:5 with
       | Error { cause = Index { index = 5; length = 1 }; _ } -> () | _ -> failwith "expected Index");
      match strings_in ~column:0 with
      | Error { cause = Type_mismatch { index = 0; expected = "VARCHAR"; actual = "BIGINT" }; _ } -> ()
      | _ -> failwith "expected Type_mismatch"));
  Stdlib.print_endline "bulk: index and type rejected before folding, empty or not=ok"

(* Every kind, across chunk boundaries; NULL rows hold 0 with mask 0. *)
let () =
  connected (fun c ->
    let sql = "SELECT i::INTEGER, i::SMALLINT, (i % 100)::TINYINT, i::FLOAT, DATE '1970-01-01' + i::INTEGER, \
               to_timestamp(i), CASE WHEN i % 9 = 0 THEN NULL ELSE i::SMALLINT END, \
               CASE WHEN i % 11 = 0 THEN NULL ELSE i::INTEGER END, \
               CASE WHEN i % 4 = 0 THEN NULL ELSE i % 2 = 1 END FROM range(5000) t(i) ORDER BY i" in
    let collect column kind nulls = ok (D.Statement.with_prepared c sql ~f:(fun p -> D.Bulk.collect p ~column kind nulls)) in
    let nn = D.Statement.Column.Non_null and nullable = D.Statement.Column.Nullable in
    let check_all dim f = assert (dim = 5000); for i = 0 to 4999 do assert (f i) done in
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 0 (D.Bulk.Int32 D.Scalar.Int32) nn in
    check_all (A1.dim data) (fun i -> Int32.equal data.{i} (Int32.of_int_exn i));
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 1 D.Bulk.Int16 nn in
    check_all (A1.dim data) (fun i -> data.{i} = i);
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 2 D.Bulk.Int8 nn in
    check_all (A1.dim data) (fun i -> data.{i} = i % 100);
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 3 D.Bulk.Float32 nn in
    check_all (A1.dim data) (fun i -> Float.equal data.{i} (Float.of_int i));
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 4 (D.Bulk.Int32 D.Scalar.Date) nn in
    check_all (A1.dim data) (fun i -> Int32.equal data.{i} (Int32.of_int_exn i));
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect 5 (D.Bulk.Int64 D.Scalar.Timestamp_tz) nn in
    check_all (A1.dim data) (fun i -> Int64.equal data.{i} (Int64.of_int (i * 1_000_000)));
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = collect 6 D.Bulk.Int16 nullable in
    assert (A1.dim mask = 5000);
    check_all (A1.dim data) (fun i ->
      if i % 9 = 0 then data.{i} = 0 && mask.{i} = 0 else data.{i} = i && mask.{i} = 1);
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = collect 7 (D.Bulk.Int32 D.Scalar.Int32) nullable in
    assert (A1.dim mask = 5000);
    check_all (A1.dim data) (fun i ->
      if i % 11 = 0 then Int32.equal data.{i} 0l && mask.{i} = 0
      else Int32.equal data.{i} (Int32.of_int_exn i) && mask.{i} = 1);
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = collect 8 D.Bulk.Bool nullable in
    assert (A1.dim mask = 5000);
    check_all (A1.dim data) (fun i ->
      if i % 4 = 0 then data.{i} = 0 && mask.{i} = 0 else data.{i} = i % 2 && mask.{i} = 1));
  Stdlib.print_endline "bulk: every kind across chunks, nullable widths 1/2/4=ok"

(* Parameterised statements: the check uses the executed result's columns,
   which are resolved even where the prepared ones are not. *)
let () =
  connected (fun c ->
    let ranged n = ok (D.Statement.with_prepared c "SELECT * FROM range(?)" ~f:(fun p ->
      ok (D.Statement.bind p 1 D.Codec.Values.int64 (Int64.of_int n));
      D.Bulk.collect p ~column:0 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null)) in
    let { D.Bulk.data; _ } = ranged 5000 in
    assert (A1.dim data = 5000);
    for i = 0 to 4999 do assert (Int64.equal data.{i} (Int64.of_int i)) done;
    let { D.Bulk.data; _ } = ranged 0 in
    assert (A1.dim data = 0);
    let { D.Bulk.data; _ } = ok (D.Statement.with_prepared c
      "SELECT * FROM generate_series(1, ?) t(a), range(?) u(b) ORDER BY a, b" ~f:(fun p ->
        ok (D.Statement.bind p 1 D.Codec.Values.int64 3L);
        ok (D.Statement.bind p 2 D.Codec.Values.int64 4L);
        D.Bulk.collect p ~column:1 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null)) in
    assert (A1.dim data = 12);
    for i = 0 to 11 do assert (Int64.equal data.{i} (Int64.of_int (i % 4))) done);
  Stdlib.print_endline "bulk: parameterised statements collect=ok"
