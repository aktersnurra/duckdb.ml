open! Base
open Resource
open Failure
open Syntax
module F = Duckdb_ffi
type path = string
let resolve p =
  let invalid () = Error (Invalid_configuration "Parquet path must be a nonempty exact local filename (no NUL, colon, backslash or glob characters)") in
  let forbidden c = String.contains "\000:\\*?[]" c in
  if String.is_empty p then invalid ()
  else try
    let absolute = if Stdlib.Filename.is_relative p then Stdlib.Filename.concat (Stdlib.Sys.getcwd ()) p else p in
    if String.exists absolute ~f:forbidden then invalid () else Ok absolute
  with Stdlib.Sys_error e -> Error (Native e)
let path p = within (Parquet p) (resolve p)
let literal s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"

(* The pinned writer/reader normalizes TIMESTAMP_S/MS to microseconds. *)
let exportable =
  List.filter_map Scalar.all ~f:(fun (Scalar.Packed typ) ->
    match typ with
    | Scalar.Timestamp_s | Scalar.Timestamp_ms -> None
    | _ -> Some (Scalar.native_id typ))
let check_types types =
  match Array.findi types ~f:(fun _ typ -> not (List.mem exportable typ ~equal:Int.equal)) with
  | None -> Ok ()
  | Some (column, actual) -> Error (Unsupported_parquet_type { column; actual = type_name actual })

(* Inlined so cleanup backtraces name the calling operation. *)
let[@inline always] local_file f =
  let work = F.local_file_work () in
  Exn.protect ~finally:(fun () -> F.finish_local_file_work work)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> f work))
let publish c tx source destination =
  with_admission c (Some tx) (fun () -> local_file (fun work ->
    match F.publish_local_file_admitted (native_connection c) work source destination with
    | -1 -> Error Cancelled
    | 0 -> checkpoint c
    | e when F.file_exists_error e -> Error Destination_exists
    | e -> Error (Native (F.file_error_message e))))
let remove temporary = local_file (fun work ->
  let e = F.remove_local_file work temporary in
  if e <> 0 then raise (Stdlib.Sys_error (F.file_error_message e)))
(* Exclusive admission spans the native reservation decision and exactly one
   synchronous reservation. Record its ownership before checking the latch
   again, so cancellation cannot strand a successfully owned temp. *)
let reserve_temporary c tx destination =
  with_admission c (Some tx) (fun () ->
    match F.admit_local_file (native_connection c) with
    | F.File_cancelled -> Error Cancelled
    | F.File_admitted ->
      try Ok (Stdlib.Filename.temp_file ~temp_dir:(Stdlib.Filename.dirname destination) ".duckdb-parquet-" ".parquet")
      with Stdlib.Sys_error e -> Error (Native e))
(* Export failures, including its transaction's, are in the destination's context. *)
let with_prepared tx destination sql ~f =
  Query.with_prepared_transaction ~lifting:(Cause (Parquet destination)) tx sql ~f
let copy_to tx ~query temporary destination =
  with_prepared tx destination ("COPY (\n" ^ query ^ "\n) TO $__duckdb_ml_destination (FORMAT PARQUET)") ~f:(fun p ->
      let* () = Query.bind p 1 Codec.Values.string temporary in
      let* result = Query.execute_prepared p in
      Query.close_result result)
let export (Session.Connection c : [ `Connection ] Session.t @ local) ~query destination =
  (* The standalone source and the final COPY are independently engine-parsed;
     the bound output name never becomes SQL text. No lexical SQL classifier. *)
  within (Parquet destination) @@ with_transaction ~lifting:(Cause (Parquet destination)) c ~f:(fun tx ->
    let* () = with_prepared tx destination query ~f:(fun p ->
      let* types = Query.select_schema p in
      check_types types) in
    let* temporary = reserve_temporary c tx destination in
    scope ~lifting:(Cause (Parquet destination))
      (fun () ->
        let* () = copy_to tx ~query temporary destination in
        let* () = checkpoint c in
        publish c tx temporary destination)
      (* The private tx is never exposed; Query scopes have drained and
         publication admission has returned. Its lease owns this cleanup. *)
      (fun () -> admit_cleanup c; remove temporary))

(* Typed decoding: each file is one oneshot request over the same columns.
   Failures are in the failing file's context; callback errors pass through.
   An empty list involves no file and is reported as ["read_parquet"]. *)
let fold_files c paths fields ~row ~init ~f =
  let read p = "SELECT * FROM read_parquet(" ^ literal p ^ ")" in
  let rec loop paths acc =
    match paths with
    | [] -> Ok acc
    | p :: rest ->
      let* () = within (Parquet p) (checkpoint c) in
      let stopped = ref false in
      let* acc = Request.fold_on ~context:(Parquet p) c (Request.many ~oneshot:true Fields.[] fields ~row (read p)) ~init:acc
        ~f:(fun value acc -> Result.map (f value acc) ~f:(fun step ->
          (match step with Query.Stop _ -> stopped := true | Query.Continue _ -> ()); step)) in
      if !stopped then Ok acc else loop rest acc in
  if List.is_empty paths then within (Parquet "read_parquet") (Error (Invalid_configuration "Parquet read requires at least one file"))
  else loop paths init
let fold (Session.Connection c : [ `Connection ] Session.t @ local) paths fields ~row ~init ~f =
  fold_files c paths fields ~row ~init ~f
let fold_table (Session.Connection c : [ `Connection ] Session.t @ local) paths (Request.Table_def t : (_, _, _) Request.table) ~init ~f =
  fold_files c paths (Request.fields_of_columns t.columns) ~row:t.row ~init ~f
