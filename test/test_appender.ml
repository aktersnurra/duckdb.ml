open! Base
open Duckdb
let rec message (e : Error.t) = match e.cause with
  | Native s -> s
  | Rollback_failed { primary; rollback } -> message primary ^ "; rollback: " ^ message rollback
  | Type_mismatch {index;expected;actual} -> Stdlib.Printf.sprintf "column %d expected %s actual %s" index expected actual
  | _ -> "structured error"
let ok = function Ok x -> x | Error e -> failwith (message e)
let error = function Error e -> e | Ok _ -> failwith "expected error"
let rows c sql fields ~row =
  match Request.Connection.collect c (Request.many ~oneshot:true Fields.[] fields ~row sql) Args.[] with
  | Ok values -> values
  | Error _ -> failwith "typed request failed"
let count c table = match rows c ("SELECT count(*) FROM " ^ table) Fields.[int64] ~row:Fn.id with
  | [n] -> n | _ -> assert false
let scalar : type a. connection -> a Scalar.t -> a list -> (a -> a -> bool) -> unit = fun c typ values equal ->
  ok (execute c ("CREATE OR REPLACE TABLE scalars(x " ^ Scalar.name typ ^ ")"));
  let expected = None :: List.map values ~f:Option.some in
  let table = Table.(declare "scalars" Columns.[ "x", nullable (of_scalar typ) ] ~row:Fn.id) in
  ok (Table.with_appender c table ~f:(fun a ->
    ok (Table.append a []);
    Table.append a (List.map expected ~f:(fun x -> Args.[x]))));
  let actual = rows c "SELECT x FROM scalars ORDER BY rowid" Fields.[nullable (of_scalar typ)] ~row:Fn.id in
  assert (List.equal (Option.equal equal) actual expected)
let floats a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Stdlib.Int64.bits_of_float a) (Stdlib.Int64.bits_of_float b)
let floats32 a b = floats (Stdlib_stable.Float32.to_float a) (Stdlib_stable.Float32.to_float b)
type _ Stdlib.Effect.t += Pause : unit Stdlib.Effect.t
let metadata_boundaries c =
  (* The pinned engine's metadata chunks contain up to 2048 rows. A generated
     column first used to shift nullability when 2048 physical columns followed.
     Declared tables name only c0 (nullable, so NULL reaches the engine's NOT
     NULL metadata); the other physical columns take their NULL defaults. *)
  let create table physical ~generated =
    let columns = List.init physical ~f:(fun i ->
      Stdlib.Printf.sprintf "c%d BIGINT%s" i (if i = 0 then " NOT NULL" else " DEFAULT NULL")) in
    let columns = if generated then "g BIGINT GENERATED ALWAYS AS (c0+1)" :: columns else columns in
    ok (execute c ("CREATE TABLE " ^ table ^ "(" ^ String.concat ~sep:"," columns ^ ")")) in
  let declared table = Table.(declare table Columns.[ "c0", nullable int64 ] ~row:Fn.id) in
  (* Warm the connection's statement cache (catalog query) before the baseline. *)
  ok (execute c "CREATE TABLE metadata_warmup(c0 BIGINT)");
  ok (Table.with_appender c (declared "metadata_warmup") ~f:(fun _ -> Ok ()));
  let baseline = Duckdb_ffi.live_resources () in
  let clean () =
    assert (Duckdb_ffi.live_resources () = baseline);
    assert (Duckdb_ffi.fallback_reclaims () = 0) in
  List.iter [2;2048] ~f:(fun physical ->
    let table = "metadata_plain_" ^ Int.to_string physical in
    create table physical ~generated:false;
    ok (Table.with_appender c (declared table) ~f:(fun a -> Table.append a [Args.[Some 42L]]));
    assert (Int64.equal (count c table) 1L);
    assert (match rows c ("SELECT c0,c1 FROM " ^ table)
      Fields.[int64; nullable int64] ~row:(fun a b -> a, b) with
      | [42L, None] -> true | _ -> false);
    let first = ref None in
    let result = Table.with_appender c (declared table) ~f:(fun a ->
      ok (Table.append a [Args.[Some 42L]]);
      let e = error (Table.append a [Args.[None]]) in
      assert (match e.cause with Null {column=0;row=0} -> true | _ -> false);
      assert (phys_equal e.cause (error (Table.flush a)).cause);
      first := Some e; Ok ()) in
    (* The scope's close reports the first error. *)
    assert (phys_equal (error result).cause (Option.value_exn !first).cause);
    assert (Int64.equal (count c table) 1L); clean ());
  ok (execute c "CREATE TABLE metadata_marker(x BIGINT)");
  let opens tx name table = error (Table.with_appender_transaction tx table ~f:(fun _ ->
    failwith ("metadata schema accepted before exhaustion: " ^ name))) in
  List.iter ["metadata_generated_boundary",2048,true;
             "metadata_generated_small",2,true;
             "metadata_oversized",2049,false;
             "metadata_three_chunks",4097,false] ~f:(fun (table,physical,generated) ->
    create table physical ~generated;
    let first = ref None in
    let result = with_transaction c ~f:(fun tx ->
      ok (execute_transaction tx "INSERT INTO metadata_marker VALUES (1)");
      (* Generated columns are declared so the catalog check passes and the
         appender's own metadata rejection is reached. *)
      let e = if generated
        then opens tx table Table.(declare table Columns.[ "c0", nullable int64; "g", nullable int64 ] ~row:(fun _ _ -> ()))
        else opens tx table (declared table) in
      assert (match e.cause with Native s -> String.equal s
        "Generated-column or very wide tables are not supported by appender" | _ -> false);
      first := Some e;
      (* Ignoring failed creation must still poison settlement and undo prior SQL. *)
      Ok ()) in
    assert (phys_equal (error result).cause (Option.value_exn !first).cause);
    assert (Int64.equal (count c "metadata_marker") 0L);
    assert (Int64.equal (count c table) 0L); clean ());
  Stdlib.print_endline "appender metadata: single/exact-chunk acceptance, generated/oversized rejection, poisoning and cleanup passed"
let () =
  ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
    metadata_boundaries c;
    scalar c Bool [false;true] Bool.equal;
    scalar c Int8 [-128s;127s] Stdlib_stable.Int8.equal; scalar c Int16 [-32768S;32767S] Stdlib_stable.Int16.equal;
    scalar c Int32 [Int32.min_value;Int32.max_value] Int32.equal;
    scalar c Int64 [Int64.min_value;9007199254740993L;Int64.max_value] Int64.equal;
    scalar c Float32 [0.s; -0.s; 0.1s; Stdlib_stable.Float32.infinity; Stdlib_stable.Float32.neg_infinity; Stdlib_stable.Float32.nan] floats32;
    scalar c Float64 [0.;-0.;0.1;Float.infinity;Float.neg_infinity;Float.nan] floats;
    scalar c String ["";"quote'\000text";String.make 100000 'z'] String.equal;
    scalar c Blob ["";"\000\255\128binary";String.make 100000 '\255'] String.equal;
    scalar c Date [Int32.min_value;Int32.max_value;-1l;0l] Int32.equal;
    List.iter [Scalar.Timestamp_s;Timestamp_ms;Timestamp_us;Timestamp_ns;Timestamp_tz] ~f:(fun typ ->
      scalar c typ [Int64.min_value;Int64.max_value;-1L;0L;1000000001L] Int64.equal);
    ok (execute c "CREATE TABLE a(x BIGINT NOT NULL UNIQUE)");
    let t = Table.(declare "a" Columns.[ "x", int64 ] ~row:Fn.id) in
    (* Nullable, so NULL reaches the engine's NOT NULL metadata. *)
    let nullable_t = Table.(declare "a" Columns.[ "x", nullable int64 ] ~row:Fn.id) in
    ok (Table.with_appender c t ~f:(fun a ->
      assert (Result.is_error (close_connection c));
      assert (Result.is_error (execute c "ALTER TABLE a ALTER x TYPE DOUBLE"));
      Table.append a [Args.[9007199254740993L]]));
    assert (Int64.equal (count c "a") 1L);
    ok (execute c "DELETE FROM a");
    (* Wrong arity/witness rows are static errors (request_compile append_arity,
       append_type); a NULL in a NOT NULL column is checked per batch. *)
    let result = Table.with_appender c nullable_t ~f:(fun a ->
      ok (Table.append a [Args.[Some 42L]]);
      let first = error (Table.append a [Args.[Some 43L]; Args.[None]]) in
      assert (match first.cause with Null {column=0;row=1} -> true | _ -> false);
      let second = error (Table.flush a) in
      assert (phys_equal first.cause second.cause); Ok ()) in
    ignore (error result); assert (Int64.equal (count c "a") 0L);
    (* A declared codec that disagrees with the catalog type fails at open. *)
    assert (match Table.with_appender c Table.(declare "a" Columns.[ "x", float64 ] ~row:Fn.id)
      ~f:(fun _ -> failwith "mismatched declaration accepted") with
      | Error { cause = Type_mismatch _; _ } -> true | _ -> false);
    ignore (error (Table.with_appender c t ~f:(fun a ->
      ok (Table.append a [Args.[1L]; Args.[1L]]);
      let first = error (Table.flush a) in
      assert (String.is_substring (message first) ~substring:"PRIMARY KEY or UNIQUE");
      Ok ())));
    assert (Int64.equal (count c "a") 0L);
    (* An entire large batch is admitted once, and automatic flush errors are
       reported by append, not deferred until explicit flush/close. *)
    let large = List.init 220000 ~f:(fun i -> Args.[Int64.of_int i]) in
    ok (Table.with_appender c t ~f:(fun a -> Table.append a large));
    assert (Int64.equal (count c "a") 220000L); ok (execute c "DELETE FROM a");
    ignore (error (Table.with_appender c t ~f:(fun a ->
      let duplicate = List.init 220000 ~f:(fun _ -> Args.[1L]) in
      ignore (error (Table.append a duplicate)); Ok ())));
    assert (Int64.equal (count c "a") 0L);
    let primary = { Error.context = Transaction; cause = Native "callback primary" } in
    assert (phys_equal (error (Table.with_appender c t ~f:(fun a ->
      ok (Table.append a [Args.[1L]]); ok (Table.flush a); Error primary))) primary);
    assert (Int64.equal (count c "a") 0L);
    (try ignore (Table.with_appender c t ~f:(fun a -> ok (Table.append a [Args.[1L]]); raise Stdlib.Exit)); assert false with Stdlib.Exit -> ());
    assert (Int64.equal (count c "a") 0L);
    ok (with_transaction c ~f:(fun tx ->
      ok (Table.with_appender_transaction tx t ~f:(fun a ->
        assert (match execute_transaction tx "SELECT 1" with Error { cause = Busy; _ } -> true | _ -> false);
        Table.append a [Args.[3L]]));
      execute_transaction tx "INSERT INTO a VALUES (4)"));
    assert (Int64.equal (count c "a") 2L);
    ignore (error (with_transaction c ~f:(fun tx ->
      ok (Table.with_appender_transaction tx t ~f:(fun a -> Table.append a [Args.[5L]])); Error { context = Transaction; cause = Native "callback primary" })));
    assert (Int64.equal (count c "a") 2L);
    ok (execute c "CREATE SCHEMA \"s' quoted\";" );
    ok (execute c "CREATE TABLE \"s' quoted\".\"t\"\"; DROP TABLE a;--\"(x BIGINT)");
    ok (Table.with_appender c Table.(declare ~schema:"s' quoted" "t\"; DROP TABLE a;--" Columns.[ "x", int64 ] ~row:Fn.id)
      ~f:(fun a -> Table.append a [Args.[7L]]));
    let bigints name = Table.(declare name Columns.[ "x", int64 ] ~row:Fn.id) in
    ignore (error (Table.with_appender c (bigints "missing") ~f:(fun _ -> Ok ())));
    ignore (error (Table.with_appender c (bigints "bad\000name") ~f:(fun _ -> Ok ())));
    ok (execute c "CREATE TABLE generated(x BIGINT,y BIGINT GENERATED ALWAYS AS (x+1))");
    ignore (error (Table.with_appender c Table.(declare "generated" Columns.[ "x", int64; "y", int64 ] ~row:(fun _ _ -> ()))
      ~f:(fun _ -> Ok ())));
    assert (Int64.equal (count c "a") 2L);
    List.iter [false;true] ~f:(fun use_effect ->
      ignore (error (with_transaction c ~f:(fun tx ->
        (try ignore (Table.with_appender_transaction tx t ~f:(fun a ->
          ok (Table.append a [Args.[99L]]);
          if use_effect then (try Stdlib.Effect.perform Pause with _ -> ())
          else raise Stdlib.Exit;
          Ok ())) with Stdlib.Exit -> ());
        Ok ())));
      assert (Int64.equal (count c "a") 2L));
    Ok ())));
  assert (Duckdb_ffi.live_resources () = 0);
  assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "appender: scalar fidelity, validation, batches, constraints, poisoning, transactions, names, aliases and cleanup passed"
