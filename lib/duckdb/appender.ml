open! Base
open Resource
module F = Duckdb_ffi
module S = Scalar
type cell = Cell : 'a S.field * 'a -> cell
type appender = { native : F.appender; child : child; tx : transaction;
                  types : int array; nullable : bool array; mutable failure : error option }
let status native = if F.appender_status native = 0 then Ok () else Error (Native_error (F.appender_message native))
let poison a e =
  if Option.is_none a.failure then a.failure <- Some e;
  poison_transaction a.tx e;
  Error (Option.value_exn a.failure)
let interrupted = Native_error "Appender operation or scope interrupted; transaction must roll back"
let destroy native flush =
  (* Resource retries a cleanup interrupted by one Break. The first attempt
     may already have finished the native shell; never read status after that. *)
  if F.appender_is_closed native then Ok () else
  Exn.protect ~finally:(fun () -> F.finish_appender_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.close_appender native flush; status native))
let open_appender tx ?(schema = "main") table =
  if String.contains schema '\000' || String.contains table '\000' then Error Embedded_nul
  else if String.is_empty schema || String.is_empty table then Error (Invalid_configuration "empty appender identifier")
  else
    let c = transaction_connection tx in
    with_admission c (Some tx) (fun () ->
      let native = F.appender_owner (native_connection c) in
      match Stdlib.Sys.with_async_exns (fun () ->
        F.create_appender native schema table;
        Result.bind (status native) ~f:(fun () ->
          let types = F.appender_types native and nullable = F.appender_nullable native in
          let owner = ref None in
          let child = register_child c (Some tx) ~cleanup:(fun () ->
            let e = Native_error "Unclosed appender discarded at scope exit" in
            (match !owner with None -> poison_transaction tx e | Some a -> ignore (poison a e));
            Exn.protect ~finally:(fun () -> match !owner with None -> () | Some a -> release_result a.child)
              ~f:(fun () -> ignore (destroy native false))) in
          let a = { native; child; tx; types; nullable; failure = None } in
          owner := Some a; reserve_result child; Ok a)) with
      | Ok a -> Ok a
      | Error e -> ignore (destroy native false); poison_transaction tx e; Error e
      | exception exn ->
        poison_transaction tx interrupted;
        Exn.protect ~finally:(fun () -> ignore (destroy native false)) ~f:(fun () -> raise exn))
let encode : type a. a S.t -> a option -> F.append_cell = fun typ value ->
  let id = S.native_id typ in
  match value with None -> id, true, 0L, 0., ""
  | Some value ->
    let integer n = id, false, n, 0., "" in
    match typ with
    | S.Bool -> integer (if value then 1L else 0L)
    | S.Int8 -> integer (Int64.of_int value)
    | S.Int16 -> integer (Int64.of_int value)
    | S.Int32 -> integer (Stdlib.Int64.of_int32 value)
    | S.Date -> integer (Stdlib.Int64.of_int32 value)
    | S.Int64 -> integer value
    | S.Timestamp_s -> integer value
    | S.Timestamp_ms -> integer value
    | S.Timestamp_us -> integer value
    | S.Timestamp_ns -> integer value
    | S.Timestamp_tz -> integer value
    | S.Float32 -> id, false, 0L, value, ""
    | S.Float64 -> id, false, 0L, value, ""
    | S.String -> id, false, 0L, 0., value
    | S.Blob -> id, false, 0L, 0., value
let validate_cell a row column (Cell (field, value)) =
  let apply : type b. b S.t -> b option -> (F.append_cell, error) result = fun typ value ->
    if a.types.(column) <> S.native_id typ then
      Error (Data_error (S.Type_mismatch { index = column; expected = S.name typ; actual = a.types.(column) }))
    else if Option.is_none value && not a.nullable.(column) then Error (Data_error (S.Null { column; row }))
    else Result.bind (match value with None -> Ok () | Some v -> Result.map_error (S.validate typ v) ~f:(fun e -> Data_error e))
      ~f:(fun () -> Ok (encode typ value)) in
  match field with Required typ -> apply typ (Some value) | Nullable typ -> apply typ value
let operation a f = child_operation a.child ~allow_result:true (fun () ->
  match a.failure with Some e -> Error e | None ->
    match Stdlib.Sys.with_async_exns f with
    | Ok () -> Ok () | Error e -> poison a e
    | exception exn -> ignore (poison a interrupted); raise exn)
let append_rows a rows = operation a (fun () ->
  let checked = List.mapi rows ~f:(fun row cells ->
    if List.length cells <> Array.length a.types then
      Error (Data_error (S.Column_count { expected = Array.length a.types; actual = List.length cells }))
    else Result.map (Result.all (List.mapi cells ~f:(validate_cell a row))) ~f:Array.of_list) |> Result.all in
  Result.bind checked ~f:(fun rows ->
    Exn.protect ~finally:(fun () -> F.clear_appender_input a.native)
      ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
        F.append_rows a.native (Array.of_list rows); status a.native))))
let flush_appender a = operation a (fun () -> F.flush_appender a.native; status a.native)
let close_appender a =
  if child_is_closed a.child then Ok ()
  else child_operation a.child ~allow_result:true (fun () ->
    Exn.protect ~finally:(fun () -> release_result a.child; unregister_child a.child)
      ~f:(fun () ->
        match Stdlib.Sys.with_async_exns (fun () -> destroy a.native (Option.is_none a.failure)) with
        | result -> (match a.failure, result with
          | Some e, _ -> Error e | None, Ok () -> Ok () | None, Error e -> poison a e)
        | exception exn -> ignore (poison a interrupted); raise exn))
let with_appender_transaction tx ?schema table ~f =
  Result.bind (open_appender tx ?schema table) ~f:(fun a ->
    (* Scope can turn a caught effect denial into an error after work returned.
       Even a manually closed child must poison settlement on that outcome. *)
    match Stdlib.Sys.with_async_exns (fun () ->
      scope (fun () ->
        match f a with
        | Error e -> ignore (poison a e); Error e
        | Ok x -> Result.map (close_appender a) ~f:(fun () -> x))
        (fun () -> force_close_child a.child)) with
    | Ok x -> Ok x
    | Error e -> poison_transaction tx e; Error e
    | exception exn -> poison_transaction tx interrupted; raise exn)
let with_appender c ?schema table ~f =
  with_transaction c ~f:(fun tx -> with_appender_transaction tx ?schema table ~f)
