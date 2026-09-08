open! Base
module F = Duckdb_ffi
module S = Scalar
type t = { native : F.prepared }
let length (chunk @ local) = F.chunk_length chunk.native
let check_type (native @ local) index typ =
  let actual = F.column_type native index in
  if actual = S.native_id typ then Ok ()
  else Error (Resource.Data_error (S.Type_mismatch { index; expected = S.name typ; actual }))
let read : type a. t @ local -> int -> int -> a S.t -> a = fun (chunk @ local) column row typ ->
  match typ with
  | S.Bool -> not (Int64.equal (F.box_int64 (F.chunk_int64 chunk.native column row)) 0L)
  | S.Int8 -> Int64.to_int_exn (F.box_int64 (F.chunk_int64 chunk.native column row))
  | S.Int16 -> Int64.to_int_exn (F.box_int64 (F.chunk_int64 chunk.native column row))
  | S.Int32 -> Stdlib.Int64.to_int32 (F.box_int64 (F.chunk_int64 chunk.native column row))
  | S.Date -> Stdlib.Int64.to_int32 (F.box_int64 (F.chunk_int64 chunk.native column row))
  | S.Int64 ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Timestamp_s ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Timestamp_ms ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Timestamp_us ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Timestamp_ns ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Timestamp_tz ->
    F.box_int64 (F.chunk_int64 chunk.native column row)
  | S.Float32 -> F.chunk_float chunk.native column row
  | S.Float64 -> F.chunk_float chunk.native column row
  | S.String -> F.chunk_string chunk.native column row
  | S.Blob -> F.chunk_string chunk.native column row
let column : type a. t @ local -> column:int -> row:int -> a S.field -> (a, Resource.error) result =
  fun (chunk @ local) ~column ~row field ->
    let columns = F.column_count chunk.native in
    if column < 0 || column >= columns then Error (Resource.Data_error (S.Index { index = column; length = columns }))
    else if row < 0 || row >= length chunk then Error (Resource.Data_error (S.Index { index = row; length = length chunk }))
    else
      let get : type b. b S.t -> (b option, Resource.error) result = fun typ ->
        match check_type chunk.native column typ with
        | Error e -> Error e
        | Ok () -> if F.chunk_valid chunk.native column row then Ok (Some (read chunk column row typ)) else Ok None in
      match field with
      | S.Nullable typ -> get typ [@nontail]
      | S.Required typ ->
        (match get typ with
         | Error e -> Error e | Ok (Some x) -> Ok x
         | Ok None -> Error (Resource.Data_error (S.Null { column; row })))
let rec width : type a. a Row.t -> int = function
  | Row.Empty -> 0 | Row.Column (_, rest) -> 1 + width rest | Row.Map (inner, _) -> width inner
let validate_schema native decoder =
  let expected = width decoder and actual = F.column_count native in
  if expected <> actual then Error (Resource.Data_error (S.Column_count { expected; actual }))
  else
    let rec loop : type a. int -> a Row.t -> (unit, Resource.error) result = fun index -> function
      | Row.Empty -> Ok () | Row.Map (inner, _) -> loop index inner
      | Row.Column (field, rest) ->
        let checked = match field with S.Required typ -> check_type native index typ | S.Nullable typ -> check_type native index typ in
        Result.bind checked ~f:(fun () -> loop (index + 1) rest) in
    loop 0 decoder
let decode (chunk @ local) row decoder =
  let rec loop : type a. t @ local -> int -> a Row.t -> (a, Resource.error) result = fun (chunk @ local) index -> function
    | Row.Empty -> Ok ()
    | Row.Map (inner, f) -> Result.map (loop chunk index inner) ~f
    | Row.Column (field, rest) ->
      match column chunk ~column:index ~row field with
      | Error e -> Error e
      | Ok value -> Result.map (loop chunk (index + 1) rest) ~f:(fun tail -> value, tail) in
  loop chunk 0 decoder
