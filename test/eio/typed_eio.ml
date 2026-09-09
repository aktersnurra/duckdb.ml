open! Base
module E = Duckdb_eio

let unwrap = function Ok value -> value | Error _ -> failwith "Eio adapter error"
let ok = function Ok value -> value | Error _ -> failwith "DuckDB error"
let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))
let equal_rows = List.equal (fun (left, ()) (right, ()) -> Int64.equal left right)

let run () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let limits = unwrap (E.limits ~connections:1 ~queue_capacity:1) in
      let pool = unwrap (E.create ~sw limits (ok (Duckdb.Config.create Duckdb.Config.Memory))) in
      assert (Result.is_ok (E.execute pool "CREATE TABLE typed(i BIGINT)"));
      let batches =
        [ [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L) ]
          ; [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 2L) ]
          ] ] in
      assert (Result.is_ok (E.ingest pool ~schema:None ~table:"typed" ~batches ~flush:true));
      assert (equal_rows (unwrap (E.query pool "SELECT i FROM typed ORDER BY i" rows)) [1L, (); 2L, ()]);
      assert (Int64.equal (unwrap (E.fold_rows pool "SELECT i FROM typed ORDER BY i" rows ~init:0L
        ~f:(fun (value, ()) total ->
          Ok (if Int64.equal value 2L then Duckdb.Stop Int64.(total + value)
              else Duckdb.Continue Int64.(total + value))))) 3L);
      let path = Stdlib.Filename.temp_file "duckdb_eio_typed" ".parquet" in
      Stdlib.Sys.remove path;
      Exn.protect
        ~f:(fun () ->
          assert (Result.is_ok (E.parquet_export pool ~query:"SELECT i FROM typed ORDER BY i" ~destination:path));
          assert (equal_rows
            (List.rev (unwrap (E.parquet_fold_rows pool [path] rows ~init:[]
              ~f:(fun row values -> Ok (Duckdb.Continue (row :: values))))))
            [1L, (); 2L, ()]))
        ~finally:(fun () -> if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path);
      assert (Result.is_ok (E.shutdown pool))))

let () = run ()
