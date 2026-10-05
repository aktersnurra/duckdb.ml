open! Base
open Duckdb
module S = Scalar
let ok = function
  | Ok x -> x | Error { Error.cause = Native s; _ } -> failwith s
  | Error { cause = Type_mismatch { index; expected; actual }; _ } ->
    failwith (Stdlib.Printf.sprintf "column/parameter %d expected %s actual type %s" index expected actual)
  | Error _ -> failwith "unexpected query error"
let error (expected : Error.cause -> bool) = function
  | Error { Error.cause; _ } when expected cause -> () | _ -> failwith "expected specific error"
let busy result = error (function Busy -> true | _ -> false) result
let children result = error (function Busy -> true | _ -> false) result
let index result = error (function Index _ -> true | _ -> false) result
let schema result = error (function Type_mismatch _ -> true | _ -> false) result
let non_null typ = Codec.Values.of_scalar typ
let decode typ = non_null typ
(* Executes [p] and reads column 0 through the borrowed-chunk lease; [inside]
   runs in every callback, while the result lease is held. *)
let rows ?(inside = fun () -> ()) p codec =
  Statement.fold_chunks p ~init:[] ~f:(fun chunk acc ->
    inside ();
    let acc = ref acc and failure = ref None in
    for row = 0 to Statement.chunk_length chunk - 1 do
      if Option.is_none !failure then
        (match Statement.column chunk ~column:0 ~row codec with
         | Ok x -> acc := x :: !acc
         | Error e -> failure := Some e)
    done;
    match !failure with None -> Ok (Continue !acc) | Some e -> Error e)
(* Preparation alone: a statement scope with no work. *)
let prepare c sql = Statement.with_prepared c sql ~f:(fun _ -> Ok ())
(* A typed request validates the schema at prepare, even for an empty result. *)
let query c sql codec =
  Request.Session.collect c (Request.many ~oneshot:true Fields.[] Fields.[codec] ~row:Fn.id sql) Args.[]
let config = ok (Config.create Memory)
(* Owned handles are global: callbacks may capture them. *)
let connected f =
  let db = ok (Owned.open_database config) in
  Exn.protect ~finally:(fun () -> ok (Owned.close_database db)) ~f:(fun () ->
    let c = ok (Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (Owned.close_connection c)) ~f:(fun () -> ok (f c)))
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let roundtrip c typ equal values =
  ok (Statement.with_prepared c ("SELECT ?::" ^ S.name typ) ~f:(fun p ->
    assert (ok (Statement.parameter_count p) = 1);
    error (function Unbound_parameter 1 -> true | _ -> false) (Statement.execute p);
    index (Statement.bind p (-1) (non_null typ) (List.hd_exn values));
    index (Statement.bind p 0 (non_null typ) (List.hd_exn values));
    index (Statement.bind p 2 (non_null typ) (List.hd_exn values));
    List.iter values ~f:(fun value ->
      ok (Statement.bind p 1 (non_null typ) value);
      for _ = 1 to 2 do
        (* The fold holds the result lease: the connection is Busy until it
           returns. (The callback cannot capture the local statement.) *)
        let inside () =
          busy (execute c "select 1"); busy (with_transaction c ~f:(fun _ -> Ok ())) in
        let copied = ok (rows ~inside p (decode typ)) in
        assert (List.equal equal copied [value])
      done);
    ok (Statement.bind p 1 Codec.Values.(nullable (of_scalar typ)) None);
    let nullable = ok (rows p Codec.Values.(nullable (of_scalar typ))) in
    assert (List.for_all nullable ~f:Option.is_none);
    error (function Null { column = 0; row = 0 } -> true | _ -> false)
      (rows p (decode typ));
    ok (Statement.reset p);
    error (function Unbound_parameter 1 -> true | _ -> false) (Statement.execute p);
    Ok ()))
let () =
  connected (fun c ->
    roundtrip c S.Bool Bool.equal [false; true];
    roundtrip c S.Int8 Stdlib_stable.Int8.equal [-128s; -1s; 0s; 127s];
    roundtrip c S.Int16 Stdlib_stable.Int16.equal [-32768S; 32767S];
    roundtrip c S.Int32 Int32.equal [Int32.min_value; Int32.max_value];
    roundtrip c S.Int64 Int64.equal [Int64.min_value; Int64.max_value];
    let float_equal a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Stdlib.Int64.bits_of_float a) (Stdlib.Int64.bits_of_float b) in
    roundtrip c S.Float32 (fun a b -> float_equal (Stdlib_stable.Float32.to_float a) (Stdlib_stable.Float32.to_float b))
      [0.s; -0.s; 0.1s; Stdlib_stable.Float32.of_float (Stdlib.Float.ldexp 1. (-149)); Stdlib_stable.Float32.infinity; Stdlib_stable.Float32.neg_infinity; Stdlib_stable.Float32.nan];
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
      error (function Native _ -> true | _ -> false) (prepare c "not valid SQL");
      ok (Statement.with_prepared c "SELECT error('execution fails')" ~f:(fun p ->
        for _ = 1 to 3 do error (function Native _ -> true | _ -> false) (Statement.execute p) done;
        Ok ()))
    done;
    ok (Statement.with_prepared c "SELECT ?::TINYINT, ?::FLOAT" ~f:(fun p ->
      schema (Statement.bind p 1 (non_null S.Int64) 1L); Ok ()));
    ok (Statement.with_prepared c "SELECT ?" ~f:(fun p ->
      ok (Statement.bind p 1 (non_null S.Int8) 2s);
      assert (List.length (ok (rows p (decode S.Int8))) = 1);
      ok (Statement.reset p); ok (Statement.bind p 1 (non_null S.String) "changed type");
      assert (List.length (ok (rows p (decode S.String))) = 1); Ok ()));
    assert (List.is_empty (ok (query c "SELECT 1::BIGINT WHERE false" (decode S.Int64))));
    schema (query c "SELECT 1::INTEGER WHERE false" (decode S.Int64));
    List.iter ["1::UBIGINT"; "1::HUGEINT"; "1::DECIMAL(10,2)"; "[1,2]"; "TIME '12:00:00'"] ~f:(fun expr ->
      schema (query c ("SELECT " ^ expr ^ " WHERE false") (decode S.Int64)));
    error (function Column_count { expected = 1; actual = 2 } -> true | _ -> false)
      (query c "SELECT 1,2" (decode S.Int32));
    Ok ());
  clean (); Stdlib.print_endline "query: policy/failures/range/schema/empty/unsupported=ok"
let () =
  connected (fun c ->
    let copied = ok (Statement.with_prepared c "SELECT case when i%67=0 then NULL else i end::BIGINT, 'a' || chr(0) || 'b' FROM range(5000) t(i)" ~f:(fun p ->
      let chunks = ref 0 in
      let result = Statement.fold_chunks p ~init:[] ~f:(fun chunk acc ->
        Int.incr chunks;
        busy (Owned.close_connection c); busy (execute c "select 1");
        index (Statement.column chunk ~column:(-1) ~row:0 (non_null S.Int64));
        index (Statement.column chunk ~column:2 ~row:0 (non_null S.Int64));
        index (Statement.column chunk ~column:0 ~row:(-1) (non_null S.Int64));
        index (Statement.column chunk ~column:0 ~row:(Statement.chunk_length chunk) (non_null S.Int64));
        schema (Statement.column chunk ~column:0 ~row:0 (non_null S.Int32));
        let rec copy row acc = if row = Statement.chunk_length chunk then acc else
          let value = ok (Statement.column chunk ~column:0 ~row Codec.Values.(nullable int64)) in
          assert (String.equal (ok (Statement.column chunk ~column:1 ~row (non_null S.String))) "a\000b");
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
    let run f = Statement.with_prepared c "SELECT i FROM range(5000) t(i)" ~f:(fun p ->
      Statement.fold_chunks p ~init:0 ~f) in
    assert (ok (run (fun _ _ -> Ok (Stop 7))) = 7);
    error (function Invalid_configuration "callback" -> true | _ -> false)
      (run (fun _ _ -> Error { context = Database; cause = Invalid_configuration "callback" }));
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
    ok (with_transaction c ~f:(fun tx ->
      Statement.with_prepared tx "SELECT 42::BIGINT" ~f:(fun p ->
        Statement.fold_chunks p ~init:() ~f:(fun _ () ->
          busy (prepare c "select 1"); Ok (Stop ())))));
    Ok ());
  clean (); Stdlib.print_endline "query: stop/error/exception/Break/effect/transaction-revocation=ok"
let () =
  let db = ok (Owned.open_database config) in
  Exn.protect ~finally:(fun () -> ok (Owned.close_database db)) ~f:(fun () ->
    let c = ok (Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (Owned.close_connection c)) ~f:(fun () ->
      ok (Statement.with_prepared c "select 1" ~f:(fun _ ->
        children (Owned.close_connection c); children (Owned.close_database db); Ok ()))));
  clean (); Stdlib.print_endline "query: parent-child-close=ok"
let () =
  connected (fun c ->
    let check sql typ equal expected =
      let values = ok (query c sql (decode typ)) in
      assert (List.equal equal values [expected]) in
    ok (Statement.with_prepared c "SELECT ?::TIMESTAMP_S" ~f:(fun p ->
      schema (Statement.bind p 1 (non_null S.Timestamp_us) 1000000L); Ok ()));
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
    (* DuckDB 1.5.5 materializes bare NULL as INTEGER, not logical SQLNULL. *)
    let decoder = Codec.Values.(nullable int32) in
    let copied = ok (query c "SELECT NULL" decoder) in
    assert (List.for_all copied ~f:Option.is_none);
    assert (List.is_empty (ok (query c "SELECT NULL WHERE false" decoder)));
    schema (query c "SELECT NULL WHERE false" (decode S.Int64));
    error (function Null _ -> true | _ -> false) (query c "SELECT NULL" (decode S.Int32));
    Ok ());
  clean (); Stdlib.print_endline "query: bare NULL retains engine-inferred INTEGER schema=ok"
let () =
  connected (fun c ->
    let run f = Statement.with_prepared c "select 1::BIGINT" ~f:(fun p -> Statement.fold_chunks p ~init:() ~f) in
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
      assert (handled = 42); assert (Statement.chunk_length chunk = 1); Ok (Stop ())));
    Ok ());
  clean (); Stdlib.print_endline "query: effect unwind/catch-reperform/composite exception/inner handler=ok"

(* Low-level bind/column take codecs, including custom ones. *)
let () =
  connected (fun c ->
    let parity = Codec.Values.custom Codec.Values.int64
      ~encode:(fun b -> Ok (if b then 1L else 0L)) ~decode:(fun n -> Ok (Int64.equal n 1L)) in
    ok (Statement.with_prepared c "SELECT ?::BIGINT AS x, NULL::VARCHAR AS y" ~f:(fun p ->
      ok (Statement.bind p 1 parity true);
      Statement.fold_chunks p ~init:() ~f:(fun chunk () ->
        let x = ok (Statement.column chunk ~column:0 ~row:0 parity) in
        let y = ok (Statement.column chunk ~column:1 ~row:0 Codec.Values.(nullable string)) in
        assert x; assert (Option.is_none y);
        Ok (Stop ()))));
    Ok ());
  Stdlib.print_endline "query: codec-typed bind/column incl. custom=ok"

(* Encoder/decoder rejections surface at the low level without disturbing state. *)
let () =
  connected (fun c ->
    let no_seven which = Codec.Values.custom Codec.Values.int64
      ~encode:(fun n -> if Int64.equal n 7L then Or_error.error_string "seven" else Ok n)
      ~decode:(fun n -> if Int64.equal n 3L && which then Or_error.error_string "three" else Ok n) in
    let codec = no_seven true in
    ok (Statement.with_prepared c "SELECT ?::BIGINT" ~f:(fun p ->
      ok (Statement.bind p 1 codec 5L);
      error (function Encode_rejected { index = 1; _ } -> true | _ -> false) (Statement.bind p 1 codec 7L);
      assert (List.equal Int64.equal (ok (rows p (decode S.Int64))) [5L]);
      Ok ()));
    ok (Statement.with_prepared c "SELECT * FROM (VALUES (1::BIGINT),(2),(3))" ~f:(fun p ->
      error (function Decode_rejected { column = 0; row = 2; _ } -> true | _ -> false)
        (Statement.fold_chunks p ~init:() ~f:(fun chunk () ->
          let outcome = ref (Ok (Continue ())) in
          for row = 0 to Statement.chunk_length chunk - 1 do
            if Result.is_ok !outcome then
              match Statement.column chunk ~column:0 ~row codec with Error e -> outcome := Error e | Ok _ -> ()
          done;
          !outcome));
      Ok ()));
    Ok ());
  Stdlib.print_endline "query: low-level encode/decode rejection=ok"
