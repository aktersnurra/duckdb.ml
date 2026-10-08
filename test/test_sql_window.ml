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
