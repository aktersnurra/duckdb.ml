open! Base
open Resource
module F = Duckdb_ffi
type path = string
let path p =
  let invalid () = Error (Invalid_configuration "Parquet path must be a nonempty exact local filename (no NUL, colon, backslash or glob characters)") in
  if String.is_empty p then invalid ()
  else try
    let absolute = if Stdlib.Filename.is_relative p then Stdlib.Filename.concat (Stdlib.Sys.getcwd ()) p else p in
    if String.exists absolute ~f:(fun c -> String.contains "\000:\\*?[]" c) then invalid ()
    else Ok absolute
  with Stdlib.Sys_error e -> Error (Native_error e)
let literal s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"
let fold_rows c paths decoder ~init ~f =
  let rec loop paths acc = match paths with
    | [] -> Ok acc
    | p :: rest ->
      let stopped = ref false in
      Result.bind (Query.with_prepared c ("SELECT * FROM read_parquet(" ^ literal p ^ ")") ~f:(fun statement ->
        Result.bind (Query.execute_prepared statement) ~f:(fun result ->
          Query.fold_rows result decoder ~init:acc ~f:(fun row acc ->
            Result.map (f row acc) ~f:(fun step ->
              (match step with Query.Stop _ -> stopped := true | Continue _ -> ()); step)))))
        ~f:(fun acc -> if !stopped then Ok acc else loop rest acc) in
  if List.is_empty paths then Error (Invalid_configuration "Parquet read requires at least one file")
  else loop paths init
let check_types types =
  match Array.findi types ~f:(fun _ typ -> not (List.mem [1;2;3;4;5;10;11;12;13;17;18;22;31] typ ~equal:Int.equal)) with
  | None -> Ok ()
  | Some (column, actual) -> Error (Unsupported_parquet_type { column; actual })
let publish source destination =
  let work = F.local_file_work () in
  Exn.protect ~finally:(fun () -> F.finish_local_file_work work)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      let e = F.publish_local_file work source destination in
      if e = 0 then Ok () else if F.file_exists_error e then Error Destination_exists
      else Error (Native_error (F.file_error_message e))))
let remove temporary =
  let work = F.local_file_work () in
  Exn.protect ~finally:(fun () -> F.finish_local_file_work work)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      let e = F.remove_local_file work temporary in
      if e <> 0 then raise (Stdlib.Sys_error (F.file_error_message e))))
let export c ~query destination =
  (* The standalone source and the final COPY are independently engine-parsed;
     the bound output name never becomes SQL text. No lexical SQL classifier. *)
  with_transaction c ~f:(fun tx ->
    Result.bind (Query.with_prepared_transaction tx query ~f:(fun p ->
      Result.bind (Query.select_schema p) ~f:check_types)) ~f:(fun () ->
      let temporary = try Ok (Stdlib.Filename.temp_file ~temp_dir:(Stdlib.Filename.dirname destination)
        ".duckdb-parquet-" ".parquet") with Stdlib.Sys_error e -> Error (Native_error e) in
      Result.bind temporary ~f:(fun temporary ->
        scope (fun () ->
          Result.bind (Query.with_prepared_transaction tx
            ("COPY (\n" ^ query ^ "\n) TO $__duckdb_ml_destination (FORMAT PARQUET)") ~f:(fun p ->
              Result.bind (Query.bind p 1 (Scalar.Required Scalar.String) temporary) ~f:(fun () ->
                Result.bind (Query.execute_prepared p) ~f:Query.close_result)))
            ~f:(fun () -> publish temporary destination))
          (fun () -> remove temporary))))
