open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
let ( let* ) x f = Result.bind x ~f
let core_ok = function Ok x -> x | Error { D.Error.cause = Native s; _ } -> failwith s | Error _ -> failwith "unexpected core error"
let rec describe (e : D.Error.t) = match e.cause with
  | Native s -> "Native: " ^ s
  | Parameter_count _ -> "Parameter_count" | Row_count _ -> "Row_count"
  | Unknown_column { name } -> "Unknown_column " ^ name | Missing_column { name } -> "Missing_column " ^ name
  | Encode_rejected _ -> "Encode_rejected" | Decode_rejected _ -> "Decode_rejected"
  | Rollback_failed { primary; _ } -> "Rollback_failed: " ^ describe primary
  | _ -> "other cause"
let ok = function Ok x -> x | Error e -> failwith ("unexpected request error: " ^ describe e)
let failed name predicate = function
  | Error (e : D.Error.t) when predicate e -> e
  | Error e -> failwith (name ^ ": unexpected " ^ describe e)
  | Ok _ -> failwith (name ^ ": unexpected success")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
(* Owned handles are global: callbacks may capture them. *)
let connected f =
  let db = core_ok (D.Owned.open_database (core_ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = core_ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])
let count c table = ok (R.Session.find c (R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id ("SELECT count(*)::BIGINT FROM " ^ table)) D.Args.[])

type note = { value : int64; note : string option }
let equal_note a b = Int64.equal a.value b.value && Option.equal String.equal a.note b.note
let notes = T.(declare "notes" Columns.[ "value", int64; "note", nullable string ] ~row:(fun value note -> { value; note }))
let read c = ok (R.Session.collect c (T.select notes) D.Args.[])

(* Typed appender, select and insert over a declared table. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)";
    ok (T.with_appender c notes ~f:(fun a ->
      match T.append a [D.Args.[1L; Some "one"]; D.Args.[2L; None]] with
      | Error _ as e -> e
      | Ok () -> T.flush a));
    ok (R.Session.exec c (T.insert notes) D.Args.[3L; Some "three"]);
    assert (List.equal equal_note (read c)
      [ { value = 1L; note = Some "one" }; { value = 2L; note = None }; { value = 3L; note = Some "three" } ]));
  Stdlib.print_endline "table: typed appender, flush, select and insert of declared columns=ok"

(* R7: columns match by name in any order; unknown names are rejected before any row. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE notes(note VARCHAR, value BIGINT NOT NULL)";
    ok (T.with_appender c notes ~f:(fun a -> T.append a [D.Args.[1L; Some "one"]]));
    assert (List.equal equal_note (read c) [ { value = 1L; note = Some "one" } ]);
    let typo = T.(declare "notes" Columns.[ "valu", int64 ] ~row:Fn.id) in
    ignore (failed "unknown column" (fun e -> match e.cause with
      | D.Error.Unknown_column { name = "valu" } -> true | _ -> false)
      (T.with_appender c typo ~f:(fun a -> T.append a [D.Args.[2L]])));
    assert (Int64.equal (count c "notes") 1L));
  Stdlib.print_endline "table: reordered catalog columns by name, Unknown_column before append=ok"

(* R9: omitted columns need a default. *)
let () =
  connected (fun c ->
    ddl c "CREATE SEQUENCE ids START 100";
    ddl c "CREATE TABLE events(id BIGINT DEFAULT nextval('ids'), kind VARCHAR NOT NULL, extra VARCHAR)";
    let kinds = T.(declare "events" Columns.[ "kind", string ] ~row:Fn.id) in
    ignore (failed "missing column" (fun e -> match e.cause with
      | D.Error.Missing_column { name = "extra" } -> true | _ -> false)
      (T.with_appender c kinds ~f:(fun a -> T.append a [D.Args.["x"]])));
    ddl c "ALTER TABLE events ALTER extra SET DEFAULT 'none'";
    ok (T.with_appender c kinds ~f:(fun a -> T.append a [D.Args.["login"]; D.Args.["logout"]]));
    ok (R.Session.exec c (T.insert kinds) D.Args.["audit"]);
    let ids = ok (R.Session.collect c (R.many D.Fields.[] D.Fields.[int64; string] ~row:(fun i e -> (i, e))
      "SELECT id, extra FROM events ORDER BY id") D.Args.[]) in
    assert (List.equal Poly.equal ids [ 100L, "none"; 101L, "none"; 102L, "none" ]));
  Stdlib.print_endline "table: Missing_column without default; defaults applied for omitted columns=ok"

(* R8 and NOT NULL: declared types and NULLs are checked against the catalog. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE notes(value INTEGER NOT NULL, note VARCHAR)";
    ignore (failed "type mismatch" (fun e -> match e.cause with
      | D.Error.Type_mismatch _ -> true | _ -> false)
      (T.with_appender c notes ~f:(fun a -> T.append a [D.Args.[1L; None]])));
    ddl c "DROP TABLE notes";
    ddl c "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)";
    let nullable_value = T.(declare "notes" Columns.[ "value", nullable int64; "note", nullable string ]
      ~row:(fun v n -> (v, n))) in
    ignore (failed "not null" (fun e -> match e.cause with
      | D.Error.Null _ -> true | _ -> false)
      (T.with_appender c nullable_value ~f:(fun a -> T.append a [D.Args.[None; None]])));
    assert (Int64.equal (count c "notes") 0L));
  Stdlib.print_endline "table: catalog type mismatch at open, NOT NULL per row=ok"

(* Codec rejections reject the batch before any native row; callback errors roll back. *)
let () =
  let positive = D.Codec.Values.custom D.Codec.Values.int64
    ~encode:(fun n -> if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive") ~decode:Or_error.return in
  let checked = T.(declare "notes" Columns.[ "value", positive ] ~row:Fn.id) in
  connected (fun c ->
    (* An explicit DEFAULT NULL lets a declaration omit the nullable column. *)
    ddl c "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR DEFAULT NULL)";
    ok (T.with_appender c checked ~f:(fun a ->
      ignore (failed "encode" (fun e -> match e.cause with
        | D.Error.Encode_rejected { index = 1; _ } -> true | _ -> false) (T.append a [D.Args.[5L]; D.Args.[-1L]]));
      T.append a [D.Args.[6L]]));
    assert (Int64.equal (count c "notes") 1L);
    ignore (failed "callback error" (fun e -> match e.cause with D.Error.Row_count _ -> true | _ -> false)
      (T.with_appender c notes ~f:(fun a ->
        let* () = T.append a [D.Args.[7L; None]] in
        Error { D.Error.context = Query "callback"; cause = Row_count { expected = `One; actual = `Zero } })));
    assert (Int64.equal (count c "notes") 1L);
    ok (R.Session.with_transaction c ~f:(fun tx -> T.with_appender tx notes ~f:(fun a -> T.append a [D.Args.[8L; None]])));
    assert (Int64.equal (count c "notes") 2L));
  Stdlib.print_endline "table: codec rejection before native rows, callback error rolls back, transaction scope=ok"

(* Connection.ingest runs a whole typed appender transaction. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)";
    ok (R.Session.ingest c notes [ [D.Args.[1L; None]]; [D.Args.[2L; Some "b"]; D.Args.[3L; None]] ] ~flush:true);
    assert (Int64.equal (count c "notes") 3L));
  Stdlib.print_endline "table: Connection.ingest batches with explicit flush=ok"

(* Parquet decoding through fields or a declared table. *)
let () =
  let file = Stdlib.Filename.temp_file "duckdb-table-" ".parquet" in
  Stdlib.Sys.remove file;
  Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file) ~f:(fun () ->
    connected (fun c ->
      ddl c "CREATE TABLE notes(value BIGINT NOT NULL, note VARCHAR)";
      ok (R.Session.ingest c notes [ [D.Args.[1L; Some "a"]; D.Args.[2L; None]] ] ~flush:false);
      let path = core_ok (D.Parquet.path file) in
      core_ok (D.Parquet.export c ~query:"SELECT value, note FROM notes ORDER BY value" path);
      let table_rows = ok (D.Parquet.fold_table c [path] notes ~init:[] ~f:(fun r rs -> Ok (D.Continue (r :: rs)))) in
      assert (List.equal equal_note (List.rev table_rows) [ { value = 1L; note = Some "a" }; { value = 2L; note = None } ]);
      let values = ok (D.Parquet.fold c [path; path] D.Fields.[int64; nullable string] ~row:(fun v _ -> v)
        ~init:[] ~f:(fun v vs -> Ok (D.Continue (v :: vs)))) in
      assert (List.equal Int64.equal values [2L; 1L; 2L; 1L]);
      (* Stop in the first file: the second file is never read. *)
      let calls = ref 0 in
      let stopped = ok (D.Parquet.fold c [path; path] D.Fields.[int64; nullable string] ~row:(fun v _ -> v)
        ~init:0 ~f:(fun _ n -> Int.incr calls; Ok (if n = 1 then D.Stop n else D.Continue (n + 1)))) in
      assert (stopped = 1 && !calls = 2);
      ignore (failed "empty path list" (fun e -> match e.cause with
        | D.Error.Invalid_configuration _ -> true | _ -> false)
        (D.Parquet.fold c [] D.Fields.[int64] ~row:Fn.id ~init:() ~f:(fun _ () -> Ok (D.Continue ()))));
      ignore (failed "wrong file shape" (fun e -> match e.cause with
        | D.Error.Column_count _ -> true | _ -> false)
        (D.Parquet.fold c [path] D.Fields.[int64] ~row:Fn.id ~init:() ~f:(fun _ () -> Ok (D.Continue ()))))));
  Stdlib.print_endline "table: Parquet fold/fold_table across files, Stop, empty list, file shape=ok"

(* Columns and Fields share one structure: a table's columns decode the
   same rows as the equivalent Fields list. *)
let () =
  let module T = Duckdb.Table in
  let t = T.declare "s" T.Columns.["a", int64; "b", nullable string] ~row:(fun a b -> (a, b)) in
  assert (String.equal (Duckdb.Request.query (T.select t)) "SELECT \"a\", \"b\" FROM \"main\".\"s\"");
  Stdlib.print_endline "table: spine-backed columns render=ok"

(* A batch larger than one native chunk lands whole and in order. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE big(a BIGINT, b VARCHAR, f DOUBLE, d DATE)";
    let big = T.(declare "big" Columns.["a", int64; "b", nullable string; "f", float64; "d", date]
      ~row:(fun a b f d -> (a, b, f, d))) in
    let rows = List.init 5000 ~f:(fun i ->
      D.Args.[Int64.of_int i; (if i % 3 = 0 then None else Some (Int.to_string i)); Float.of_int i; Int32.of_int_exn i]) in
    ok (T.with_appender c big ~f:(fun a -> T.append a rows));
    let back = ok (R.Session.collect c
      (R.many D.Fields.[] D.Fields.[int64; nullable string; float64; date] ~row:(fun a b f d -> (a, b, f, d))
         "SELECT a, b, f, d FROM big ORDER BY a") D.Args.[]) in
    assert (List.length back = 5000);
    List.iteri back ~f:(fun i (a, b, f, d) ->
      assert (Int64.equal a (Int64.of_int i));
      assert (Option.equal String.equal b (if i % 3 = 0 then None else Some (Int.to_string i)));
      assert (Float.equal f (Float.of_int i) && Int32.equal d (Int32.of_int_exn i))));
  Stdlib.print_endline "table: a 5000-row batch lands whole and in order=ok"

(* A codec rejection in the last row leaves the table untouched and does not
   poison the appender; it wins over a NULL in a NOT NULL column earlier. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE strict(a BIGINT NOT NULL, b BIGINT)";
    let positive = D.Codec.Values.custom ~encode:(fun (n : int64) ->
      if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive") ~decode:Or_error.return D.Codec.Values.int64 in
    let strict = T.(declare "strict" Columns.["a", nullable int64; "b", positive] ~row:(fun a b -> (a, b))) in
    let outcome = T.with_appender c strict ~f:(fun a ->
      (match T.append a [ D.Args.[None; 1L]; D.Args.[Some 1L; 1L]; D.Args.[Some 2L; 0L] ] with
       | Error { cause = D.Error.Encode_rejected { index = 2; _ }; _ } -> ()
       | Error e -> failwith ("expected Encode_rejected at the second column, got " ^ describe e)
       | Ok () -> failwith "expected Encode_rejected at the second column");
      T.append a [ D.Args.[Some 3L; 3L] ]) in
    ok outcome;
    assert (Int64.equal (count c "strict") 1L));
  Stdlib.print_endline "table: codec rejection is atomic, unpoisoning and precedes NULL=ok"

(* Invalid UTF-8 in a VARCHAR value fails the batch and poisons the appender
   (DuckDB would silently store NULL); nothing reaches the table. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE texts(s VARCHAR)";
    let texts = T.(declare "texts" Columns.["s", nullable string] ~row:Fn.id) in
    let first = ref None in
    let outcome = T.with_appender c texts ~f:(fun a ->
      let e = failed "invalid UTF-8" (fun e -> match e.cause with D.Error.Native _ -> true | _ -> false)
        (T.append a [ D.Args.[Some "ok"]; D.Args.[Some "\xff\xfe"] ]) in
      first := Some e;
      let again = failed "poisoned appender" (fun _ -> true) (T.append a [ D.Args.[Some "later"] ]) in
      (match e.cause, again.cause with
       | D.Error.Native first, D.Error.Native later -> assert (String.equal first later)
       | _ -> assert false);
      Ok ()) in
    ignore (failed "poisoned scope" (fun _ -> true) outcome);
    assert (Option.is_some !first);
    assert (Int64.equal (count c "texts") 0L));
  Stdlib.print_endline "table: invalid UTF-8 VARCHAR fails the batch and poisons=ok"

(* Invalid UTF-8 staged before a later codec rejection in the same batch is
   dropped with it: the rejection does not poison, and a later valid batch
   commits alone. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE mixed(s VARCHAR, n BIGINT)";
    let positive = D.Codec.Values.custom ~encode:(fun (n : int64) ->
      if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive") ~decode:Or_error.return D.Codec.Values.int64 in
    let mixed = T.(declare "mixed" Columns.["s", nullable string; "n", positive] ~row:(fun s n -> (s, n))) in
    ok (T.with_appender c mixed ~f:(fun a ->
      (match T.append a [ D.Args.[Some "\xff\xfe"; 1L]; D.Args.[Some "x"; 0L] ] with
       | Error { cause = D.Error.Encode_rejected { index = 2; _ }; _ } -> ()
       | Error e -> failwith ("expected Encode_rejected, got " ^ describe e)
       | Ok () -> failwith "expected Encode_rejected");
      T.append a [ D.Args.[Some "valid"; 2L] ]));
    assert (Int64.equal (count c "mixed") 1L));
  Stdlib.print_endline "table: codec rejection after invalid UTF-8 does not poison=ok"

(* Staging chunks are reused between batches: a reset clears validity and
   string heaps, and a batch beyond the retained pool (16 chunks) shrinks it
   back without disturbing the next batch. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE reuse(n BIGINT, s VARCHAR)";
    let reuse = T.(declare "reuse" Columns.["n", int64; "s", nullable string] ~row:(fun n s -> (n, s))) in
    let nulls = List.init 2049 ~f:(fun i -> D.Args.[Int64.of_int i; None]) in
    let large = List.init 40000 ~f:(fun i -> D.Args.[Int64.of_int (3000 + i); Some (Int.to_string i)]) in
    ok (T.with_appender c reuse ~f:(fun a ->
      ok (T.append a nulls);
      ok (T.append a [ D.Args.[2049L; Some "a"]; D.Args.[2050L; Some "b"] ]);
      ok (T.append a large);
      T.append a [ D.Args.[2051L; Some "c"]; D.Args.[2052L; None] ]));
    let back = ok (R.Session.collect c
      (R.many D.Fields.[] D.Fields.[int64; nullable string] ~row:(fun n s -> (n, s))
         "SELECT n, s FROM reuse WHERE n < 3000 ORDER BY n") D.Args.[]) in
    assert (List.length back = 2053);
    List.iteri back ~f:(fun i (n, s) ->
      assert (Int64.equal n (Int64.of_int i));
      let expected = match i with 2049 -> Some "a" | 2050 -> Some "b" | 2051 -> Some "c" | _ -> None in
      assert (Option.equal String.equal s expected));
    assert (Int64.equal (count c "reuse") 42053L);
    let large_ok = ok (R.Session.find c (R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT count(*)::BIGINT FROM reuse WHERE n >= 3000 AND s = (n - 3000)::VARCHAR") D.Args.[]) in
    assert (Int64.equal large_ok 40000L));
  Stdlib.print_endline "table: staging reuse resets validity/strings and caps the pool=ok"
