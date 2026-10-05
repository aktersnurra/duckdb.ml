open! Base
open Resource
open Syntax
module F = Duckdb_ffi
type path = string
let path p =
  let invalid () = Error (Invalid_configuration "Parquet path must be a nonempty exact local filename (no NUL, colon, backslash or glob characters)") in
  let forbidden c = String.contains "\000:\\*?[]" c in
  if String.is_empty p then invalid ()
  else try
    let absolute = if Stdlib.Filename.is_relative p then Stdlib.Filename.concat (Stdlib.Sys.getcwd ()) p else p in
    if String.exists absolute ~f:forbidden then invalid () else Ok absolute
  with Stdlib.Sys_error e -> Error (Native_error e)
let literal s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"

(* Folds one file; [stopped] records whether the callback asked to stop. *)
let fold_file c p decoder ~init ~f =
  let stopped = ref false in
  let observe step = (match step with Query.Stop _ -> stopped := true | Query.Continue _ -> ()); step in
  let+ acc = Query.with_prepared c ("SELECT * FROM read_parquet(" ^ literal p ^ ")") ~f:(fun statement ->
    let* result = Query.execute_prepared statement in
    Query.fold_rows result decoder ~init ~f:(fun row acc -> Result.map (f row acc) ~f:observe)) in
  acc, !stopped
let fold_rows c paths decoder ~init ~f =
  let rec loop paths acc =
    let* () = checkpoint c in
    match paths with
    | [] -> Ok acc
    | p :: rest ->
      let* acc, stopped = fold_file c p decoder ~init:acc ~f in
      if stopped then Ok acc else loop rest acc in
  if List.is_empty paths then Error (Invalid_configuration "Parquet read requires at least one file")
  else loop paths init

(* The pinned writer/reader normalizes TIMESTAMP_S/MS to microseconds. *)
let exportable =
  List.filter_map Scalar.all ~f:(fun (Scalar.Packed typ) ->
    match typ with
    | Scalar.Timestamp_s | Scalar.Timestamp_ms -> None
    | _ -> Some (Scalar.native_id typ))
let check_types types =
  match Array.findi types ~f:(fun _ typ -> not (List.mem exportable typ ~equal:Int.equal)) with
  | None -> Ok ()
  | Some (column, actual) -> Error (Unsupported_parquet_type { column; actual })

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
    | e -> Error (Native_error (F.file_error_message e))))
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
      with Stdlib.Sys_error e -> Error (Native_error e))
let copy_to tx ~query temporary =
  Query.with_prepared_transaction tx
    ("COPY (\n" ^ query ^ "\n) TO $__duckdb_ml_destination (FORMAT PARQUET)") ~f:(fun p ->
      let* () = Query.bind p 1 Codec.Values.string temporary in
      let* result = Query.execute_prepared p in
      Query.close_result result)
let export c ~query destination =
  (* The standalone source and the final COPY are independently engine-parsed;
     the bound output name never becomes SQL text. No lexical SQL classifier. *)
  with_transaction c ~f:(fun tx ->
    let* () = Query.with_prepared_transaction tx query ~f:(fun p ->
      let* types = Query.select_schema p in
      check_types types) in
    let* temporary = reserve_temporary c tx destination in
    scope
      (fun () ->
        let* () = copy_to tx ~query temporary in
        let* () = checkpoint c in
        publish c tx temporary destination)
      (* The private tx is never exposed; Query scopes have drained and
         publication admission has returned. Its lease owns this cleanup. *)
      (fun () -> admit_cleanup c; remove temporary))

(* Typed decoding: each file is one oneshot request over the same columns. *)
let fold c paths fields ~row ~init ~f =
  let read p = "SELECT * FROM read_parquet(" ^ literal p ^ ")" in
  let core sql result = Result.map_error result ~f:(fun error -> { Request.context = Request.Query sql; cause = Request.Core error }) in
  let rec loop paths acc =
    match paths with
    | [] -> Ok acc
    | p :: rest ->
      let sql = read p in
      let* () = core sql (checkpoint c) in
      let stopped = ref false in
      let* acc = Request.fold_on c (Request.many ~oneshot:true Fields.[] fields ~row sql) ~init:acc
        ~f:(fun value acc -> Result.map (f value acc) ~f:(fun step ->
          (match step with Query.Stop _ -> stopped := true | Query.Continue _ -> ()); step)) in
      if !stopped then Ok acc else loop rest acc in
  if List.is_empty paths then core "read_parquet" (Error (Invalid_configuration "Parquet read requires at least one file"))
  else loop paths init
let fold_table c paths (Request.Table_def t : (_, _) Request.table) ~init ~f =
  fold c paths (Request.fields_of_columns t.columns) ~row:t.row ~init ~f
