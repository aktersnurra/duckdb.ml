open! Base

type config = { rows : int; warmups : int; samples : int }
type totals = { rows : int; nulls : int; checksum : int64 }
type metrics = { execute_ns : int64; process_ns : int64; minor_words : float;
                 promoted_words : float; major_words : float; minor_collections : int;
                 major_collections : int; compactions : int }

let fail_error = function
  | Ok value -> value
  | Error _ -> failwith "DuckDB operation failed"

let expected rows =
  let total = Stdlib.Int64.div (Stdlib.Int64.mul (Stdlib.Int64.of_int rows)
    (Stdlib.Int64.of_int (rows - 1))) 2L in
  let multiples = (rows - 1) / 10 in
  let missing = Stdlib.Int64.mul 10L (Stdlib.Int64.div
    (Stdlib.Int64.mul (Stdlib.Int64.of_int multiples) (Stdlib.Int64.of_int (multiples + 1))) 2L) in
  { rows; nulls = (rows + 9) / 10; checksum = Stdlib.Int64.add total (Stdlib.Int64.sub total missing) }

let add required nullable totals =
  { rows = totals.rows + 1
  ; nulls = totals.nulls + if Option.is_none nullable then 1 else 0
  ; checksum = Stdlib.Int64.add (Stdlib.Int64.add totals.checksum required)
      (Option.value nullable ~default:0L) }

let check (config : config) totals =
  let target = expected config.rows in
  if totals.rows <> target.rows || totals.nulls <> target.nulls ||
     not (Int64.equal totals.checksum target.checksum)
  then failwith "benchmark result mismatch"

(* The read paths execute and decode in one call ([Statement.fold_chunks] folds
   inside the result lease), so each time includes execute and neither has a
   separate execute time. The request is built once, so
   warmups populate the statement cache and later samples exclude prepare. *)
let owned_request sql =
  Duckdb.Request.many Duckdb.Fields.[] Duckdb.Fields.[int64; nullable int64]
    ~row:(fun required nullable -> required, nullable) sql

let owned connection request () =
  match Duckdb.Request.Session.fold connection request Duckdb.Args.[] ~init:{ rows = 0; nulls = 0; checksum = 0L }
    ~f:(fun (required, nullable) totals -> Ok (Duckdb.Continue (add required nullable totals))) with
  | Ok totals -> totals
  | Error { context = Query sql; _ } -> failwith ("benchmark owned request failed in " ^ sql)
  | Error _ -> failwith "benchmark owned request failed"

let borrowed prepared () =
  fail_error (Duckdb.Statement.fold_chunks prepared ~init:{ rows = 0; nulls = 0; checksum = 0L }
                ~f:(fun chunk totals ->
                  let rec rows index totals =
                    if index = Duckdb.Statement.chunk_length chunk then Ok (Duckdb.Continue totals)
                    else
                      let required = fail_error (Duckdb.Statement.column chunk ~column:0 ~row:index
                                                   Duckdb.Codec.Values.int64) in
                      let nullable = fail_error (Duckdb.Statement.column chunk ~column:1 ~row:index
                                                   Duckdb.Codec.Values.(nullable int64)) in
                      rows (index + 1) (add required nullable totals)
                  in
                  rows 0 totals [@nontail]))

module C = Duckdb.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u

let[@zero_alloc] rec sum_required (v @ local) i n acc =
  if i = n then acc else sum_required v (i + 1) n (I64.add acc (C.int64 v i))
let[@zero_alloc] rec sum_nullable (v @ local) i n acc =
  if i = n then acc else sum_nullable v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))

let column_views prepared () =
  fail_error (Duckdb.Statement.fold_chunks prepared ~init:{ rows = 0; nulls = 0; checksum = 0L }
                ~f:(fun chunk totals ->
                  match C.view chunk 0 Duckdb.Scalar.Int64 C.Non_null,
                        C.view chunk 1 Duckdb.Scalar.Int64 C.Nullable with
                  | C.Rejected e, _ | _, C.Rejected e -> Error e
                  | C.Opened a, C.Opened b ->
                    let n = C.length a in
                    Ok (Duckdb.Continue
                          { rows = totals.rows + n; nulls = totals.nulls + C.null_count b
                          ; checksum = Int64.(totals.checksum + I64.to_int64 (sum_required a 0 n #0L)
                                              + I64.to_int64 (sum_nullable b 0 n #0L)) })))

type int64s = (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
type bytes_ba = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
(* Unboxed accumulators, so collect's minor words are the API's, not the harness's. *)
let[@zero_alloc] rec sum_ba (a : int64s) (b : int64s) i n acc =
  if i = n then acc else sum_ba a b (i + 1) n (I64.add acc (I64.of_int64 Int64.(a.{i} + b.{i})))
let[@zero_alloc] rec count_zero (m : bytes_ba) i n acc =
  if i = n then acc else count_zero m (i + 1) n (if m.{i} = 0 then acc + 1 else acc)

(* [Bulk.collect] gathers one column per call, so this path executes the query
   twice (once per column); that is the honest cost of the one-column helper. *)
let collect prepared () =
  let { Duckdb.Bulk.data = a; _ } =
    fail_error (Duckdb.Bulk.collect prepared ~column:0 (Duckdb.Bulk.Int64 Duckdb.Scalar.Int64) C.Non_null) in
  let { Duckdb.Bulk.data = b; validity = Duckdb.Bulk.Mask m } =
    fail_error (Duckdb.Bulk.collect prepared ~column:1 (Duckdb.Bulk.Int64 Duckdb.Scalar.Int64) C.Nullable) in
  let n = Bigarray.Array1.dim a in
  { rows = n; nulls = count_zero m 0 n 0; checksum = I64.to_int64 (sum_ba a b 0 n #0L) }

(* The ingest paths' execute phase recreates the table and builds the input;
   their process time covers the append plus one aggregate query that
   computes the totals from the ingested table. *)
let ingest_table =
  Duckdb.Table.(declare "ingest" Columns.["a", int64; "b", nullable int64] ~row:(fun a b -> (a, b)))
let totals_query =
  Duckdb.Request.one Duckdb.Fields.[] Duckdb.Fields.[int64; int64; int64]
    ~row:(fun rows nulls checksum -> { rows = Int64.to_int_exn rows; nulls = Int64.to_int_exn nulls; checksum })
    "SELECT count(*)::BIGINT, count(*) FILTER (WHERE b IS NULL)::BIGINT, \
     (sum(a) + coalesce(sum(b), 0))::BIGINT FROM ingest"
let fresh connection = fail_error (Duckdb.execute connection "CREATE OR REPLACE TABLE ingest(a BIGINT, b BIGINT)")

let row_batches rows =
  List.chunks_of ~length:1000 (List.init rows ~f:(fun i ->
    Duckdb.Args.[Int64.of_int i; (if i % 10 = 0 then None else Some (Int64.of_int i))]))
let row_ingest connection batches =
  fail_error (Duckdb.Table.with_appender connection ingest_table ~f:(fun a ->
    let rec append_all = function
      | [] -> Ok ()
      | rows :: rest -> (match Duckdb.Table.append a rows with Ok () -> append_all rest | e -> e) in
    append_all batches [@nontail]));
  fail_error (Duckdb.Request.Session.find connection totals_query Duckdb.Args.[])

let columnar_input rows =
  Bigarray.Array1.init Bigarray.int64 Bigarray.c_layout rows Int64.of_int,
  Bigarray.Array1.init Bigarray.int8_unsigned Bigarray.c_layout rows (fun i -> if i % 10 = 0 then 0 else 1)
let columnar_ingest connection (a, m) =
  fail_error (Duckdb.Table.with_appender connection ingest_table ~f:(fun ap ->
    Duckdb.Table.append_columns ap
      Duckdb.Bulk.Columns.[Int64 (Duckdb.Scalar.Int64, a); Nullable (Int64 (Duckdb.Scalar.Int64, a), m)]));
  fail_error (Duckdb.Request.Session.find connection totals_query Duckdb.Args.[])

let delta before after =
  { execute_ns = 0L; process_ns = 0L
  ; minor_words = after.Stdlib.Gc.minor_words -. before.Stdlib.Gc.minor_words
  ; promoted_words = after.Stdlib.Gc.promoted_words -. before.Stdlib.Gc.promoted_words
  ; major_words = after.Stdlib.Gc.major_words -. before.Stdlib.Gc.major_words
  ; minor_collections = after.Stdlib.Gc.minor_collections - before.Stdlib.Gc.minor_collections
  ; major_collections = after.Stdlib.Gc.major_collections - before.Stdlib.Gc.major_collections
  ; compactions = after.Stdlib.Gc.compactions - before.Stdlib.Gc.compactions }

(* Local, so the measured work may use the scoped connection and statement. *)
let measure (config : config) (execute @ local) (process @ local) =
  Stdlib.Gc.full_major ();
  let execute_start = Mtime_clock.elapsed_ns () in
  let result = execute () in
  let execute_ns = Stdlib.Int64.sub (Mtime_clock.elapsed_ns ()) execute_start in
  let before = Stdlib.Gc.quick_stat () in
  let process_start = Mtime_clock.elapsed_ns () in
  let totals = process result in
  let process_ns = Stdlib.Int64.sub (Mtime_clock.elapsed_ns ()) process_start in
  let after = Stdlib.Gc.quick_stat () in
  check config totals;
  let metrics = delta before after in
  if Int64.(metrics.execute_ns < 0L || process_ns < 0L) ||
     List.exists [ metrics.minor_words; metrics.promoted_words; metrics.major_words ] ~f:(fun value -> Float.(value < 0.))
  then failwith "negative metric";
  { metrics with execute_ns; process_ns }, totals

let print_row sample path order (config : config) metrics totals =
  Stdlib.Printf.printf "%d\t%s\t%s\t%d\t%Ld\t%d\t%Ld\t%Ld\t%.17g\t%.17g\t%.17g\t%d\t%d\t%d\n%!"
    sample path order config.rows totals.checksum totals.nulls metrics.execute_ns metrics.process_ns
    metrics.minor_words metrics.promoted_words metrics.major_words metrics.minor_collections
    metrics.major_collections metrics.compactions

let parse_config argv =
  if Array.length argv <> 7 || not (String.equal argv.(1) "--rows") ||
     not (String.equal argv.(3) "--warmups") || not (String.equal argv.(5) "--samples")
  then failwith "usage: --rows INT --warmups INT --samples INT"
  else match Int.of_string_opt argv.(2), Int.of_string_opt argv.(4), Int.of_string_opt argv.(6) with
    | Some rows, Some warmups, Some samples when rows > 0 && warmups >= 0 && samples > 0 ->
      { rows; warmups; samples }
    | _ -> failwith "rows/samples must be positive and warmups nonnegative"

let run (config : config) =
  let sql = Printf.sprintf
      "SELECT i::BIGINT, CASE WHEN i %% 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(%d) AS values(i) ORDER BY i"
      config.rows in
  (* An owned connection is global, so the statement callback may use it too. *)
  let database = fail_error (Duckdb.Owned.open_database (fail_error (Duckdb.Config.create ~threads:1 Duckdb.Config.Memory))) in
  Exn.protect ~finally:(fun () -> fail_error (Duckdb.Owned.close_database database)) ~f:(fun () ->
  let connection = fail_error (Duckdb.Owned.connect database) in
  Exn.protect ~finally:(fun () -> fail_error (Duckdb.Owned.close_connection connection)) ~f:(fun () ->
  ignore (fail_error (
        Duckdb.Statement.with_prepared connection sql ~f:(fun prepared ->
          let request = owned_request sql in
          (* Same order as [PATHS] in run_benchmarks.py. *)
          let path_count = 6 in
          let path_name = function
            | 0 -> "borrowed_chunks" | 1 -> "owned_rows" | 2 -> "column_views"
            | 3 -> "collect" | 4 -> "row_ingest" | 5 -> "columnar_ingest"
            | _ -> failwith "unknown benchmark path" in
          let measure_path index =
            match index with
            | 0 -> measure config ignore (borrowed prepared) [@nontail]
            | 1 -> measure config ignore (fun () -> owned connection request ())
            | 2 -> measure config ignore (column_views prepared) [@nontail]
            | 3 -> measure config ignore (collect prepared) [@nontail]
            | 4 -> measure config (fun () -> fresh connection; row_batches config.rows)
                     (row_ingest connection)
            | 5 -> measure config (fun () -> fresh connection; columnar_input config.rows)
                     (columnar_ingest connection)
            | _ -> failwith "unknown benchmark path" in
          for _ = 1 to config.warmups do
            for index = 0 to path_count - 1 do
              ignore (measure_path index : metrics * totals)
            done
          done;
          Stdlib.Printf.printf "# benchmark_processing rows=%d warmups=%d samples=%d threads=1\n" config.rows config.warmups config.samples;
          Stdlib.Printf.printf "sample\tpath\torder\trows\tchecksum\tnulls\texecute_ns\tprocess_ns\tminor_words\tpromoted_words\tmajor_words\tminor_collections\tmajor_collections\tcompactions\n%!";
          for sample = 0 to config.samples - 1 do
            let first = sample % path_count in
            let order = "first=" ^ path_name first in
            for offset = 0 to path_count - 1 do
              let index = (first + offset) % path_count in
              let metrics, totals = measure_path index in
              print_row sample (path_name index) order config metrics totals
            done
          done;
          Ok ())) : unit)))

let () = run (parse_config Stdlib.Sys.argv)
