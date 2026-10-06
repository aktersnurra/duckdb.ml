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

(* Columnar ingest across chunk boundaries, with NULL masks and strings. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE users(id BIGINT, name VARCHAR, age INTEGER)");
    let users = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
      ~row:(fun id name age -> (id, name, age))) in
    let n = 5000 in
    let ids = A1.init Bigarray.int64 Bigarray.c_layout n Int64.of_int in
    let ages = A1.init Bigarray.int32 Bigarray.c_layout n Int32.of_int_trunc in
    let valid = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i % 4 = 0 then 0 else 1) in
    let names = Array.init n ~f:(fun i -> "u" ^ Int.to_string i) in
    ok (D.Table.with_appender c users ~f:(fun a ->
      D.Table.append_columns a D.Bulk.Columns.[
        Int64 (D.Scalar.Int64, ids); Strings (D.Scalar.String, names); Nullable (Int32 (D.Scalar.Int32, ages), valid) ]));
    let back = ok (D.Request.Session.collect c (D.Table.select users) D.Args.[]) in
    let back = List.sort back ~compare:(fun (a, _, _) (b, _, _) -> Int64.compare a b) in
    assert (List.length back = n);
    List.iteri back ~f:(fun i (id, name, age) ->
      assert (Int64.equal id (Int64.of_int i) && String.equal name ("u" ^ Int.to_string i));
      assert (Option.equal Int32.equal age (if i % 4 = 0 then None else Some (Int32.of_int_trunc i)))));
  Stdlib.print_endline "bulk: append_columns across chunks with masks and strings=ok"

(* Runtime rejections, all before any native work. Masks are all-valid except
   in the NULL case, so each attempt trips exactly one check. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE t(a BIGINT NOT NULL, ts TIMESTAMP, v BIGINT)");
    let positive = D.Codec.Values.custom ~encode:(fun (n : int64) -> if Int64.(n > 0L) then Ok n else Or_error.error_string "neg")
      ~decode:Or_error.return D.Codec.Values.int64 in
    let custom = D.Table.(declare "t" Columns.["a", nullable int64; "ts", timestamp_us; "v", positive] ~row:(fun a ts v -> (a, ts, v))) in
    let plain = D.Table.(declare "t" Columns.["a", nullable int64; "ts", timestamp_us; "v", int64] ~row:(fun a ts v -> (a, ts, v))) in
    let i64 n = A1.create Bigarray.int64 Bigarray.c_layout n in
    let valid n = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun _ -> 1) in
    let hole n = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i = 1 then 0 else 1) in
    let attempt table cols = D.Table.with_appender c table ~f:(fun a -> D.Table.append_columns a cols) in
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Timestamp_us, i64 2); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Length_mismatch { column = 1; expected = 3; actual = 2 }; _ } -> ()
     | _ -> failwith "length mismatch expected");
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Int64, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Type_mismatch { index = 1; _ }; _ } -> ()
     | _ -> failwith "engine scalar mismatch expected");
    (match attempt custom D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Timestamp_us, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Encode_rejected { index = 3; _ }; _ } -> ()
     | _ -> failwith "custom codec rejection expected");
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), hole 3); Int64 (D.Scalar.Timestamp_us, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Null { column = 0; row = 1 }; _ } -> ()
     | _ -> failwith "NULL in NOT NULL column expected");
    assert (Int64.equal (ok (D.Request.Session.find c (D.Request.one D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT count(*)::BIGINT FROM t") D.Args.[])) 0L));
  Stdlib.print_endline "bulk: append_columns rejects lengths, scalars, custom codecs and NULLs before native work=ok"

(* A rejected pre-check leaves the appender usable; invalid UTF-8 fails and
   poisons like row ingest, while a masked-NULL string is never validated. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE s(n BIGINT NOT NULL, name VARCHAR)");
    let s = D.Table.(declare "s" Columns.["n", int64; "name", nullable string] ~row:(fun n name -> (n, name))) in
    let bad = "\xff\xfe" in
    let ns k = A1.init Bigarray.int64 Bigarray.c_layout k Int64.of_int in
    let mask l = A1.of_array Bigarray.int8_unsigned Bigarray.c_layout l in
    ok (D.Table.with_appender c s ~f:(fun a ->
      (match D.Table.append_columns a D.Bulk.Columns.[Int64 (D.Scalar.Int64, ns 2); Nullable (Strings (D.Scalar.String, [| "x" |]), mask [| 1 |])] with
       | Error { cause = Length_mismatch { column = 1; expected = 2; actual = 1 }; _ } -> ()
       | _ -> failwith "length mismatch expected");
      D.Table.append_columns a D.Bulk.Columns.[Int64 (D.Scalar.Int64, ns 2); Nullable (Strings (D.Scalar.String, [| "x"; bad |]), mask [| 1; 0 |])]));
    let back = ok (D.Request.Session.collect c (D.Table.select s) D.Args.[]) in
    assert (List.equal Poly.equal (List.sort back ~compare:Poly.compare) [ (0L, Some "x"); (1L, None) ]);
    let first = ref None in
    (match D.Table.with_appender c s ~f:(fun a ->
       (match D.Table.append_columns a D.Bulk.Columns.[Int64 (D.Scalar.Int64, ns 2); Nullable (Strings (D.Scalar.String, [| "y"; bad |]), mask [| 1; 1 |])] with
        | Error ({ cause = Native _; _ } as e) -> first := Some e
        | _ -> failwith "invalid UTF-8 expected");
       match D.Table.append_columns a D.Bulk.Columns.[Int64 (D.Scalar.Int64, ns 1); Nullable (Strings (D.Scalar.String, [| "z" |]), mask [| 1 |])] with
       | Error e -> assert (Poly.equal (Some e) !first); Ok ()
       | Ok () -> failwith "poisoned appender expected") with
     | Error _ -> ()
     | Ok () -> failwith "poisoned scope expected");
    let count = ok (D.Request.Session.find c (D.Request.one D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT count(*)::BIGINT FROM s") D.Args.[]) in
    assert (Int64.equal count 2L));
  Stdlib.print_endline "bulk: append_columns pre-checks do not poison; invalid UTF-8 poisons; masked strings unchecked=ok"

(* Every fixed-width kind blits across slices; booleans normalize to 0/1. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE k(b BOOLEAN, i8 TINYINT, i16 SMALLINT, f32 FLOAT, f64 DOUBLE, d DATE)");
    let k = D.Table.(declare "k" Columns.["b", bool; "i8", int8; "i16", int16; "f32", float32; "f64", float64; "d", date]
      ~row:(fun b i8 i16 f32 f64 d -> (b, i8, i16, f32, f64, d))) in
    let n = 3000 in
    let init kind f = A1.init kind Bigarray.c_layout n f in
    ok (D.Table.with_appender c k ~f:(fun a ->
      D.Table.append_columns a D.Bulk.Columns.[
        Bool (init Bigarray.int8_unsigned (fun i -> i % 3));
        Int8 (init Bigarray.int8_signed (fun i -> i % 100 - 50));
        Int16 (init Bigarray.int16_signed (fun i -> i - 1500));
        Float32 (init Bigarray.float32 (fun i -> Float.of_int i /. 2.));
        Float64 (init Bigarray.float64 (fun i -> Float.of_int i /. 4.));
        Int32 (D.Scalar.Date, init Bigarray.int32 Int32.of_int_trunc) ]));
    let back = ok (D.Request.Session.collect c (D.Table.select k) D.Args.[]) in
    let back = List.sort back ~compare:(fun (_, _, a, _, _, _) (_, _, b, _, _, _) ->
      Int.compare (Stdlib_stable.Int16.to_int a) (Stdlib_stable.Int16.to_int b)) in
    assert (List.length back = n);
    List.iteri back ~f:(fun i (b, i8, i16, f32, f64, d) ->
      assert (Bool.equal b (i % 3 <> 0));
      assert (Stdlib_stable.Int8.to_int i8 = i % 100 - 50 && Stdlib_stable.Int16.to_int i16 = i - 1500);
      assert (Float.equal (Stdlib_stable.Float32.to_float f32) (Float.of_int i /. 2.));
      assert (Float.equal f64 (Float.of_int i /. 4.) && Int32.equal d (Int32.of_int_trunc i))));
  Stdlib.print_endline "bulk: append_columns blits bool, int8, int16, float32, float64 and date=ok"

(* Zero rows insert nothing; an exact multiple of the vector size; timestamp
   scalars; BLOB bytes are not UTF-8 validated. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE e(ts TIMESTAMP NOT NULL, bytes BLOB)");
    let e = D.Table.(declare "e" Columns.["ts", timestamp_us; "bytes", nullable blob] ~row:(fun ts b -> (ts, b))) in
    let count () = ok (D.Request.Session.find c (D.Request.one D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT count(*)::BIGINT FROM e") D.Args.[]) in
    let columns k ~blob = D.Bulk.Columns.[
      Int64 (D.Scalar.Timestamp_us, A1.init Bigarray.int64 Bigarray.c_layout k (fun i -> Int64.of_int (i * 1_000_000)));
      Nullable (Strings (D.Scalar.Blob, Array.init k ~f:blob), A1.init Bigarray.int8_unsigned Bigarray.c_layout k (fun _ -> 1)) ] in
    ok (D.Table.with_appender c e ~f:(fun a -> D.Table.append_columns a (columns 0 ~blob:(fun _ -> ""))));
    assert (Int64.equal (count ()) 0L);
    let blob i = if i % 2 = 0 then "\xff\xfe" ^ Int.to_string i else Int.to_string i in
    ok (D.Table.with_appender c e ~f:(fun a -> D.Table.append_columns a (columns 4096 ~blob)));
    assert (Int64.equal (count ()) 4096L);
    let back = List.sort (ok (D.Request.Session.collect c (D.Table.select e) D.Args.[]))
      ~compare:(fun (a, _) (b, _) -> Int64.compare a b) in
    List.iteri back ~f:(fun i (ts, bytes) ->
      assert (Int64.equal ts (Int64.of_int (i * 1_000_000)));
      assert (Option.equal String.equal bytes (Some (blob i)))));
  Stdlib.print_endline "bulk: append_columns zero rows, 4096 rows, timestamps and raw BLOB bytes=ok"
