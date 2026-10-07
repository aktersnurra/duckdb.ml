open! Base
module D = Duckdb
module R = D.Request
external prepares : unit -> int = "epoch_test_prepares" [@@noalloc]
let core_ok = function Ok x -> x | Error { D.Error.cause = Native s; _ } -> failwith s | Error _ -> failwith "unexpected core error"
let rec describe (e : D.Error.t) = match e.cause with
  | Native s -> "Native: " ^ s
  | Parameter_count _ -> "Parameter_count" | Row_count _ -> "Row_count"
  | Unknown_column _ -> "Unknown_column" | Missing_column _ -> "Missing_column"
  | Unknown_table _ -> "Unknown_table" | Constraint_mismatch _ -> "Constraint_mismatch"
  | Migration_mismatch _ -> "Migration_mismatch"
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
let connected ?(statement_cache = 64) f =
  let config = core_ok (D.Config.create ~statement_cache Memory) in
  let db = core_ok (D.Owned.open_database config) in
  Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = core_ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let count c table = core_ok (D.Statement.with_prepared c ("SELECT count(*)::BIGINT FROM " ^ table) ~f:(fun p ->
  D.Statement.fold_chunks p ~init:0L ~f:(fun chunk _ ->
    match D.Statement.column chunk ~column:0 ~row:0 D.Codec.Values.int64 with Ok n -> Ok (D.Stop n) | Error e -> Error e)))

let create = R.exec D.Fields.[] "CREATE TABLE t(id BIGINT, note VARCHAR, score DOUBLE)"
let insert = R.exec D.Fields.[int64; nullable string; nullable float64] "INSERT INTO t VALUES (?, ?, ?)"
type row = { id : int64; note : string option; score : float option }
let equal_row a b =
  Int64.equal a.id b.id && Option.equal String.equal a.note b.note && Option.equal Float.equal a.score b.score
let rows = R.many D.Fields.[int64] D.Fields.[int64; nullable string; nullable float64]
  ~row:(fun id note score -> { id; note; score }) "SELECT id, note, score FROM t WHERE id >= ? ORDER BY id"
let by_id = R.one D.Fields.[int64] D.Fields.[nullable string] ~row:Fn.id "SELECT note FROM t WHERE id = ?"
let maybe = R.zero_or_one D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t WHERE id = ?"
let seeded f = connected (fun c ->
  ok (R.Session.exec c create D.Args.[]);
  ok (R.Session.exec c insert D.Args.[1L; Some "one"; Some 1.5]);
  ok (R.Session.exec c insert D.Args.[2L; None; None]);
  f c)

let () =
  seeded (fun c ->
    assert (List.equal equal_row (ok (R.Session.collect c rows D.Args.[0L]))
      [ { id = 1L; note = Some "one"; score = Some 1.5 }; { id = 2L; note = None; score = None } ]);
    assert (Option.equal String.equal (ok (R.Session.find c by_id D.Args.[1L])) (Some "one"));
    assert (Option.is_none (ok (R.Session.find c by_id D.Args.[2L])));
    assert (Option.equal Int64.equal (ok (R.Session.find_opt c maybe D.Args.[2L])) (Some 2L));
    assert (Option.is_none (ok (R.Session.find_opt c maybe D.Args.[9L])));
    assert (ok (R.Session.fold c rows D.Args.[0L] ~init:0 ~f:(fun _ n -> Ok (D.Continue (n + 1)))) = 2);
    assert (ok (R.Session.fold c rows D.Args.[0L] ~init:0 ~f:(fun _ n -> Ok (D.Stop (n + 1)))) = 1));
  Stdlib.print_endline "request: exec/find/find_opt/collect/fold roundtrip, NULLs, Stop=ok"

(* R5/R6: multiplicity is enforced at run time; the result is always closed. *)
let () =
  seeded (fun c ->
    let any = R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let none = R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t WHERE id < 0" in
    let at_most = R.zero_or_one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let row_count expected actual (e : D.Error.t) = match e.cause with
      | D.Error.Row_count r -> Poly.equal r.expected expected && Poly.equal r.actual actual | _ -> false in
    ignore (failed "find many" (row_count `One `More_than_one) (R.Session.find c any D.Args.[]));
    ignore (failed "find none" (row_count `One `Zero) (R.Session.find c none D.Args.[]));
    ignore (failed "find_opt many" (row_count `Zero_or_one `More_than_one) (R.Session.find_opt c at_most D.Args.[]));
    ok (R.Session.exec c insert D.Args.[3L; None; None]));
  Stdlib.print_endline "request: Row_count for find/find_opt, connection reusable=ok"

(* R1-R3: declarations are checked against engine metadata before execution. *)
let () =
  seeded (fun c ->
    let wrong_type = R.exec D.Fields.[string] "INSERT INTO t(id) VALUES (?)" in
    let mismatch (e : D.Error.t) = match e.cause with
      | Type_mismatch _ -> true | _ -> false in
    ignore (failed "parameter type" mismatch (R.Session.exec c wrong_type D.Args.["x"]));
    let too_few = R.exec D.Fields.[int64] "INSERT INTO t(id, note) VALUES (?, ?)" in
    ignore (failed "parameter count" (fun e -> match e.cause with
      | D.Error.Parameter_count { expected = 1; actual = 2 } -> true | _ -> false) (R.Session.exec c too_few D.Args.[5L]));
    let wrong_columns = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id, note FROM t" in
    ignore (failed "column count" (fun e -> match e.cause with
      | Column_count { expected = 1; actual = 2 } -> true | _ -> false)
      (R.Session.collect c wrong_columns D.Args.[]));
    let wrong_column = R.many D.Fields.[] D.Fields.[string] ~row:Fn.id "SELECT id FROM t" in
    ignore (failed "column type" mismatch (R.Session.collect c wrong_column D.Args.[]));
    assert (Int64.equal (count c "t") 2L));
  Stdlib.print_endline "request: parameter type/count and column count/type rejected before execution=ok"

(* R10/R11: custom codecs; failures are named and positioned. *)
let () =
  let positive = D.Codec.Values.custom D.Codec.Values.int64
    ~encode:(fun n -> if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive")
    ~decode:(fun n -> if Int64.(n > 0L) then Ok n else Or_error.error_string "stored not positive") in
  seeded (fun c ->
    let insert_positive = R.exec D.Fields.[positive] "INSERT INTO t(id) VALUES (?)" in
    ok (R.Session.exec c insert_positive D.Args.[7L]);
    ignore (failed "encode" (fun e -> match e.cause with
      | D.Error.Encode_rejected { index = 1; reason } -> String.equal (Error.to_string_hum reason) "not positive"
      | _ -> false) (R.Session.exec c insert_positive D.Args.[-1L]));
    assert (Int64.equal (count c "t") 3L);
    ok (R.Session.exec c (R.exec D.Fields.[] "INSERT INTO t(id) VALUES (-5)") D.Args.[]);
    let read_positive = R.many D.Fields.[] D.Fields.[int64; positive] ~row:(fun a b -> (a, b))
      "SELECT 0::BIGINT, id FROM t ORDER BY id" in
    ignore (failed "decode" (fun e -> match e.cause with
      | D.Error.Decode_rejected { column = 1; row = 0; _ } -> true | _ -> false) (R.Session.collect c read_positive D.Args.[])));
  Stdlib.print_endline "request: custom codec encode/decode rejection with positions=ok"

(* R13: every error names its SQL. *)
let () =
  seeded (fun c ->
    let sql = "SELECT missing FROM t" in
    let e = failed "native" (fun _ -> true) (R.Session.collect c (R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id sql) D.Args.[]) in
    assert (match e.context with D.Error.Query q -> String.equal q sql | _ -> false));
  Stdlib.print_endline "request: errors carry query context=ok"

(* R12: statement cache. *)
let () =
  seeded (fun c ->
    ignore (ok (R.Session.collect c rows D.Args.[0L]));
    let start = prepares () in
    for _ = 1 to 5 do ignore (ok (R.Session.collect c rows D.Args.[0L])) done;
    Stdlib.Printf.printf "request: prepares for five cached executions=%d\n%!" (prepares () - start);
    assert (prepares () = start);
    let oneshot = R.many ~oneshot:true D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t WHERE id >= ?" in
    let start = prepares () in
    for _ = 1 to 3 do ignore (ok (R.Session.collect c oneshot D.Args.[0L])) done;
    assert (prepares () = start + 3));
  connected ~statement_cache:1 (fun c ->
    ok (R.Session.exec c create D.Args.[]);
    let a = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let b = R.many D.Fields.[] D.Fields.[nullable string] ~row:Fn.id "SELECT note FROM t" in
    ignore (ok (R.Session.collect c a D.Args.[]));
    let start = prepares () in
    ignore (ok (R.Session.collect c b D.Args.[])); ignore (ok (R.Session.collect c a D.Args.[]));
    assert (prepares () = start + 2));
  connected ~statement_cache:0 (fun c ->
    ok (R.Session.exec c create D.Args.[]);
    let a = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    ignore (ok (R.Session.collect c a D.Args.[]));
    let start = prepares () in
    ignore (ok (R.Session.collect c a D.Args.[]));
    assert (prepares () = start + 1));
  (match D.Config.create ~statement_cache:(-1) Memory with
   | Error { cause = Invalid_configuration _; _ } -> () | _ -> failwith "negative statement cache accepted");
  (* Cached statements are not live children: manual close and Bridge succeed. *)
  let config = core_ok (D.Config.create Memory) in
  let db = core_ok (D.Owned.open_database config) in
  Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = core_ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_connection c)) ~f:(fun () ->
      ok (R.Session.exec c create D.Args.[]);
      ignore (ok (R.Session.collect c rows D.Args.[0L]));
      (* Manual close succeeds with cached statements (finally then repeats it). *)
      core_ok (D.Bridge.run (D.Bridge.request (D.Bridge.canceller ())) c ~f:(fun facade -> D.execute facade "SELECT 1"));
      core_ok (D.Owned.close_connection c)));
  clean ();
  Stdlib.print_endline "request: cache hit/oneshot/LRU/disabled/negative config/close and Bridge with cached statements=ok"

(* Transactions: cached statements are lent; errors roll back; schema change in tx detected. *)
let () =
  seeded (fun c ->
    ignore (ok (R.Session.collect c rows D.Args.[0L]));
    let in_tx = ok (R.Session.with_transaction c ~f:(fun tx ->
      match R.Session.exec tx insert D.Args.[3L; Some "three"; None] with Error e -> Error e | Ok () ->
      R.Session.collect tx rows D.Args.[3L])) in
    assert (List.length in_tx = 1);
    let rolled = R.Session.with_transaction c ~f:(fun tx ->
      match R.Session.exec tx insert D.Args.[4L; None; None] with Error e -> Error e | Ok () ->
      R.Session.find tx by_id D.Args.[999L]) in
    ignore (failed "rollback on request error" (fun e -> match e.cause with D.Error.Row_count _ -> true | _ -> false) rolled);
    assert (Int64.equal (count c "t") 3L);
    let changed = R.Session.with_transaction c ~f:(fun tx ->
      match R.Session.exec tx (R.exec D.Fields.[] "ALTER TABLE t ALTER id TYPE DOUBLE") D.Args.[] with Error e -> Error e | Ok () ->
      R.Session.exec tx insert D.Args.[5L; None; None]) in
    ignore (failed "schema change inside transaction" (fun e -> match e.cause with
      | Parameter_schema_changed | D.Error.Type_mismatch _ -> true
      | _ -> false) changed);
    ok (R.Session.exec c insert D.Args.[6L; None; None]);
    assert (Int64.equal (count c "t") 4L));
  Stdlib.print_endline "request: transaction lending, rollback on request error, in-transaction schema change=ok"

(* Exact small numerics: boundary values roundtrip without validation. *)
let () =
  connected (fun c ->
    ok (R.Session.exec c (R.exec D.Fields.[] "CREATE TABLE n(a TINYINT, b SMALLINT, f FLOAT)") D.Args.[]);
    let insert = R.exec D.Fields.[int8; int16; float32] "INSERT INTO n VALUES (?, ?, ?)" in
    ok (R.Session.exec c insert D.Args.[-128s; 32767S; 0.1s]);
    ok (R.Session.exec c insert D.Args.[127s; -32768S; -0.s]);
    let rows = R.many D.Fields.[] D.Fields.[int8; int16; float32] ~row:(fun a b f -> (a, b, f))
      "SELECT a, b, f FROM n ORDER BY a" in
    match ok (R.Session.collect c rows D.Args.[]) with
    | [ (a1, b1, f1); (a2, b2, f2) ] ->
      assert (Stdlib_stable.Int8.to_int a1 = -128 && Stdlib_stable.Int16.to_int b1 = 32767);
      assert (Int64.equal (Stdlib.Int64.bits_of_float (Stdlib_stable.Float32.to_float f1)) (Stdlib.Int64.bits_of_float (Stdlib_stable.Float32.to_float 0.1s)));
      assert (Stdlib_stable.Int8.to_int a2 = 127 && Stdlib_stable.Int16.to_int b2 = -32768);
      assert (Int64.equal (Stdlib.Int64.bits_of_float (Stdlib_stable.Float32.to_float f2)) Int64.min_value)
    | _ -> failwith "small numerics: unexpected rows");
  Stdlib.print_endline "request: int8/int16/float32 boundaries roundtrip exactly=ok"
let () =
  connected (fun c ->
    (match R.Session.collect c (R.many D.Fields.[] D.Fields.[] ~row:() "SELECT 1") D.Args.[] with
     | Error { cause = Column_count { expected = 0; actual = 1 }; _ } -> ()
     | _ -> failwith "zero-column decoder must fail with Column_count");
    ok (R.Session.exec c (R.exec D.Fields.[] "CREATE TABLE z(i INT)") D.Args.[]);
    (* An exec request folded as rows yields units: the unconstrained No_rows path. *)
    match ok (R.Session.collect c (R.exec D.Fields.[] "INSERT INTO z VALUES (1)") D.Args.[]) with
    | [ () ] -> ()
    | _ -> failwith "exec collected as rows must yield one unit");
  Stdlib.print_endline "request: zero-column decoders are column-checked=ok"

(* One run per shape agrees with the named operations. *)
let () =
  seeded (fun c ->
    assert (Option.equal String.equal (ok (D.Owned.run c D.Owned.Find by_id D.Args.[1L])) (ok (R.Session.find c by_id D.Args.[1L])));
    assert (Option.is_none (ok (D.Owned.run c D.Owned.Find_opt maybe D.Args.[9L])));
    assert (List.length (ok (D.Owned.run c D.Owned.Collect rows D.Args.[0L])) = 2);
    assert (ok (D.Owned.run c (D.Owned.Fold { init = 0; f = (fun _ n -> Ok (D.Continue (n + 1))) }) rows D.Args.[0L]) = 2);
    ok (D.Owned.run c D.Owned.Exec insert D.Args.[3L; None; None]));
  Stdlib.print_endline "request: shape run agrees with named operations=ok"

(* Errors are flat: context plus cause, no Core/Data_error nesting. *)
let () =
  connected (fun c ->
    let bad = R.exec D.Fields.[] "SELEC 1" in
    (match R.Session.exec c bad D.Args.[] with
     | Error { D.Error.context = D.Error.Query "SELEC 1"; cause = D.Error.Native _ } -> ()
     | _ -> failwith "flat error: unexpected shape");
    let wrong = R.one D.Fields.[] D.Fields.[string] ~row:Fn.id "SELECT 1::BIGINT" in
    match R.Session.find c wrong D.Args.[] with
    | Error { cause = D.Error.Type_mismatch { actual = "BIGINT"; expected = "VARCHAR"; _ }; _ } -> ()
    | _ -> failwith "flat error: type names");
  Stdlib.print_endline "request: flat errors with type names=ok"

(* Request-level row numbers are absolute within the result, not chunk-relative. *)
let () =
  connected (fun c ->
    let sql = "SELECT CASE WHEN i = 3000 THEN NULL ELSE i END FROM range(4000) t(i)" in
    let values = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id sql in
    match R.Session.collect c values D.Args.[] with
    | Error { D.Error.context = D.Error.Query q; cause = D.Error.Null { column = 0; row = 3000 } } when String.equal q sql -> ()
    | _ -> failwith "request Null must report the absolute row");
  connected (fun c ->
    let rejecting = D.Codec.Values.custom D.Codec.Values.int64 ~encode:Or_error.return
      ~decode:(fun n -> if Int64.equal n 3001L then Or_error.error_string "reject" else Ok n) in
    let decoded = R.many D.Fields.[] D.Fields.[rejecting] ~row:Fn.id "SELECT i FROM range(4000) t(i)" in
    match R.Session.collect c decoded D.Args.[] with
    | Error { cause = D.Error.Decode_rejected { column = 0; row = 3001; _ }; _ } -> ()
    | _ -> failwith "request Decode_rejected must report the absolute row");
  Stdlib.print_endline "request: absolute row numbers in Null and Decode_rejected=ok"

(* Each facade family reports its own context; callback errors pass through. *)
let () =
  let context name expected = function
    | Error { D.Error.context; _ } when Poly.equal context expected -> ()
    | Error _ -> failwith (name ^ ": wrong context") | Ok _ -> failwith (name ^ ": unexpected success") in
  let dir = Stdlib.Filename.temp_dir "duckdb-error-contexts" "" in
  let good = Stdlib.Filename.concat dir "good.parquet" and corrupt = Stdlib.Filename.concat dir "corrupt.parquet" in
  Exn.protect ~finally:(fun () ->
    List.iter [good; corrupt] ~f:(fun f -> if Stdlib.Sys.file_exists f then Stdlib.Sys.remove f); Stdlib.Sys.rmdir dir)
    ~f:(fun () ->
      connected (fun c ->
        let path name = core_ok (D.Parquet.path name) in
        core_ok (D.Parquet.export c ~query:"SELECT 1::BIGINT AS i" (path good));
        Stdlib.Out_channel.with_open_bin corrupt (fun ch -> Stdlib.Out_channel.output_string ch "not parquet");
        let fold paths ~f = D.Parquet.fold c (List.map paths ~f:path) D.Fields.[int64] ~row:Fn.id ~init:() ~f in
        let continue _ () = Ok (D.Continue ()) in
        context "corrupt file" (D.Error.Parquet corrupt) (fold [corrupt] ~f:continue);
        context "second file" (D.Error.Parquet corrupt) (fold [good; corrupt] ~f:continue);
        let returned = { D.Error.context = Query "callback"; cause = Busy } in
        (match fold [good] ~f:(fun _ () -> Error returned) with
         | Error e when phys_equal e returned -> () | _ -> failwith "Parquet callback error not passed through");
        let sql = "SELECT ?::BIGINT" in
        context "bind" (D.Error.Query sql) (D.Statement.with_prepared c sql ~f:(fun p -> D.Statement.bind p 1 D.Codec.Values.string "x"));
        ok (R.Session.exec c (R.exec D.Fields.[] "CREATE TABLE typed(x INTEGER)") D.Args.[]);
        let typed = D.Table.(declare "typed" Columns.[ "x", string ] ~row:Fn.id) in
        context "table" (D.Error.Table { schema = "main"; name = "typed" })
          (D.Table.with_appender c typed ~f:(fun _ -> Ok ())));
      let db = core_ok (D.Owned.open_database (core_ok (D.Config.create Memory))) in
      let c = core_ok (D.Owned.connect db) in
      (match D.Owned.close_database db with
       | Error { context = Database; cause = Busy } -> ()
       | _ -> failwith "close_database with a live connection");
      core_ok (D.Owned.close_connection c); core_ok (D.Owned.close_database db); clean ());
  Stdlib.print_endline "errors: contexts for parquet/statement/database/table=ok"

(* One operation set over both session kinds. *)
let () =
  connected (fun c ->
    let s = R.Session.exec in
    ok (s c create D.Args.[]);
    ok (R.Session.with_transaction c ~f:(fun tx ->
      match R.Session.exec tx insert D.Args.[1L; Some "a"; None] with Error e -> Error e | Ok () ->
      match R.Session.collect tx rows D.Args.[0L] with Error e -> Error e | Ok n ->
      assert (List.length n = 1); Ok ()));
    assert (List.length (ok (R.Session.collect c rows D.Args.[0L])) = 1));
  Stdlib.print_endline "request: Session ops over connection and transaction=ok"

module C = R.Session

(* Arity 1, 8 (largest saturated) and 9 (curried fallback) decode identically. *)
let () =
  connected (fun c ->
    let one = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT i::BIGINT FROM range(3000) t(i) ORDER BY i" in
    assert (List.length (ok (C.collect c one D.Args.[])) = 3000);
    let eight = R.many D.Fields.[] D.Fields.[int64; int64; int64; int64; int64; int64; int64; int64]
      ~row:(fun a b c d e f g h -> Int64.(a + b + c + d + e + f + g + h))
      "SELECT i, i, i, i, i, i, i, i FROM (SELECT i::BIGINT i FROM range(3000) t(i)) ORDER BY i" in
    let nine = R.many D.Fields.[] D.Fields.[int64; int64; int64; int64; int64; int64; int64; int64; nullable int64]
      ~row:(fun a b c d e f g h k -> Int64.(a + b + c + d + e + f + g + h + Option.value k ~default:0L))
      "SELECT i, i, i, i, i, i, i, i, CASE WHEN i % 2 = 0 THEN NULL ELSE i END FROM (SELECT i::BIGINT i FROM range(3000) t(i)) ORDER BY i" in
    let sum rows = List.fold rows ~init:0L ~f:Int64.( + ) in
    assert (Int64.equal (sum (ok (C.collect c eight D.Args.[]))) Int64.(8L * 4_498_500L));
    assert (Int64.equal (sum (ok (C.collect c nine D.Args.[]))) Int64.(8L * 4_498_500L + 2_250_000L)));
  Stdlib.print_endline "request: arities 1, 8 and 9 decode identically=ok"

(* A NULL after a Stop is never read; a NULL before it is reported with its absolute row. *)
let () =
  connected (fun c ->
    let q = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT CASE WHEN i = 2100 THEN NULL ELSE i::BIGINT END FROM range(3000) t(i) ORDER BY i" in
    assert (Int64.equal (ok (C.fold c q D.Args.[] ~init:0L ~f:(fun x _ -> Ok (if Int64.(x = 5L) then D.Stop x else D.Continue x)))) 5L);
    ignore (failed "null row" (fun e -> match e.cause with Null { column = 0; row = 2100 } -> true | _ -> false)
      (C.collect c q D.Args.[]) : D.Error.t));
  Stdlib.print_endline "request: NULL reported at its absolute row, never after Stop=ok"

(* Within one row, the leftmost failing column is reported. *)
let () =
  connected (fun c ->
    let bad = D.Codec.Values.custom ~encode:Or_error.return
      ~decode:(fun (n : int64) -> if Int64.(n = 2049L) then Or_error.error_string "bad" else Ok n) D.Codec.Values.int64 in
    let q = R.many D.Fields.[] D.Fields.[bad; int64] ~row:(fun a b -> Int64.(a + b))
      "SELECT i::BIGINT, CASE WHEN i = 2049 THEN NULL ELSE i::BIGINT END FROM range(3000) t(i) ORDER BY i" in
    ignore (failed "leftmost" (fun e -> match e.cause with Decode_rejected { column = 0; row = 2049; _ } -> true | _ -> false)
      (C.collect c q D.Args.[]) : D.Error.t));
  Stdlib.print_endline "request: leftmost column failure wins within a row=ok"

(* Fast path: leftmost rejection within a row, saturated (arity 2) and across
   the curried boundary (columns 7 and 8 of 9). *)
let () =
  connected (fun c ->
    let bad = D.Codec.Values.custom ~encode:Or_error.return
      ~decode:(fun (n : int64) -> if Int64.(n = 2049L) then Or_error.error_string "bad" else Ok n) D.Codec.Values.int64 in
    let rejected column (e : D.Error.t) = match e.cause with
      | Decode_rejected { column = c; row = 2049; _ } -> c = column | _ -> false in
    let two = R.many D.Fields.[] D.Fields.[bad; bad] ~row:(fun a b -> Int64.(a + b))
      "SELECT i::BIGINT, i::BIGINT FROM range(3000) t(i) ORDER BY i" in
    ignore (failed "fast leftmost" (rejected 0) (C.collect c two D.Args.[]) : D.Error.t);
    let nine = R.many D.Fields.[] D.Fields.[int64; int64; int64; int64; int64; int64; int64; bad; bad]
      ~row:(fun a b c d e f g h k -> Int64.(a + b + c + d + e + f + g + h + k))
      "SELECT i, i, i, i, i, i, i, i, i FROM (SELECT i::BIGINT i FROM range(3000) t(i)) ORDER BY i" in
    ignore (failed "curried leftmost" (rejected 7) (C.collect c nine D.Args.[]) : D.Error.t));
  Stdlib.print_endline "request: fast-path leftmost rejection, saturated and curried=ok"

(* A result type that validation accepted as unresolved but that differs from
   the declaration is reported, never reinterpreted. *)
let () =
  connected (fun c ->
    let q = R.many D.Fields.[int64] D.Fields.[float64] ~row:Fn.id "SELECT ?" in
    ignore (failed "unresolved result type" (fun e -> match e.cause with
      | Type_mismatch { index = 0; expected = "DOUBLE"; actual = "BIGINT" } -> true | _ -> false)
      (C.collect c q D.Args.[1L]) : D.Error.t));
  Stdlib.print_endline "request: unresolved result type mismatch reported, not reinterpreted=ok"

(* Fast path over a nullable custom codec and timestamp scalars. *)
let () =
  connected (fun c ->
    let doubled = D.Codec.Values.custom ~encode:(fun n -> Ok Int64.(n / 2L))
      ~decode:(fun n -> Ok Int64.(n * 2L)) D.Codec.Values.int64 in
    let q = R.many D.Fields.[] D.Fields.[nullable doubled; timestamp_s; timestamp_ms] ~row:(fun a s ms -> a, s, ms)
      "SELECT CASE WHEN i = 7 THEN NULL ELSE i::BIGINT END, make_timestamp(i * 1000000)::TIMESTAMP_S, \
       make_timestamp(i * 1000)::TIMESTAMP_MS FROM range(3000) t(i) ORDER BY i" in
    let rows = ok (C.collect c q D.Args.[]) in
    assert (List.length rows = 3000);
    List.iteri rows ~f:(fun i (a, s, ms) ->
      let i = Int64.of_int i in
      assert (Option.equal Int64.equal a (if Int64.(i = 7L) then None else Some Int64.(i * 2L)));
      assert (Int64.equal s i && Int64.equal ms i)));
  Stdlib.print_endline "request: fast path nullable custom and timestamps round-trip=ok"

(* DuckDB prepares a parameterised table function's columns as one unresolved
   column; typed rows are validated against the executed result's columns. *)
let () =
  let check ~oneshot c =
    let doubled = R.many ~oneshot D.Fields.[int64] D.Fields.[int64; int64] ~row:(fun a b -> (a, b))
      "SELECT i, i * 2 FROM range(?) t(i) ORDER BY i" in
    let expected = List.init 5 ~f:(fun i -> let i = Int64.of_int i in (i, Int64.(i * 2L))) in
    let pairs = List.equal (fun (a, b) (x, y) -> Int64.equal a x && Int64.equal b y) in
    assert (pairs (ok (C.collect c doubled D.Args.[5L])) expected);
    (* A re-run takes the cached statement when caching applies. *)
    assert (pairs (ok (C.collect c doubled D.Args.[5L])) expected);
    assert (List.is_empty (ok (C.collect c doubled D.Args.[0L])));
    let cross = R.many ~oneshot D.Fields.[int64; int64] D.Fields.[int64; int64] ~row:(fun a b -> (a, b))
      "SELECT a, b FROM generate_series(1, ?) t(a), range(?) u(b)" in
    assert (List.length (ok (C.collect c cross D.Args.[3L; 4L])) = 12);
    let mistyped = R.many ~oneshot D.Fields.[int64] D.Fields.[int64; string] ~row:(fun a b -> (a, b))
      "SELECT i, i * 2 FROM range(?) t(i)" in
    let type_mismatch (e : D.Error.t) = match e.cause with
      | Type_mismatch { index = 1; expected = "VARCHAR"; actual = "BIGINT" } -> true | _ -> false in
    ignore (failed "table function type" type_mismatch (C.collect c mistyped D.Args.[5L]) : D.Error.t);
    ignore (failed "table function type, empty" type_mismatch (C.collect c mistyped D.Args.[0L]) : D.Error.t);
    let wide = R.many ~oneshot D.Fields.[int64] D.Fields.[int64; int64; int64] ~row:(fun a b c -> (a, b, c))
      "SELECT i, i * 2 FROM range(?) t(i)" in
    let column_count (e : D.Error.t) = match e.cause with
      | Column_count { expected = 3; actual = 2 } -> true | _ -> false in
    ignore (failed "table function arity" column_count (C.collect c wide D.Args.[5L]) : D.Error.t);
    ignore (failed "table function arity, cached" column_count (C.collect c wide D.Args.[5L]) : D.Error.t);
    ignore (failed "table function arity, empty" column_count (C.collect c wide D.Args.[0L]) : D.Error.t) in
  connected (fun c -> check ~oneshot:false c; check ~oneshot:true c);
  connected ~statement_cache:0 (fun c -> check ~oneshot:false c);
  Stdlib.print_endline "request: parameterised table functions validated against executed columns=ok"
