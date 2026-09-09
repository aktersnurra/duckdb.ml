open! Base
open Resource
module F = Duckdb_ffi
module S = Scalar
type prepared = { native : F.prepared; child : child; connection : connection; sql : string;
                  parameter_types : int array;
                  bound : bool array; mutable result : query_result option }
and query_result = { prepared : prepared; mutable closed : bool }
type chunk = Borrowed_chunk.t
type 'a step = Continue of 'a | Stop of 'a
(* Held-runtime metadata is admitted as a synchronous batch, not separately
   interruptible calls. Checkpoint again before publishing its owned output. *)
let status native = match F.prepared_status native with
  | 0 -> Ok () | 2 -> Error Unsupported_statement | 3 -> Error Cancelled | _ -> Error (Native_error (F.prepared_message native))
let native_close c native =
  admit_cleanup c;
  Exn.protect ~finally:(fun () -> F.finish_prepared_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_prepared native))
let native_close_result c native =
  admit_cleanup c;
  Exn.protect ~finally:(fun () -> F.finish_result_close native)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () -> F.close_result native))
let destroy_result r =
  Exn.protect ~finally:(fun () ->
    r.closed <- true; r.prepared.result <- None; release_result r.prepared.child)
    ~f:(fun () -> native_close_result r.prepared.connection r.prepared.native)
let prepare_on c tx sql =
  if String.contains sql '\000' then Error Embedded_nul
  else with_admission c tx (fun () ->
    let native = F.prepared_owner (native_connection c) in
    match Stdlib.Sys.with_async_exns (fun () ->
      F.prepare native sql;
      Result.bind (Result.bind (status native) ~f:(fun () -> checkpoint c)) ~f:(fun () ->
        let parameter_types = Array.init (F.parameter_count native) ~f:(fun i -> F.parameter_type native (i + 1)) in
        Result.bind (checkpoint c) ~f:(fun () ->
        (* The parent owns this cleanup even if the caller drops every alias. *)
        let result_ref = ref None in
        let child = register_child c tx ~cleanup:(fun () ->
          Exn.protect ~finally:(fun () ->
            match !result_ref with None -> () | Some p ->
              (match p.result with None -> () | Some r -> r.closed <- true);
              p.result <- None; release_result p.child)
            ~f:(fun () -> native_close c native)) in
        let p = { native; child; connection = c; sql; parameter_types; bound = Array.create ~len:(Array.length parameter_types) false; result = None } in
        result_ref := Some p;
        Ok p))) with
    | Ok p -> Ok p
    | Error e -> native_close c native; Error e
    | exception exn -> Exn.protect ~finally:(fun () -> native_close c native) ~f:(fun () -> raise exn))
let prepare c sql = prepare_on c None sql
let prepare_transaction tx sql = prepare_on (transaction_connection tx) (Some tx) sql
let without_result ?(cleanup = false) p work = child_operation ~cleanup p.child ~allow_result:true (fun () ->
  if Option.is_some p.result then Error Live_children else work ())
let close_prepared p =
  if child_is_closed p.child then Ok ()
  else without_result ~cleanup:true p (fun () ->
    Exn.protect ~finally:(fun () -> unregister_child p.child)
      ~f:(fun () -> native_close p.connection p.native; Ok ()))
let parameter_count p = child_operation p.child ~allow_result:true (fun () -> Ok (Array.length p.bound))
let reset p = without_result p (fun () ->
  (* A failed/interrupted reset leaves no binding marked usable. *)
  Array.fill p.bound ~pos:0 ~len:(Array.length p.bound) false;
  F.reset p.native; Result.bind (status p.native) ~f:(fun () -> checkpoint p.connection))
let bind_value : type a. prepared -> int -> a S.t -> a -> unit = fun p index typ value ->
  let integer x = F.bind_int64 p.native index (S.native_id typ) x in
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
  | S.Float32 -> F.bind_float p.native index (S.native_id typ) value
  | S.Float64 -> F.bind_float p.native index (S.native_id typ) value
  | S.String -> F.bind_string p.native index (S.native_id typ) value
  | S.Blob -> F.bind_string p.native index (S.native_id typ) value
let bind : type a. prepared -> int -> a S.field -> a -> (unit, error) result = fun p index field value ->
  without_result p (fun () ->
    let count = Array.length p.bound in
    if index < 1 || index > count then Error (Data_error (S.Index { index; length = count }))
    else
      let apply : type b. b S.t -> b option -> (unit, error) result = fun typ value ->
        let actual = p.parameter_types.(index - 1) in
        if actual <> 0 && actual <> 34 && actual <> S.native_id typ then
          Error (Data_error (S.Type_mismatch { index; expected = S.name typ; actual }))
        else
          let checked = match value with None -> Ok () | Some x -> Result.map_error (S.validate typ x) ~f:(fun e -> Data_error e) in
          Result.bind checked ~f:(fun () ->
            p.bound.(index - 1) <- false;
            Exn.protect ~finally:(fun () -> F.clear_prepared_input p.native)
              ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
                (match value with None -> F.bind_null p.native index | Some x -> bind_value p index typ x);
                Result.map (Result.bind (status p.native) ~f:(fun () -> checkpoint p.connection)) ~f:(fun () -> p.bound.(index - 1) <- true)))) in
      match field with S.Required typ -> apply typ (Some value) | S.Nullable typ -> apply typ value)
let validate_parameter_schema p =
  let fresh = F.prepared_owner (native_connection p.connection) in
  scope (fun () -> Result.bind (checkpoint p.connection) ~f:(fun () ->
    F.prepare fresh p.sql;
    Result.bind (Result.bind (status fresh) ~f:(fun () -> checkpoint p.connection)) ~f:(fun () ->
      let count = Array.length p.parameter_types in
      if F.parameter_count fresh <> count ||
         not (Array.for_alli p.parameter_types ~f:(fun i typ -> F.parameter_type fresh (i + 1) = typ))
      then Error (Data_error S.Parameter_schema_changed)
      else checkpoint p.connection))) (fun () -> native_close p.connection fresh)
let execute_prepared p = without_result p (fun () ->
  match Array.findi p.bound ~f:(fun _ bound -> not bound) with
  | Some (i, _) -> Error (Data_error (S.Unbound_parameter (i + 1)))
  | None ->
    match Stdlib.Sys.with_async_exns (fun () -> try Ok (
      Result.bind (with_child_snapshot p.child (fun () ->
        Result.bind (validate_parameter_schema p) ~f:(fun () ->
          Result.bind (checkpoint p.connection) ~f:(fun () ->
            F.execute_prepared p.native;
            Result.bind (status p.native) ~f:(fun () -> checkpoint p.connection))))) ~f:(fun () ->
        Result.bind (checkpoint p.connection) ~f:(fun () ->
        let r = { prepared = p; closed = false } in
        p.result <- Some r; reserve_result p.child; Ok r)))
      with exn -> Error (exn, Stdlib.Printexc.get_raw_backtrace ())) with
    | Ok (Ok r) -> Ok r
    | Ok (Error e) -> native_close_result p.connection p.native; Error e
    | Error (exn, backtrace) ->
      Exn.protect ~finally:(fun () -> native_close_result p.connection p.native)
        ~f:(fun () -> Stdlib.Printexc.raise_with_backtrace exn backtrace)
    | exception exn ->
      let backtrace = Stdlib.Printexc.get_raw_backtrace () in
      Exn.protect ~finally:(fun () -> native_close_result p.connection p.native)
        ~f:(fun () -> Stdlib.Printexc.raise_with_backtrace exn backtrace))
let close_result r =
  if r.closed || child_is_closed r.prepared.child then Ok ()
  else child_operation ~cleanup:true r.prepared.child ~allow_result:true (fun () ->
    if r.closed then Ok () else (destroy_result r; Ok ()))
let scoped prepare ~f = Result.bind (prepare ()) ~f:(fun p ->
  scope (fun () -> f p) (fun () -> force_close_child p.child))
let with_prepared c sql ~f = scoped (fun () -> prepare c sql) ~f
let with_prepared_transaction tx sql ~f = scoped (fun () -> prepare_transaction tx sql) ~f
let chunk_length = Borrowed_chunk.length
let column = Borrowed_chunk.column
let fold_internal r validate ~init ~f =
  child_operation r.prepared.child ~allow_result:true (fun () ->
    if r.closed then Error Closed
    else scope (fun () ->
      Result.bind (Result.bind (checkpoint r.prepared.connection) ~f:(fun () -> validate r.prepared.native)) ~f:(fun () ->
        let rec loop acc = match checkpoint r.prepared.connection with
          | Error e -> Error e
          | Ok () -> match F.fetch r.prepared.native with
          | 0 -> Result.map (checkpoint r.prepared.connection) ~f:(fun () -> acc)
          | -1 -> Result.bind (status r.prepared.native) ~f:(fun () -> assert false)
          | _ -> match checkpoint r.prepared.connection with
            | Error e -> Error e
            | Ok () ->
            let chunk = stack_ { Borrowed_chunk.native = r.prepared.native } in
            if chunk_length chunk = 0 then loop acc
            else match f chunk acc with
              | Error e -> Error e | Ok (Stop acc) -> Result.map (checkpoint r.prepared.connection) ~f:(fun () -> acc) | Ok (Continue acc) -> loop acc in
        loop init)) (fun () -> destroy_result r))
let fold_chunks r ~init ~f = fold_internal r (fun _ -> Ok ()) ~init ~f
let fold_rows r decoder ~init ~f =
  fold_internal r (fun native -> Borrowed_chunk.validate_schema native decoder) ~init
    ~f:(fun (chunk @ local) acc ->
      let rec loop row acc =
        match checkpoint r.prepared.connection with
        | Error e -> Error e
        | Ok () -> if row = chunk_length chunk then Ok (Continue acc)
        else match Borrowed_chunk.decode chunk row decoder with
          | Error e -> Error e
          | Ok owned -> (match f owned acc with
            | Error e -> Error e | Ok (Stop acc) -> Ok (Stop acc)
            | Ok (Continue acc) -> loop (row + 1) acc) in
      loop 0 acc [@nontail])
let select_schema p = without_result p (fun () ->
  if F.prepared_kind p.native <> 1 || Array.length p.bound <> 0 then Error Unsupported_statement
  else
    let types = F.prepared_column_types p.native in
    Result.map (checkpoint p.connection) ~f:(fun () -> types))
