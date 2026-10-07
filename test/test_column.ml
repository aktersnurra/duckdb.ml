open! Base
module D = Duckdb
module C = D.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u
module I32 = Stdlib_upstream_compatible.Int32_u
module F64 = Stdlib_upstream_compatible.Float_u
module F32 = Stdlib_stable.Float32_u
let ok = function Ok x -> x | Error (e : D.Error.t) -> failwith (match e.cause with Native s -> s | _ -> "unexpected error")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
(* Sums a non-null BIGINT view without allocating. *)
let[@zero_alloc] rec sum (v @ local) i n acc =
  if i = n then acc else sum v (i + 1) n (I64.add acc (C.int64 v i))
let[@zero_alloc] rec sum_or (v @ local) i n acc =
  if i = n then acc else sum_or v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))
let fold_views c sql ~init ~f = ok (D.Statement.with_prepared c sql ~f:(fun p ->
  D.Statement.fold_chunks p ~init ~f))

(* Every scalar reads back exactly through its accessor. *)
let () =
  connected (fun c ->
    let sql = "SELECT 7::BIGINT, 8::INTEGER, 9::SMALLINT, 10::TINYINT, true, 1.5::DOUBLE, 2.5::FLOAT, \
               'hi', DATE '1970-01-03', TIMESTAMP '1970-01-01 00:00:01'" in
    fold_views c sql ~init:() ~f:(fun chunk () ->
      let open_ (type a) column (scalar : a D.Scalar.t) k =
        match C.view chunk column scalar C.Non_null with
        | C.Rejected e -> Error e
        | C.Opened v -> k v [@nontail] in
      ignore (open_ 0 D.Scalar.Int64 (fun v -> assert (I64.equal (C.int64 v 0) #7L); Ok ()) : (unit, _) result);
      ignore (open_ 1 D.Scalar.Int32 (fun v -> assert (Int32.equal (I32.to_int32 (C.int32 v 0)) 8l); Ok ()) : (unit, _) result);
      ignore (open_ 2 D.Scalar.Int16 (fun v -> assert (Stdlib_stable.Int16.to_int (C.int16 v 0) = 9); Ok ()) : (unit, _) result);
      ignore (open_ 3 D.Scalar.Int8 (fun v -> assert (Stdlib_stable.Int8.to_int (C.int8 v 0) = 10); Ok ()) : (unit, _) result);
      ignore (open_ 4 D.Scalar.Bool (fun v -> assert (C.bool v 0); Ok ()) : (unit, _) result);
      ignore (open_ 5 D.Scalar.Float64 (fun v -> assert (Float.equal (F64.to_float (C.float v 0)) 1.5); Ok ()) : (unit, _) result);
      ignore (open_ 6 D.Scalar.Float32 (fun v -> assert (Float.equal (Stdlib_stable.Float32.to_float (F32.to_float32 (C.float32 v 0))) 2.5); Ok ()) : (unit, _) result);
      ignore (open_ 7 D.Scalar.String (fun v -> assert (String.equal (C.string v 0) "hi"); Ok ()) : (unit, _) result);
      ignore (open_ 8 D.Scalar.Date (fun v -> assert (Int32.equal (I32.to_int32 (C.int32 v 0)) 2l); Ok ()) : (unit, _) result);
      ignore (open_ 9 D.Scalar.Timestamp_us (fun v -> assert (I64.equal (C.int64 v 0) #1_000_000L); Ok ()) : (unit, _) result);
      Ok (D.Continue ())));
  Stdlib.print_endline "column: every scalar reads back=ok"

(* Sums across chunk boundaries; NULLs read as the explicit default. *)
let () =
  connected (fun c ->
    let total = fold_views c
      "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(5000) t(i) ORDER BY i"
      ~init:(0L, 0L) ~f:(fun chunk (a, b) ->
        match C.view chunk 0 D.Scalar.Int64 C.Non_null, C.view chunk 1 D.Scalar.Int64 C.Nullable with
        | C.Rejected e, _ | _, C.Rejected e -> Error e
        | C.Opened x, C.Opened y ->
          let n = C.length x in
          assert (C.length y = n);
          Ok (D.Continue (Int64.(a + I64.to_int64 (sum x 0 n #0L)), Int64.(b + I64.to_int64 (sum_or y 0 n #0L))))) in
    assert (Poly.equal total (12_497_500L, 11_250_000L)));
  Stdlib.print_endline "column: sums across chunks with explicit NULL defaults=ok"

(* View failures: wrong type, bad index, NULL in a non-null view. *)
let () =
  connected (fun c ->
    (* The first rejection over every chunk: views of later chunks open too. *)
    let cause (type a n) sql column (scalar : a D.Scalar.t) (nulls : n C.nulls) =
      let r = ref None in
      fold_views c sql ~init:() ~f:(fun chunk () ->
        (match C.view chunk column scalar nulls with
         | C.Rejected e -> if Option.is_none !r then r := Some e.cause
         | C.Opened _ -> ());
        Ok (D.Continue ()));
      !r in
    (match cause "SELECT 1::INTEGER" 0 D.Scalar.Int64 C.Non_null with
     | Some (Type_mismatch { index = 0; expected = "BIGINT"; actual = "INTEGER" }) -> ()
     | _ -> failwith "type mismatch expected");
    (match cause "SELECT 1::BIGINT" 3 D.Scalar.Int64 C.Non_null with
     | Some (Index { index = 3; length = 1 }) -> () | _ -> failwith "index expected");
    (match cause "SELECT * FROM (VALUES (1::BIGINT), (NULL)) t(x)" 0 D.Scalar.Int64 C.Non_null with
     | Some (Null { column = 0; row = 1 }) -> () | _ -> failwith "null expected");
    (match cause "SELECT * FROM (VALUES (1::BIGINT), (NULL)) t(x)" 0 D.Scalar.Int64 C.Nullable with
     | None -> () | Some _ -> failwith "nullable view opens");
    (* The first-NULL scan crosses validity words (row 100 is in the second). *)
    (match cause "SELECT CASE WHEN i = 100 THEN NULL ELSE i END FROM range(130) t(i) ORDER BY i"
             0 D.Scalar.Int64 C.Non_null with
     | Some (Null { column = 0; row = 100 }) -> () | _ -> failwith "null at row 100 expected");
    (* Row 2100 is row 52 of the second 2048-row chunk: rows are chunk-relative. *)
    (match cause "SELECT CASE WHEN i = 2100 THEN NULL ELSE i END FROM range(3000) t(i) ORDER BY i"
             0 D.Scalar.Int64 C.Non_null with
     | Some (Null { column = 0; row = 52 }) -> () | _ -> failwith "chunk-relative null at row 52 expected"));
  Stdlib.print_endline "column: type, index and NULL rejections=ok"

(* An index outside the chunk raises, like Array.get. *)
let () =
  connected (fun c ->
    fold_views c "SELECT 1::BIGINT" ~init:() ~f:(fun chunk () ->
      match C.view chunk 0 D.Scalar.Int64 C.Non_null with
      | C.Rejected e -> Error e
      | C.Opened v ->
        (match C.int64 v 1 with
         | _ -> failwith "out of bounds read accepted"
         | exception Invalid_argument _ -> ());
        (match C.int64 v (-1) with
         | _ -> failwith "negative row read accepted"
         | exception Invalid_argument _ -> ());
        Ok (D.Continue ())));
  Stdlib.print_endline "column: out-of-bounds read raises=ok"

(* Nullable views: [is_null], [string_opt] and explicit defaults. *)
let () =
  connected (fun c ->
    fold_views c "SELECT * FROM (VALUES ('a', 1.5::DOUBLE, true), (NULL, NULL, NULL)) t(s, f, b)"
      ~init:() ~f:(fun chunk () ->
      match C.view chunk 0 D.Scalar.String C.Nullable, C.view chunk 1 D.Scalar.Float64 C.Nullable,
            C.view chunk 2 D.Scalar.Bool C.Nullable with
      | C.Rejected e, _, _ | _, C.Rejected e, _ | _, _, C.Rejected e -> Error e
      | C.Opened s, C.Opened f, C.Opened b ->
        assert (C.length s = 2);
        assert (not (C.is_null s 0) && C.is_null s 1);
        assert (not (C.is_null f 0) && C.is_null f 1);
        assert (not (C.is_null b 0) && C.is_null b 1);
        assert (Poly.equal (C.string_opt s 0) (Some "a"));
        assert (Option.is_none (C.string_opt s 1));
        assert (Float.equal (F64.to_float (C.float_or f ~default:#9.0 0)) 1.5);
        assert (Float.equal (F64.to_float (C.float_or f ~default:#9.0 1)) 9.0);
        assert (C.bool_or b ~default:false 0);
        assert (C.bool_or b ~default:true 1);
        Ok (D.Continue ())));
  Stdlib.print_endline "column: nullable views read NULLs and defaults=ok"

(* Every [_or] accessor: the value at a valid row, the default at a NULL row. *)
let () =
  connected (fun c ->
    fold_views c "SELECT * FROM (VALUES (7::BIGINT, 8::INTEGER, 9::SMALLINT, 10::TINYINT, true, 1.5::DOUBLE, \
                  2.5::FLOAT), (NULL, NULL, NULL, NULL, NULL, NULL, NULL)) t(a, b, c, d, e, f, g)"
      ~init:() ~f:(fun chunk () ->
      let open_ (type a) column (scalar : a D.Scalar.t) k =
        match C.view chunk column scalar C.Nullable with
        | C.Rejected e -> Error e
        | C.Opened v -> k v [@nontail] in
      let check = function Ok () -> () | Error _ -> failwith "nullable view rejected" in
      check @@ open_ 0 D.Scalar.Int64 (fun v ->
        assert (I64.equal (C.int64_or v ~default:(I64.of_int64 (-1L)) 0) #7L);
        assert (I64.equal (C.int64_or v ~default:(I64.of_int64 (-1L)) 1) (I64.of_int64 (-1L))); Ok ());
      check @@ open_ 1 D.Scalar.Int32 (fun v ->
        assert (Int32.equal (I32.to_int32 (C.int32_or v ~default:(I32.of_int32 (-1l)) 0)) 8l);
        assert (Int32.equal (I32.to_int32 (C.int32_or v ~default:(I32.of_int32 (-1l)) 1)) (-1l)); Ok ());
      check @@ open_ 2 D.Scalar.Int16 (fun v ->
        let d = Stdlib_stable.Int16.of_int (-1) in
        assert (Stdlib_stable.Int16.to_int (C.int16_or v ~default:d 0) = 9);
        assert (Stdlib_stable.Int16.to_int (C.int16_or v ~default:d 1) = -1); Ok ());
      check @@ open_ 3 D.Scalar.Int8 (fun v ->
        let d = Stdlib_stable.Int8.of_int (-1) in
        assert (Stdlib_stable.Int8.to_int (C.int8_or v ~default:d 0) = 10);
        assert (Stdlib_stable.Int8.to_int (C.int8_or v ~default:d 1) = -1); Ok ());
      check @@ open_ 4 D.Scalar.Bool (fun v ->
        assert (C.bool_or v ~default:false 0);
        assert (C.bool_or v ~default:true 1); Ok ());
      check @@ open_ 5 D.Scalar.Float64 (fun v ->
        assert (Float.equal (F64.to_float (C.float_or v ~default:#9.0 0)) 1.5);
        assert (Float.equal (F64.to_float (C.float_or v ~default:#9.0 1)) 9.0); Ok ());
      check @@ open_ 6 D.Scalar.Float32 (fun v ->
        let f32 x = Stdlib_stable.Float32.to_float (F32.to_float32 x) in
        assert (Float.equal (f32 (C.float32_or v ~default:#9.0s 0)) 2.5);
        assert (Float.equal (f32 (C.float32_or v ~default:#9.0s 1)) 9.0); Ok ());
      Ok (D.Continue ())));
  Stdlib.print_endline "column: every _or accessor reads values and NULL defaults=ok"

(* [null_count]: 0 without NULLs; across validity words and a later chunk it
   equals the per-row [is_null] count. *)
let () =
  connected (fun c ->
    let rec count_nulls (v @ local) i n acc =
      if i = n then acc else count_nulls v (i + 1) n (if C.is_null v i then acc + 1 else acc) in
    let counts sql =
      fold_views c sql ~init:[] ~f:(fun chunk acc ->
        match C.view chunk 0 D.Scalar.Int64 C.Nullable with
        | C.Rejected e -> Error e
        | C.Opened v ->
          let n = C.null_count v in
          assert (n = count_nulls v 0 (C.length v) 0);
          Ok (D.Continue (n :: acc))) |> List.rev in
    assert (Poly.equal (counts "SELECT i::BIGINT FROM range(100) t(i)") [ 0 ]);
    (* 3000 rows: chunks of 2048 and 952; NULL every 7th row and rows 100..199. *)
    let per_chunk = counts "SELECT CASE WHEN i % 7 = 0 OR i BETWEEN 100 AND 199 THEN NULL ELSE i END::BIGINT \
                            FROM range(3000) t(i) ORDER BY i" in
    let expected lo hi = List.count (List.range lo hi) ~f:(fun i -> i % 7 = 0 || (i >= 100 && i <= 199)) in
    assert (Poly.equal per_chunk [ expected 0 2048; expected 2048 3000 ]));
  Stdlib.print_endline "column: null_count matches per-row is_null across words and chunks=ok"

(* [_or] accessors bounds-check like the non-null ones: index = length and -1 raise. *)
let () =
  connected (fun c ->
    fold_views c "SELECT * FROM (VALUES (1::BIGINT, 2::TINYINT), (NULL, NULL)) t(a, b)" ~init:() ~f:(fun chunk () ->
      match C.view chunk 0 D.Scalar.Int64 C.Nullable, C.view chunk 1 D.Scalar.Int8 C.Nullable with
      | C.Rejected e, _ | _, C.Rejected e -> Error e
      | C.Opened a, C.Opened b ->
        let n = C.length a in
        assert (n = 2 && C.length b = 2);
        List.iter [ n; -1 ] ~f:(fun i ->
          (match C.int64_or a ~default:#0L i with
           | _ -> failwith "out of bounds int64_or accepted"
           | exception Invalid_argument _ -> ());
          match C.int8_or b ~default:(Stdlib_stable.Int8.of_int 0) i with
          | _ -> failwith "out of bounds int8_or accepted"
          | exception Invalid_argument _ -> ());
        Ok (D.Continue ())));
  Stdlib.print_endline "column: out-of-bounds _or reads raise=ok"
