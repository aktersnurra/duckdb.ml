open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module S = D.Sql
let rec describe (e : D.Error.t) = match e.cause with
  | Native s -> "Native: " ^ s
  | Type_mismatch { expected; actual; _ } -> "Type_mismatch " ^ expected ^ "/" ^ actual
  | Column_count _ -> "Column_count"
  | Rollback_failed { primary; _ } -> "Rollback_failed: " ^ describe primary
  | _ -> "other cause"
let ok = function Ok x -> x | Error e -> failwith ("unexpected error: " ^ describe e)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
(* Owned handles are global: callbacks may capture them. *)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])
let expect_sql name request expected =
  if String.( <> ) (R.query request) expected then
    failwith (Printf.sprintf "%s: rendered\n  %s\nexpected\n  %s" name (R.query request) expected)
let rejected name build = match build () with
  | exception Invalid_argument _ -> ()
  | (_ : (_, _, _) R.t) -> failwith (name ^ ": accepted")
let near a b = Float.(abs (a - b) < 1e-9)

let sales = T.(declare "sales" Columns.["k", string; "d", int32; "v", int64; "n", nullable int64]
  ~row:(fun k d v n -> (k, d, v, n)))
let seed c =
  ddl c "CREATE TABLE sales(k VARCHAR NOT NULL, d INTEGER NOT NULL, v BIGINT NOT NULL, n BIGINT)";
  ddl c "INSERT INTO sales VALUES ('a', 1, 10, 10), ('a', 2, 20, NULL), ('a', 3, 30, 5), ('b', 1, 5, NULL), ('b', 2, 7, 7)"
let run c q = ok (R.Session.collect c q D.Args.[])

(* Ranking functions over a partitioned, ordered window; QUALIFY and ORDER
   BY on window results. *)
let ranks = S.(query Params.[] (fun [] -> from sales (fun [k; d; _; _] ->
  let w = window ~partition_by:[part k] ~order_by:[asc d] () in
  let by_k = window ~order_by:[asc k] () in
  select_over Exprs.[lift k; lift d; row_number w; rank by_k; dense_rank by_k; ntile 2 w; percent_rank w; cume_dist w]
    ~row:(fun k d rn r dr nt pr cd -> (k, d, rn, r, dr, nt, pr, cd)) ~order_by:[asc (lift k); asc (lift d)])))
let latest = S.(query Params.[] (fun [] -> from sales (fun [k; d; _; _] ->
  let w = window ~partition_by:[part k] ~order_by:[desc d] () in
  select_over Exprs.[lift k; lift d] ~row:(fun k d -> (k, d))
    ~qualify:(row_number w = int64 1L) ~order_by:[asc (lift k)])))
let by_rank = S.(query Params.[] (fun [] -> from sales (fun [k; d; v; _] ->
  select_over Exprs.[lift v] ~row:Fn.id
    ~order_by:[asc (row_number (window ~order_by:[desc v] ())); asc (lift k); asc (lift d)])))
let () =
  expect_sql "latest" latest
    "SELECT t0.\"k\", t0.\"d\" FROM \"main\".\"sales\" AS t0 \
     QUALIFY (row_number() OVER (PARTITION BY t0.\"k\" ORDER BY t0.\"d\" DESC) = CAST(1 AS BIGINT)) ORDER BY t0.\"k\" ASC";
  connected (fun c ->
    seed c;
    let expected = [ ("a", 1l, 1L, 1L, 1L, 1L, 0., 1. /. 3.); ("a", 2l, 2L, 1L, 1L, 1L, 0.5, 2. /. 3.);
                     ("a", 3l, 3L, 1L, 1L, 2L, 1., 1.); ("b", 1l, 1L, 4L, 2L, 1L, 0., 0.5); ("b", 2l, 2L, 4L, 2L, 2L, 1., 1.) ] in
    if not (List.equal (fun (k, d, rn, r, dr, nt, pr, cd) (k', d', rn', r', dr', nt', pr', cd') ->
        String.equal k k' && Int32.equal d d' && Int64.equal rn rn' && Int64.equal r r' && Int64.equal dr dr'
        && Int64.equal nt nt' && near pr pr' && near cd cd') (run c ranks) expected) then failwith "ranks";
    (match run c latest with [ ("a", 3l); ("b", 2l) ] -> () | _ -> failwith "latest");
    (match run c by_rank with [ 30L; 20L; 10L; 7L; 5L ] -> () | _ -> failwith "by_rank"));
  rejected "negative ntile" (fun () -> S.(query Params.[] (fun [] -> from sales (fun [_; d; _; _] ->
    select_over Exprs.[ntile (-1) (window ~order_by:[asc d] ())] ~row:Fn.id))));
  Stdlib.print_endline "window: ranking functions, qualify, order by a window=ok"

(* Offset functions: NULL past the partition edge, or a default; values of
   the frame; ROWS and RANGE frames. *)
let offsets = S.(query Params.[] (fun [] -> from sales (fun [k; d; v; n] ->
  let w = window ~partition_by:[part k] ~order_by:[asc d] () in
  let all = window ~partition_by:[part k] ~order_by:[asc d] ~frame:(rows ~start:Unbounded_preceding ~end_:Unbounded_following) () in
  select_over Exprs.[lag v w; lead ~offset:2 v w; lag_or ~default:(int64 0L) v w; first_value v w; last_value v w;
                     last_value v all; nth_value 2 v w; Null.lag n w]
    ~row:(fun a b c d e f g h -> (a, b, c, d, e, f, g, h)) ~order_by:[asc (lift k); asc (lift d)])))
let framed = S.(query Params.[] (fun [] -> from sales (fun [k; d; v; _] ->
  let previous = window ~partition_by:[part k] ~order_by:[asc d] ~frame:(rows ~start:(Preceding 1) ~end_:Current_row) () in
  let nearby = window ~order_by:[asc d] ~frame:(range ~start:(Preceding 1) ~end_:(Following 0)) () in
  select_over Exprs.[first_value v previous; Null.first_value (nullable v) nearby]
    ~row:(fun a b -> (a, b)) ~order_by:[asc (lift k); asc (lift d)])))
let () =
  expect_sql "framed" framed
    "SELECT first_value(t0.\"v\") OVER (PARTITION BY t0.\"k\" ORDER BY t0.\"d\" ASC ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), \
     first_value(t0.\"v\") OVER (ORDER BY t0.\"d\" ASC RANGE BETWEEN 1 PRECEDING AND 0 FOLLOWING) \
     FROM \"main\".\"sales\" AS t0 ORDER BY t0.\"k\" ASC, t0.\"d\" ASC";
  connected (fun c ->
    seed c;
    (match run c offsets with
     | [ (None, Some 30L, 0L, Some 10L, Some 10L, Some 30L, None, None);
         (Some 10L, None, 10L, Some 10L, Some 20L, Some 30L, Some 20L, Some 10L);
         (Some 20L, None, 20L, Some 10L, Some 30L, Some 30L, Some 20L, None);
         (None, None, 0L, Some 5L, Some 5L, Some 7L, None, None);
         (Some 5L, None, 5L, Some 5L, Some 7L, Some 7L, Some 7L, None) ] -> ()
     | _ -> failwith "offsets");
    (* first_value over all rows by d within 1 of the current d: the rows'
       order within one d is unspecified, so only the previous-row frame is
       compared exactly. *)
    match run c framed with
    | [ (a1, _); (a2, _); (a3, _); (b1, _); (b2, _) ] ->
      assert (List.equal (Option.equal Int64.equal) [ a1; a2; a3; b1; b2 ] [ Some 10L; Some 10L; Some 20L; Some 5L; Some 5L ])
    | _ -> failwith "framed");
  rejected "negative lag offset" (fun () -> S.(query Params.[] (fun [] -> from sales (fun [_; d; v; _] ->
    select_over Exprs.[lag ~offset:(-1) v (window ~order_by:[asc d] ())] ~row:Fn.id))));
  rejected "negative frame offset" (fun () -> S.(query Params.[] (fun [] -> from sales (fun [_; d; v; _] ->
    select_over Exprs.[first_value v (window ~order_by:[asc d] ~frame:(rows ~start:(Preceding (-1)) ~end_:Current_row) ())]
      ~row:Fn.id))));
  rejected "nth_value 0" (fun () -> S.(query Params.[] (fun [] -> from sales (fun [_; d; v; _] ->
    select_over Exprs.[nth_value 0 v (window ~order_by:[asc d] ())] ~row:Fn.id))));
  Stdlib.print_endline "window: lag, lead, defaults, first/last/nth value, rows and range frames=ok"
