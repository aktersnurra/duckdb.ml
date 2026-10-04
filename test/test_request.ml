open! Base
module D = Duckdb
module R = D.Request
module C = R.Connection
module T = R.Transaction
external prepares : unit -> int = "epoch_test_prepares" [@@noalloc]
let ( let* ) x f = Result.bind x ~f
let core_ok = function Ok x -> x | Error (D.Native_error s) -> failwith s | Error _ -> failwith "unexpected core error"
let rec describe (e : R.request_error) = match e.cause with
  | R.Core (D.Native_error s) -> "Core Native_error: " ^ s
  | R.Core _ -> "Core"
  | R.Parameter_count _ -> "Parameter_count" | R.Row_count _ -> "Row_count"
  | R.Unknown_column _ -> "Unknown_column" | R.Missing_column _ -> "Missing_column"
  | R.Encode_rejected _ -> "Encode_rejected" | R.Decode_rejected _ -> "Decode_rejected"
  | R.Rollback_failed { primary; _ } -> "Rollback_failed: " ^ describe primary
let ok = function Ok x -> x | Error e -> failwith ("unexpected request error: " ^ describe e)
let failed name predicate = function
  | Error (e : R.request_error) when predicate e -> e
  | Error e -> failwith (name ^ ": unexpected " ^ describe e)
  | Ok _ -> failwith (name ^ ": unexpected success")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected ?(statement_cache = 64) f =
  let config = core_ok (D.Config.create ~statement_cache Memory) in
  core_ok (D.with_database config ~f:(fun db -> D.with_connection db ~f:(fun c -> f c; Ok ())));
  clean ()
let count c table = core_ok (D.with_prepared c ("SELECT count(*)::BIGINT FROM " ^ table) ~f:(fun p ->
  let* r = D.execute_prepared p in
  D.fold_rows r D.Row.(Column (Required Int64, Empty)) ~init:0L ~f:(fun (n, ()) _ -> Ok (D.Stop n))))

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
  ok (C.exec c create D.Args.[]);
  ok (C.exec c insert D.Args.[1L; Some "one"; Some 1.5]);
  ok (C.exec c insert D.Args.[2L; None; None]);
  f c)

let () =
  seeded (fun c ->
    assert (List.equal equal_row (ok (C.collect c rows D.Args.[0L]))
      [ { id = 1L; note = Some "one"; score = Some 1.5 }; { id = 2L; note = None; score = None } ]);
    assert (Option.equal String.equal (ok (C.find c by_id D.Args.[1L])) (Some "one"));
    assert (Option.is_none (ok (C.find c by_id D.Args.[2L])));
    assert (Option.equal Int64.equal (ok (C.find_opt c maybe D.Args.[2L])) (Some 2L));
    assert (Option.is_none (ok (C.find_opt c maybe D.Args.[9L])));
    assert (ok (C.fold c rows D.Args.[0L] ~init:0 ~f:(fun _ n -> Ok (D.Continue (n + 1)))) = 2);
    assert (ok (C.fold c rows D.Args.[0L] ~init:0 ~f:(fun _ n -> Ok (D.Stop (n + 1)))) = 1));
  Stdlib.print_endline "request: exec/find/find_opt/collect/fold roundtrip, NULLs, Stop=ok"

(* R5/R6: multiplicity is enforced at run time; the result is always closed. *)
let () =
  seeded (fun c ->
    let any = R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let none = R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t WHERE id < 0" in
    let at_most = R.zero_or_one D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let row_count expected actual (e : R.request_error) = match e.cause with
      | R.Row_count r -> Poly.equal r.expected expected && Poly.equal r.actual actual | _ -> false in
    ignore (failed "find many" (row_count `One `More_than_one) (C.find c any D.Args.[]));
    ignore (failed "find none" (row_count `One `Zero) (C.find c none D.Args.[]));
    ignore (failed "find_opt many" (row_count `Zero_or_one `More_than_one) (C.find_opt c at_most D.Args.[]));
    ok (C.exec c insert D.Args.[3L; None; None]));
  Stdlib.print_endline "request: Row_count for find/find_opt, connection reusable=ok"

(* R1-R3: declarations are checked against engine metadata before execution. *)
let () =
  seeded (fun c ->
    let wrong_type = R.exec D.Fields.[string] "INSERT INTO t(id) VALUES (?)" in
    let mismatch (e : R.request_error) = match e.cause with
      | R.Core (D.Data_error (D.Scalar.Type_mismatch _)) -> true | _ -> false in
    ignore (failed "parameter type" mismatch (C.exec c wrong_type D.Args.["x"]));
    let too_few = R.exec D.Fields.[int64] "INSERT INTO t(id, note) VALUES (?, ?)" in
    ignore (failed "parameter count" (fun e -> match e.cause with
      | R.Parameter_count { expected = 1; actual = 2 } -> true | _ -> false) (C.exec c too_few D.Args.[5L]));
    let wrong_columns = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id, note FROM t" in
    ignore (failed "column count" (fun e -> match e.cause with
      | R.Core (D.Data_error (D.Scalar.Column_count { expected = 1; actual = 2 })) -> true | _ -> false)
      (C.collect c wrong_columns D.Args.[]));
    let wrong_column = R.many D.Fields.[] D.Fields.[string] ~row:Fn.id "SELECT id FROM t" in
    ignore (failed "column type" mismatch (C.collect c wrong_column D.Args.[]));
    assert (Int64.equal (count c "t") 2L));
  Stdlib.print_endline "request: parameter type/count and column count/type rejected before execution=ok"

(* R10/R11: custom codecs; failures are named and positioned. *)
let () =
  let positive = D.Codec.Values.custom D.Codec.Values.int64
    ~encode:(fun n -> if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive")
    ~decode:(fun n -> if Int64.(n > 0L) then Ok n else Or_error.error_string "stored not positive") in
  seeded (fun c ->
    let insert_positive = R.exec D.Fields.[positive] "INSERT INTO t(id) VALUES (?)" in
    ok (C.exec c insert_positive D.Args.[7L]);
    ignore (failed "encode" (fun e -> match e.cause with
      | R.Encode_rejected { index = 1; reason } -> String.equal (Error.to_string_hum reason) "not positive"
      | _ -> false) (C.exec c insert_positive D.Args.[-1L]));
    assert (Int64.equal (count c "t") 3L);
    ok (C.exec c (R.exec D.Fields.[] "INSERT INTO t(id) VALUES (-5)") D.Args.[]);
    let read_positive = R.many D.Fields.[] D.Fields.[int64; positive] ~row:(fun a b -> (a, b))
      "SELECT 0::BIGINT, id FROM t ORDER BY id" in
    ignore (failed "decode" (fun e -> match e.cause with
      | R.Decode_rejected { column = 1; row = 0; _ } -> true | _ -> false) (C.collect c read_positive D.Args.[])));
  Stdlib.print_endline "request: custom codec encode/decode rejection with positions=ok"

(* R13: every error names its SQL. *)
let () =
  seeded (fun c ->
    let sql = "SELECT missing FROM t" in
    let e = failed "native" (fun _ -> true) (C.collect c (R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id sql) D.Args.[]) in
    assert (String.equal (R.query_of_context e.context) sql));
  Stdlib.print_endline "request: errors carry query context=ok"

(* R12: statement cache. *)
let () =
  seeded (fun c ->
    ignore (ok (C.collect c rows D.Args.[0L]));
    let start = prepares () in
    for _ = 1 to 5 do ignore (ok (C.collect c rows D.Args.[0L])) done;
    Stdlib.Printf.printf "request: prepares for five cached executions=%d\n%!" (prepares () - start);
    assert (prepares () = start);
    let oneshot = R.many ~oneshot:true D.Fields.[int64] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t WHERE id >= ?" in
    let start = prepares () in
    for _ = 1 to 3 do ignore (ok (C.collect c oneshot D.Args.[0L])) done;
    assert (prepares () = start + 3));
  connected ~statement_cache:1 (fun c ->
    ok (C.exec c create D.Args.[]);
    let a = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    let b = R.many D.Fields.[] D.Fields.[nullable string] ~row:Fn.id "SELECT note FROM t" in
    ignore (ok (C.collect c a D.Args.[]));
    let start = prepares () in
    ignore (ok (C.collect c b D.Args.[])); ignore (ok (C.collect c a D.Args.[]));
    assert (prepares () = start + 2));
  connected ~statement_cache:0 (fun c ->
    ok (C.exec c create D.Args.[]);
    let a = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT id FROM t" in
    ignore (ok (C.collect c a D.Args.[]));
    let start = prepares () in
    ignore (ok (C.collect c a D.Args.[]));
    assert (prepares () = start + 1));
  (match D.Config.create ~statement_cache:(-1) Memory with
   | Error (D.Invalid_configuration _) -> () | _ -> failwith "negative statement cache accepted");
  (* Cached statements are not live children: manual close and Bridge succeed. *)
  let config = core_ok (D.Config.create Memory) in
  core_ok (D.with_database config ~f:(fun db ->
    let c = core_ok (D.connect db) in
    ok (C.exec c create D.Args.[]);
    ignore (ok (C.collect c rows D.Args.[0L]));
    core_ok (D.Bridge.run (D.Bridge.create ()) c ~f:(fun facade -> D.execute facade "SELECT 1"));
    D.close_connection c));
  clean ();
  Stdlib.print_endline "request: cache hit/oneshot/LRU/disabled/negative config/close and Bridge with cached statements=ok"

(* Transactions: cached statements are lent; errors roll back; schema change in tx detected. *)
let () =
  seeded (fun c ->
    ignore (ok (C.collect c rows D.Args.[0L]));
    let in_tx = ok (C.with_transaction c ~f:(fun tx ->
      let* () = T.exec tx insert D.Args.[3L; Some "three"; None] in
      T.collect tx rows D.Args.[3L])) in
    assert (List.length in_tx = 1);
    let rolled = C.with_transaction c ~f:(fun tx ->
      let* () = T.exec tx insert D.Args.[4L; None; None] in
      T.find tx by_id D.Args.[999L]) in
    ignore (failed "rollback on request error" (fun e -> match e.cause with R.Row_count _ -> true | _ -> false) rolled);
    assert (Int64.equal (count c "t") 3L);
    let changed = C.with_transaction c ~f:(fun tx ->
      let* () = T.exec tx (R.exec D.Fields.[] "ALTER TABLE t ALTER id TYPE DOUBLE") D.Args.[] in
      T.exec tx insert D.Args.[5L; None; None]) in
    ignore (failed "schema change inside transaction" (fun e -> match e.cause with
      | R.Core (D.Data_error (D.Scalar.Parameter_schema_changed | D.Scalar.Type_mismatch _)) -> true
      | _ -> false) changed);
    ok (C.exec c insert D.Args.[6L; None; None]);
    assert (Int64.equal (count c "t") 4L));
  Stdlib.print_endline "request: transaction lending, rollback on request error, in-transaction schema change=ok"
