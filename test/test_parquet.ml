open! Base
open Duckdb
let rec message = function Native_error s -> s | Rollback_failed (a,b) -> message a ^ "; " ^ message b | _ -> "structured error"
let ok = function Ok x -> x | Error e -> failwith (message e)
let error = function Error e -> e | Ok _ -> failwith "expected error"
let floats a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Stdlib.Int64.bits_of_float a) (Stdlib.Int64.bits_of_float b)
let write path text = let ch = Stdlib.open_out_bin path in Exn.protect ~finally:(fun () -> Stdlib.close_out ch) ~f:(fun () -> Stdlib.output_string ch text)
let read path = let ch = Stdlib.open_in_bin path in Exn.protect ~finally:(fun () -> Stdlib.close_in ch) ~f:(fun () -> Stdlib.really_input_string ch (Stdlib.in_channel_length ch))
let scalar : type a. connection -> string -> a Scalar.t -> a list -> (a -> a -> bool) -> unit = fun c dir typ values equal ->
  let file = Stdlib.Filename.concat dir (Scalar.name typ ^ " quote' ; --.parquet") in
  let p = ok (Parquet.path file) in
  ok (execute c ("CREATE OR REPLACE TABLE scalars(x " ^ Scalar.name typ ^ ")"));
  let expected = None :: List.map values ~f:Option.some in
  ok (with_appender c "scalars" ~f:(fun a -> append_rows a (List.map expected ~f:(fun x -> [Cell (Nullable typ,x)]))));
  ok (Parquet.export c ~query:"SELECT x FROM scalars ORDER BY rowid" p);
  let decode paths = ok (Parquet.fold_rows c paths Row.(Column (Nullable typ,Empty)) ~init:[]
    ~f:(fun (x,()) xs -> Ok (Continue (x::xs)))) |> List.rev in
  assert (List.equal (Option.equal equal) (decode [p]) expected);
  assert (List.equal (Option.equal equal) (decode [p;p]) (expected @ expected));
  let original = read file in
  assert (match Parquet.export c ~query:"SELECT 0" p with Error Destination_exists -> true | _ -> false);
  assert (String.equal original (read file));
  ignore (error (Parquet.fold_rows c [p] Row.Empty ~init:() ~f:(fun () () -> Ok (Continue ()))));
  Stdlib.Sys.remove file
let () =
  let dir = Stdlib.Filename.temp_file "duckdb-parquet-tests-" "" in
  Stdlib.Sys.remove dir; Unix.mkdir dir 0o700;
  Exn.protect ~finally:(fun () ->
    Array.iter (Stdlib.Sys.readdir dir) ~f:(fun name -> Stdlib.Sys.remove (Stdlib.Filename.concat dir name)); Unix.rmdir dir)
    ~f:(fun () ->
      ok (with_database (ok (Config.create Memory)) ~f:(fun db -> with_connection db ~f:(fun c ->
        scalar c dir Bool [true;false] Bool.equal;
        scalar c dir Int8 [-128;127] Int.equal; scalar c dir Int16 [-32768;32767] Int.equal;
        scalar c dir Int32 [Int32.min_value;Int32.max_value] Int32.equal;
        scalar c dir Int64 [Int64.min_value;9007199254740993L;Int64.max_value] Int64.equal;
        scalar c dir Float32 [0.;-0.;Scalar.round_float32 0.1;Float.infinity;Float.neg_infinity;Float.nan] floats;
        scalar c dir Float64 [0.;-0.;0.1;Float.infinity;Float.neg_infinity;Float.nan] floats;
        scalar c dir String ["";"\000quote' text";String.make 100000 's'] String.equal;
        scalar c dir Blob ["";"\000\255\128";String.make 100000 '\255'] String.equal;
        scalar c dir Date [Int32.min_value;Int32.max_value;-1l;0l] Int32.equal;
        List.iter [Scalar.Timestamp_us;Timestamp_ns;Timestamp_tz] ~f:(fun typ ->
          scalar c dir typ [Int64.min_value;Int64.max_value;-1L;1000000001L] Int64.equal);
        let file = Stdlib.Filename.concat dir "out.parquet" in
        let p = ok (Parquet.path file) in
        List.iter ["";"https://host/x";"s3://bucket/x";"file:/x";"a\000b";"*.parquet";"a?.parquet";"[a].parquet";"a\\b"]
          ~f:(fun s -> ignore (error (Parquet.path s)));
        let original_cwd = Stdlib.Sys.getcwd () in
        let unusual_cwd = Stdlib.Filename.concat dir "glob[dir]" in
        Unix.mkdir unusual_cwd 0o700;
        Exn.protect ~finally:(fun () -> Stdlib.Sys.chdir original_cwd; Unix.rmdir unusual_cwd)
          ~f:(fun () ->
            Stdlib.Sys.chdir unusual_cwd;
            ignore (error (Parquet.path "relative.parquet")));
        let decoder = Row.(Column (Required Int64,Empty)) in
        let consume paths = Parquet.fold_rows c paths decoder ~init:0 ~f:(fun _ n -> Ok (Continue (n+1))) in
        ignore (error (consume [])); ignore (error (consume [p]));
        write file ""; ignore (error (consume [p])); write file "PAR1corrupt"; ignore (error (consume [p])); Stdlib.Sys.remove file;
        List.iter ["SELECT 1; SELECT 2";"SELECT ?";"CREATE TABLE should_not_exist(x INT)";
          "SELECT (";"SELECT 1; COPY (SELECT 2) TO '/must-not-write'";"SELECT 1;-- trailing terminator"] ~f:(fun query ->
          ignore (error (Parquet.export c ~query p)); assert (not (Stdlib.Sys.file_exists file)));
        List.iter ["SELECT '1970-01-01'::TIMESTAMP_S";"SELECT '1970-01-01'::TIMESTAMP_MS";
          "SELECT 1::HUGEINT";"SELECT [1,2]"] ~f:(fun query ->
          assert (match Parquet.export c ~query p with Error (Unsupported_parquet_type _) -> true | _ -> false);
          assert (not (Stdlib.Sys.file_exists file)));
        (* Writer failure after schema preparation: TRY is deliberately absent. *)
        ignore (error (Parquet.export c ~query:"SELECT CAST('not an integer' AS BIGINT)" p));
        assert (not (Stdlib.Sys.file_exists file)); assert (Array.length (Stdlib.Sys.readdir dir) = 0);
        ok (Parquet.export c ~query:"SELECT 1::BIGINT AS \"quote' ; --\" WHERE false" p);
        assert (ok (consume [p;p]) = 0);
        ignore (error (Parquet.fold_rows c [p] Row.(Column (Required Float64,Empty)) ~init:() ~f:(fun _ () -> Ok (Continue ()))));
        Stdlib.Sys.remove file;
        ok (Parquet.export c ~query:"SELECT i AS x FROM range(5000) t(i) -- safe trailing comment" p);
        assert (ok (consume [p;p]) = 10000);
        assert (ok (Parquet.fold_rows c [p;p] decoder ~init:0 ~f:(fun _ n -> Ok (Stop (n+1)))) = 1);
        let other = Stdlib.Filename.concat dir "other.parquet" in
        let p2 = ok (Parquet.path other) in
        ok (Parquet.export c ~query:"SELECT 9007199254740992::DOUBLE" p2);
        let seen = ref 0 in
        ignore (error (Parquet.fold_rows c [p;p2] decoder ~init:() ~f:(fun _ () -> Int.incr seen; Ok (Continue ()))));
        assert (!seen = 5000);
        Stdlib.Sys.remove file; Stdlib.Sys.remove other;
        (* No-replace link also refuses dangling symlinks. *)
        Unix.symlink "nonexistent" file;
        assert (match Parquet.export c ~query:"SELECT 1" p with Error Destination_exists -> true | _ -> false);
        assert (String.equal (Unix.readlink file) "nonexistent"); Stdlib.Sys.remove file;
        assert (Array.length (Stdlib.Sys.readdir dir) = 0); Ok ()))));
  assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0);
  Stdlib.print_endline "parquet: all supported scalar fidelity, paths, multi-file exact schemas, no-overwrite and failure cleanup passed"
