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

(* Both paths execute and decode in one call ([Statement.fold_chunks] folds
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
  let database = fail_error (Duckdb.Owned.open_database (fail_error (Duckdb.Config.create Duckdb.Config.Memory))) in
  Exn.protect ~finally:(fun () -> fail_error (Duckdb.Owned.close_database database)) ~f:(fun () ->
  let connection = fail_error (Duckdb.Owned.connect database) in
  Exn.protect ~finally:(fun () -> fail_error (Duckdb.Owned.close_connection connection)) ~f:(fun () ->
  ignore (fail_error (
        Duckdb.Statement.with_prepared connection sql ~f:(fun prepared ->
          let request = owned_request sql in
          let measure_owned () = measure config ignore (fun () -> owned connection request ()) in
          let measure_borrowed () = measure config ignore (borrowed prepared) [@nontail] in
          for _ = 1 to config.warmups do
            ignore (measure_owned () : metrics * totals);
            ignore (measure_borrowed () : metrics * totals)
          done;
          Stdlib.Printf.printf "# benchmark_processing rows=%d warmups=%d samples=%d\n" config.rows config.warmups config.samples;
          Stdlib.Printf.printf "sample\tpath\torder\trows\tchecksum\tnulls\texecute_ns\tprocess_ns\tminor_words\tpromoted_words\tmajor_words\tminor_collections\tmajor_collections\tcompactions\n%!";
          for sample = 0 to config.samples - 1 do
            let first_owned = sample % 2 = 0 in
            let emit path measured order =
              let metrics, totals = measured () in
              print_row sample path order config metrics totals in
            if first_owned then begin
              emit "owned_rows" measure_owned "owned_first";
              emit "borrowed_chunks" measure_borrowed "owned_first"
            end else begin
              emit "borrowed_chunks" measure_borrowed "borrowed_first";
              emit "owned_rows" measure_owned "borrowed_first"
            end
          done;
          Ok ())) : unit)))

let () = run (parse_config Stdlib.Sys.argv)
