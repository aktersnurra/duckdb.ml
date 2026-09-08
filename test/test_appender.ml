open! Base
open Duckdb
let rec message = function
  | Native_error s -> s
  | Rollback_failed (a,b) -> message a ^ "; rollback: " ^ message b
  | Data_error (Scalar.Type_mismatch {index;expected;actual}) -> Stdlib.Printf.sprintf "column %d expected %s actual %d" index expected actual
  | _ -> "structured error"
let ok = function Ok x -> x | Error e -> failwith (message e)
let error = function Error e -> e | Ok _ -> failwith "expected error"
let rows c sql decoder = ok (with_prepared c sql ~f:(fun p ->
  fold_rows (ok (execute_prepared p)) decoder ~init:[] ~f:(fun row xs -> Ok (Continue (row::xs))))) |> List.rev
let count c table = match rows c ("SELECT count(*) FROM " ^ table) Row.(Column (Required Int64,Empty)) with
  | [(n,())] -> n | _ -> assert false
let scalar : type a. connection -> a Scalar.t -> a list -> (a -> a -> bool) -> unit = fun c typ values equal ->
  ok (execute c ("CREATE OR REPLACE TABLE scalars(x " ^ Scalar.name typ ^ ")"));
  let expected = None :: List.map values ~f:Option.some in
  ok (with_appender c "scalars" ~f:(fun a ->
    ok (append_rows a []);
    append_rows a (List.map expected ~f:(fun x -> [Cell (Nullable typ,x)]))));
  let actual = rows c "SELECT x FROM scalars ORDER BY rowid" Row.(Column (Nullable typ,Empty)) |> List.map ~f:fst in
  assert (List.equal (Option.equal equal) actual expected)
let floats a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Stdlib.Int64.bits_of_float a) (Stdlib.Int64.bits_of_float b)
type _ Stdlib.Effect.t += Pause : unit Stdlib.Effect.t
let () =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
    scalar c Bool [false;true] Bool.equal;
    scalar c Int8 [-128;127] Int.equal; scalar c Int16 [-32768;32767] Int.equal;
    scalar c Int32 [Int32.min_value;Int32.max_value] Int32.equal;
    scalar c Int64 [Int64.min_value;9007199254740993L;Int64.max_value] Int64.equal;
    scalar c Float32 [0.;-0.;Scalar.round_float32 0.1;Float.infinity;Float.neg_infinity;Float.nan] floats;
    scalar c Float64 [0.;-0.;0.1;Float.infinity;Float.neg_infinity;Float.nan] floats;
    scalar c String ["";"quote'\000text";String.make 100000 'z'] String.equal;
    scalar c Blob ["";"\000\255\128binary";String.make 100000 '\255'] String.equal;
    scalar c Date [Int32.min_value;Int32.max_value;-1l;0l] Int32.equal;
    List.iter [Scalar.Timestamp_s;Timestamp_ms;Timestamp_us;Timestamp_ns;Timestamp_tz] ~f:(fun typ ->
      scalar c typ [Int64.min_value;Int64.max_value;-1L;0L;1000000001L] Int64.equal);
    ok (execute c "CREATE TABLE a(x BIGINT NOT NULL UNIQUE)");
    let escaped = ref None in
    ok (with_appender c "a" ~f:(fun a ->
      escaped := Some a;
      assert (Result.is_error (close_connection c));
      assert (Result.is_error (execute c "ALTER TABLE a ALTER x TYPE DOUBLE"));
      append_rows a [[Cell (Required Int64,9007199254740993L)]]));
    let a = Option.value_exn !escaped in
    assert (match append_rows a [] with Error Closed -> true | _ -> false);
    ok (close_appender a); assert (Int64.equal (count c "a") 1L);
    ok (execute c "DELETE FROM a");
    let invalid cases = List.iter cases ~f:(fun cells ->
      let result = with_appender c "a" ~f:(fun a ->
        ok (append_rows a [[Cell (Required Int64,42L)]]);
        let first = error (append_rows a [[Cell (Required Int64,43L)];cells]) in
        let second = error (flush_appender a) in
        assert (phys_equal first second); Ok ()) in
      ignore (error result); assert (Int64.equal (count c "a") 0L)) in
    invalid [[];[Cell (Required Int64,1L);Cell (Required Int64,2L)];
      [Cell (Required Float64,1.)];[Cell (Nullable Int64,None)]];
    ok (execute c "CREATE TABLE narrow(x TINYINT)");
    ignore (error (with_appender c "narrow" ~f:(fun a -> append_rows a [[Cell (Required Int8,128)]])));
    ok (execute c "CREATE TABLE fp(x FLOAT)");
    ignore (error (with_appender c "fp" ~f:(fun a -> append_rows a [[Cell (Required Float32,0.1)]])));
    ignore (error (with_appender c "a" ~f:(fun a ->
      ok (append_rows a [[Cell (Required Int64,1L)];[Cell (Required Int64,1L)]]);
      let first = error (flush_appender a) in
      assert (String.is_substring (message first) ~substring:"PRIMARY KEY or UNIQUE");
      ignore (error (close_appender a)); Ok ())));
    assert (Int64.equal (count c "a") 0L);
    (* An entire large batch is admitted once, and automatic flush errors are
       reported by append_rows, not deferred until explicit flush/close. *)
    let large = List.init 220000 ~f:(fun i -> [Cell (Required Int64,Int64.of_int i)]) in
    ok (with_appender c "a" ~f:(fun a -> append_rows a large));
    assert (Int64.equal (count c "a") 220000L); ok (execute c "DELETE FROM a");
    ignore (error (with_appender c "a" ~f:(fun a ->
      let duplicate = List.init 220000 ~f:(fun _ -> [Cell (Required Int64,1L)]) in
      ignore (error (append_rows a duplicate)); Ok ())));
    assert (Int64.equal (count c "a") 0L);
    let primary = Native_error "callback primary" in
    assert (phys_equal (error (with_appender c "a" ~f:(fun a ->
      ok (append_rows a [[Cell (Required Int64,1L)]]); ok (flush_appender a); Error primary))) primary);
    assert (Int64.equal (count c "a") 0L);
    (try ignore (with_appender c "a" ~f:(fun a -> ok (append_rows a [[Cell (Required Int64,1L)]]); raise Stdlib.Exit)); assert false with Stdlib.Exit -> ());
    assert (Int64.equal (count c "a") 0L);
    ignore (error (with_transaction c ~f:(fun tx ->
      let a = ok (open_appender tx "a") in
      ok (append_rows a [[Cell (Required Int64,2L)]]); Ok ())));
    assert (Int64.equal (count c "a") 0L);
    ok (with_transaction c ~f:(fun tx ->
      let a = ok (open_appender tx "a") in
      assert (match execute_transaction tx "SELECT 1" with Error Busy -> true | _ -> false);
      ok (append_rows a [[Cell (Required Int64,3L)]]);
      ok (close_appender a); execute_transaction tx "INSERT INTO a VALUES (4)"));
    assert (Int64.equal (count c "a") 2L);
    ignore (error (with_transaction c ~f:(fun tx ->
      ok (with_appender_transaction tx "a" ~f:(fun a -> append_rows a [[Cell (Required Int64,5L)]])); Error primary)));
    assert (Int64.equal (count c "a") 2L);
    ok (execute c "CREATE SCHEMA \"s' quoted\";" );
    ok (execute c "CREATE TABLE \"s' quoted\".\"t\"\"; DROP TABLE a;--\"(x BIGINT)");
    ok (with_appender c ~schema:"s' quoted" "t\"; DROP TABLE a;--" ~f:(fun a -> append_rows a [[Cell (Required Int64,7L)]]));
    ignore (error (with_appender c "missing" ~f:(fun _ -> Ok ())));
    ignore (error (with_appender c "bad\000name" ~f:(fun _ -> Ok ())));
    ok (execute c "CREATE TABLE generated(x BIGINT,y BIGINT GENERATED ALWAYS AS (x+1))");
    ignore (error (with_appender c "generated" ~f:(fun _ -> Ok ())));
    assert (Int64.equal (count c "a") 2L);
    List.iter [false;true] ~f:(fun use_effect ->
      ignore (error (with_transaction c ~f:(fun tx ->
        (try ignore (with_appender_transaction tx "a" ~f:(fun a ->
          ok (append_rows a [[Cell (Required Int64,99L)]]);
          ok (close_appender a);
          if use_effect then (try Stdlib.Effect.perform Pause with _ -> ())
          else raise Stdlib.Exit;
          Ok ())) with Stdlib.Exit -> ());
        Ok ())));
      assert (Int64.equal (count c "a") 2L));
    Ok ())));
  assert (Duckdb_ffi.live_resources () = 0);
  assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "appender: scalar fidelity, validation, batches, constraints, poisoning, transactions, names, aliases and cleanup passed"
