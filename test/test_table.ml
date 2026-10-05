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
let connected f =
  core_ok (D.with_database (core_ok (D.Config.create Memory)) ~f:(fun db -> D.with_connection db ~f:(fun c -> f c; Ok ())));
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
      let* () = T.append a [D.Args.[1L; Some "one"]; D.Args.[2L; None]] in
      T.flush a));
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
