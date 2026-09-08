open! Base
open Duckdb
module S = Scalar
let ok = function
  | Ok x -> x | Error (Native_error s) -> failwith s
  | Error (Data_error (S.Type_mismatch { index; expected; actual })) ->
    failwith (Stdlib.Printf.sprintf "column/parameter %d expected %s actual type %d" index expected actual)
  | Error _ -> failwith "unexpected query error"
let error expected = function Error e when expected e -> () | _ -> failwith "expected specific error"
let busy result = error (function Busy -> true | _ -> false) result
let closed result = error (function Closed -> true | _ -> false) result
let children result = error (function Live_children -> true | _ -> false) result
let index result = error (function Data_error (S.Index _) -> true | _ -> false) result
let schema result = error (function Data_error (S.Type_mismatch _) -> true | _ -> false) result
let required typ = S.Required typ
let decode typ = Row.Column (required typ, Row.Empty)
let rows r decoder = fold_rows r decoder ~init:[] ~f:(fun x xs -> Ok (Continue (x :: xs)))
let query c sql decoder = with_prepared c sql ~f:(fun p -> rows (ok (execute_prepared p)) decoder)
let config = ok (Config.create Memory)
let connected f = ok (with_database config ~f:(fun db -> with_connection db ~f))
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let roundtrip c typ equal values =
  ok (with_prepared c ("SELECT ?::" ^ S.name typ) ~f:(fun p ->
    assert (ok (parameter_count p) = 1);
    error (function Data_error (S.Unbound_parameter 1) -> true | _ -> false) (execute_prepared p);
    index (bind p (-1) (required typ) (List.hd_exn values));
    index (bind p 0 (required typ) (List.hd_exn values));
    index (bind p 2 (required typ) (List.hd_exn values));
    List.iter values ~f:(fun value ->
      ok (bind p 1 (required typ) value);
      for _ = 1 to 2 do
        let r = ok (execute_prepared p) in
        children (reset p); children (close_prepared p); children (execute_prepared p);
        busy (execute c "select 1"); busy (with_transaction c ~f:(fun _ -> Ok ()));
        let copied = ok (rows r (decode typ)) in
        assert (List.equal (fun (a, ()) (b, ()) -> equal a b) copied [value, ()]);
        ok (close_result r); ok (close_result r);
        closed (rows r (decode typ))
      done);
    ok (bind p 1 (S.Nullable typ) None);
    let nullable = ok (rows (ok (execute_prepared p)) (Row.Column (S.Nullable typ, Row.Empty))) in
    assert (List.for_all nullable ~f:(fun (x, ()) -> Option.is_none x));
    error (function Data_error (S.Null { column = 0; row = 0 }) -> true | _ -> false)
      (rows (ok (execute_prepared p)) (decode typ));
    ok (reset p);
    error (function Data_error (S.Unbound_parameter 1) -> true | _ -> false) (execute_prepared p);
    Ok ()))
let () =
  connected (fun c ->
    roundtrip c S.Bool Bool.equal [false; true];
    roundtrip c S.Int8 Int.equal [-128; -1; 0; 127];
    roundtrip c S.Int16 Int.equal [-32768; 32767];
    roundtrip c S.Int32 Int32.equal [Int32.min_value; Int32.max_value];
    roundtrip c S.Int64 Int64.equal [Int64.min_value; Int64.max_value];
    let float_equal a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Stdlib.Int64.bits_of_float a) (Stdlib.Int64.bits_of_float b) in
    roundtrip c S.Float32 float_equal [0.; -0.; S.round_float32 0.1; Stdlib.Float.ldexp 1. (-149); Float.infinity; Float.neg_infinity; Float.nan];
    roundtrip c S.Float64 float_equal [0.1; Float.max_finite_value; Float.min_positive_subnormal_value; Float.nan; -0.];
    roundtrip c S.String String.equal [""; "a\000b"; String.make 10000 'x'; "λ"];
    roundtrip c S.Blob String.equal [""; "\000\255abc\000"; String.make 10000 '\255'];
    roundtrip c S.Date Int32.equal [Int32.min_value; -1l; 0l; 2147483647l];
    List.iter [S.Timestamp_s; S.Timestamp_ms; S.Timestamp_us; S.Timestamp_ns; S.Timestamp_tz]
      ~f:(fun typ -> roundtrip c typ Int64.equal [Int64.min_value; -123456789012345L; -1L; 0L; 123456789012345L; Int64.max_value]);
    Ok ());
  clean ();
  Stdlib.print_endline "query: all scalar/NULL/extrema/unit/binding/reuse roundtrips=ok"
let () =
  connected (fun c ->
    List.iter ["BEGIN"; "COMMIT"; "ROLLBACK"; "SELECT 1; SELECT 2"; "PREPARE x AS SELECT 1"; "EXPLAIN SELECT 1"]
      ~f:(fun sql -> error (function Unsupported_statement -> true | _ -> false) (prepare c sql));
    error (function Embedded_nul -> true | _ -> false) (prepare c "SELECT 1\000;");
    for _ = 1 to 30 do
      error (function Native_error _ -> true | _ -> false) (prepare c "not valid SQL");
      ok (with_prepared c "SELECT error('execution fails')" ~f:(fun p ->
        for _ = 1 to 3 do error (function Native_error _ -> true | _ -> false) (execute_prepared p) done;
        Ok ()))
    done;
    let p = ok (prepare c "SELECT ?::TINYINT, ?::FLOAT") in
    error (function Data_error (S.Range _) -> true | _ -> false) (bind p 1 (required S.Int8) 128);
    error (function Data_error (S.Range _) -> true | _ -> false) (bind p 2 (required S.Float32) 0.1);
    schema (bind p 1 (required S.Int64) 1L);
    ok (close_prepared p); ok (close_prepared p); closed (reset p);
    ok (with_prepared c "SELECT ?" ~f:(fun p ->
      ok (bind p 1 (required S.Int8) 2);
      assert (List.length (ok (rows (ok (execute_prepared p)) (decode S.Int8))) = 1);
      ok (reset p); ok (bind p 1 (required S.String) "changed type");
      assert (List.length (ok (rows (ok (execute_prepared p)) (decode S.String))) = 1); Ok ()));
    assert (List.is_empty (ok (query c "SELECT 1::BIGINT WHERE false" (decode S.Int64))));
    schema (query c "SELECT 1::INTEGER WHERE false" (decode S.Int64));
    List.iter ["1::UBIGINT"; "1::HUGEINT"; "1::DECIMAL(10,2)"; "[1,2]"; "TIME '12:00:00'"] ~f:(fun expr ->
      schema (query c ("SELECT " ^ expr ^ " WHERE false") (decode S.Int64)));
    error (function Data_error (S.Column_count { expected = 1; actual = 2 }) -> true | _ -> false)
      (query c "SELECT 1,2" (decode S.Int32));
    Ok ());
  clean (); Stdlib.print_endline "query: policy/failures/range/schema/empty/unsupported=ok"
let () =
  connected (fun c ->
    let copied = ok (with_prepared c "SELECT case when i%67=0 then NULL else i end::BIGINT, 'a' || chr(0) || 'b' FROM range(5000) t(i)" ~f:(fun p ->
      let r = ok (execute_prepared p) in
      let chunks = ref 0 in
      let result = fold_chunks r ~init:[] ~f:(fun chunk acc ->
        Int.incr chunks;
        busy (close_result r); busy (close_prepared p); busy (reset p); busy (execute_prepared p);
        busy (close_connection c); busy (execute c "select 1");
        busy (fold_chunks r ~init:() ~f:(fun _ () -> Ok (Continue ())));
        index (column chunk ~column:(-1) ~row:0 (required S.Int64));
        index (column chunk ~column:2 ~row:0 (required S.Int64));
        index (column chunk ~column:0 ~row:(-1) (required S.Int64));
        index (column chunk ~column:0 ~row:(chunk_length chunk) (required S.Int64));
        schema (column chunk ~column:0 ~row:0 (required S.Int32));
        let rec copy row acc = if row = chunk_length chunk then acc else
          let value = ok (column chunk ~column:0 ~row (S.Nullable S.Int64)) in
          assert (String.equal (ok (column chunk ~column:1 ~row (required S.String))) "a\000b");
          copy (row + 1) (value :: acc) in
        let copied = copy 0 acc in
        Stdlib.Gc.compact ();
        Ok (Continue copied)) in
      assert (!chunks >= 3); result)) in
    assert (List.length copied = 5000);
    List.iteri (List.rev copied) ~f:(fun i value ->
      if i % 67 = 0 then assert (Option.is_none value)
      else assert (Option.value_map value ~default:false ~f:(Int64.equal (Int64.of_int i))));
    let owned : int64 option list = copied in
    let transferred = Stdlib.Domain.Safe.spawn (fun () -> List.length owned) in
    assert (Stdlib.Domain.join transferred = 5000);
    Ok ());
  clean (); Stdlib.print_endline "query: genuine buffers/validity/multichunk/copy/aliases/indices=ok"
exception Callback_failure
type _ Stdlib.Effect.t += Pause : unit Stdlib.Effect.t
let () =
  connected (fun c ->
    let run f = with_prepared c "SELECT i FROM range(5000) t(i)" ~f:(fun p ->
      fold_chunks (ok (execute_prepared p)) ~init:0 ~f) in
    assert (ok (run (fun _ _ -> Ok (Stop 7))) = 7);
    error (function Invalid_configuration "callback" -> true | _ -> false)
      (run (fun _ _ -> Error (Invalid_configuration "callback")));
    (match run (fun _ _ -> raise Callback_failure) with
     | exception Callback_failure -> () | _ -> assert false);
    (match run (fun _ _ -> raise Stdlib.Sys.Break) with
     | exception Stdlib.Sys.Break -> () | _ -> assert false);
    let delivered = ref false in
    let denied () = run (fun _ n ->
      (try Stdlib.Effect.perform Pause with _ -> ()); Ok (Continue n)) in
    let result = Stdlib.Effect.Deep.try_with denied ()
      { effc = fun (type a) (effect : a Stdlib.Effect.t) -> match effect with
        | Pause -> Some (fun (k : (a, _) Stdlib.Effect.Deep.continuation) -> delivered := true; Stdlib.Effect.Deep.continue k ())
        | _ -> None } in
    error (function Effects_not_allowed -> true | _ -> false) result;
    assert (not !delivered);
    let retained_p = ref None and retained_r = ref None in
    ok (with_transaction c ~f:(fun tx ->
      let p = ok (prepare_transaction tx "SELECT 42::BIGINT") in
      let r = ok (execute_prepared p) in
      retained_p := Some p; retained_r := Some r;
      busy (prepare c "select 1"); busy (execute_transaction tx "select 1"); Ok ()));
    let p = Option.value_exn !retained_p and r = Option.value_exn !retained_r in
    closed (execute_prepared p); closed (rows r (decode S.Int64)); ok (close_result r); ok (close_prepared p);
    let p = ok (prepare c "SELECT 1") in
    ok (with_transaction c ~f:(fun _ -> busy (execute_prepared p); Ok ()));
    ok (close_prepared p);
    Ok ());
  clean (); Stdlib.print_endline "query: stop/error/exception/Break/effect/transaction-revocation=ok"
let () =
  let retained = ref None in
  ok (with_database config ~f:(fun db ->
    let c = ok (connect db) in
    let p = ok (prepare c "select 1") in
    children (close_connection c); children (close_database db);
    retained := Some (p, ok (execute_prepared p)); Ok ()));
  let p, r = Option.value_exn !retained in
  closed (reset p); ok (close_prepared p); ok (close_result r);
  clean (); Stdlib.print_endline "query: scoped-parent-child-close=ok"
let () =
  connected (fun c ->
    let check sql typ equal expected =
      let values = ok (query c sql (decode typ)) in
      assert (List.equal (fun (a, ()) (b, ()) -> equal a b) values [expected, ()]) in
    ok (with_prepared c "SELECT ?::TIMESTAMP_S" ~f:(fun p ->
      schema (bind p 1 (required S.Timestamp_us) 1000000L); Ok ()));
    schema (query c "SELECT TIMESTAMP_S '1970-01-01 00:00:01'" (decode S.Timestamp_us));
    check "SELECT DATE '1969-12-31'" S.Date Int32.equal (-1l);
    check "SELECT TIMESTAMP_S '1970-01-01 00:00:01'" S.Timestamp_s Int64.equal 1L;
    check "SELECT TIMESTAMP_MS '1970-01-01 00:00:01.001'" S.Timestamp_ms Int64.equal 1001L;
    check "SELECT TIMESTAMP '1969-12-31 23:59:59.999999'" S.Timestamp_us Int64.equal (-1L);
    check "SELECT TIMESTAMP_NS '1970-01-01 00:00:01.000000001'" S.Timestamp_ns Int64.equal 1000000001L;
    check "SELECT TIMESTAMPTZ '1970-01-01 01:00:00+01:00'" S.Timestamp_tz Int64.equal 0L;
    Ok ());
  clean (); Stdlib.print_endline "query: independent native date/timestamp units/UTC semantics=ok"
let () =
  connected (fun c ->
    let other = ref None in
    ok (with_prepared c "select 1" ~f:(fun _ ->
      let p = ok (prepare c "select 2") in
      other := Some (p, ok (execute_prepared p)); Ok ()));
    (* Closing a sibling prepared scope must not clear someone else's lease. *)
    busy (execute c "select 3");
    let p, r = Option.value_exn !other in
    ok (close_result r); ok (close_prepared p); Ok ());
  clean (); Stdlib.print_endline "query: sibling scoped close preserves result lease identity=ok"
let () =
  connected (fun c ->
    (* DuckDB 1.5.5 materializes bare NULL as INTEGER, not logical SQLNULL. *)
    let decoder = Row.Column (S.Nullable S.Int32, Row.Empty) in
    let copied = ok (query c "SELECT NULL" decoder) in
    assert (List.for_all copied ~f:(fun (value, ()) -> Option.is_none value));
    assert (List.is_empty (ok (query c "SELECT NULL WHERE false" decoder)));
    schema (query c "SELECT NULL WHERE false" (decode S.Int64));
    error (function Data_error (S.Null _) -> true | _ -> false) (query c "SELECT NULL" (decode S.Int32));
    Ok ());
  clean (); Stdlib.print_endline "query: bare NULL retains engine-inferred INTEGER schema=ok"
let () =
  connected (fun c ->
    let run f = with_prepared c "select 1::BIGINT" ~f:(fun p -> fold_chunks (ok (execute_prepared p)) ~init:() ~f) in
    let unwound = ref 0 in
    error (function Effects_not_allowed -> true | _ -> false)
      (run (fun _ () -> Exn.protect ~f:(fun () -> Stdlib.Effect.perform Pause; Ok (Stop ()))
        ~finally:(fun () -> Int.incr unwound)));
    assert (!unwound = 1);
    error (function Effects_not_allowed -> true | _ -> false)
      (run (fun _ () -> (try Stdlib.Effect.perform Pause with _ -> Stdlib.Effect.perform Pause); Ok (Stop ())));
    (match run (fun _ () -> Exn.protect ~f:(fun () -> raise Callback_failure)
      ~finally:(fun () -> Stdlib.Effect.perform Pause)) with
     | exception Exn.Finally (Callback_failure, _) -> () | _ -> assert false);
    ok (run (fun chunk () ->
      let handled = Stdlib.Effect.Deep.try_with (fun () -> Stdlib.Effect.perform Pause; 42) ()
        { effc = fun (type a) (effect : a Stdlib.Effect.t) -> match effect with
          | Pause -> Some (fun (k : (a, _) Stdlib.Effect.Deep.continuation) -> Stdlib.Effect.Deep.continue k ())
          | _ -> None } in
      assert (handled = 42); assert (chunk_length chunk = 1); Ok (Stop ())));
    Ok ());
  clean (); Stdlib.print_endline "query: effect unwind/catch-reperform/composite exception/inner handler=ok"
