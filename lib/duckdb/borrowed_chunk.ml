open! Base
open Failure
module F = Duckdb_ffi
module S = Scalar
type t = { native : F.prepared; sql : string @@ global }
let length (chunk @ local) = F.chunk_length chunk.native
let check_type (native @ local) index typ =
  let actual = F.column_type native index in
  if actual = S.native_id typ then Ok ()
  else Error (Type_mismatch { index; expected = S.name typ; actual = type_name actual })
let read : type a. t @ local -> int -> int -> a S.t -> a = fun (chunk @ local) column row typ ->
  match S.repr typ with
  | S.Integer { decode; _ } -> decode (F.box_int64 (F.chunk_int64 chunk.native column row))
  | S.Floating { decode; _ } -> decode (F.chunk_float chunk.native column row)
  | S.Bytes -> F.chunk_string chunk.native column row
let column : type a n. t @ local -> column:int -> row:int -> (a, n) Codec.t -> (a, Resource.error) result =
  fun (chunk @ local) ~column ~row codec ->
    let columns = F.column_count chunk.native in
    if column < 0 || column >= columns then Error (Index { index = column; length = columns })
    else if row < 0 || row >= length chunk then Error (Index { index = row; length = length chunk })
    else
      let get : type b. b S.t -> (b option, Resource.error) result = fun typ ->
        match check_type chunk.native column typ with
        | Error e -> Error e
        | Ok () -> if F.chunk_valid chunk.native column row then Ok (Some (read chunk column row typ)) else Ok None in
      let decoded decode b = Result.map_error (decode b) ~f:(fun reason ->
        Decode_rejected { column; row; reason }) in
      let decode_plan : type b. b Codec.plan -> (b option, Resource.error) result = function
        | Codec.Identity scalar -> get scalar
        | Codec.Plan plan ->
          (match get plan.scalar with
           | Error e -> Error e
           | Ok None -> Ok None
           | Ok (Some b) -> Result.map (decoded plan.decode b) ~f:Option.some) in
      match codec with
      | Codec.Nullable plan -> (decode_plan plan) [@nontail]
      | Codec.Non_null plan ->
        (match decode_plan plan with
         | Error e -> Error e
         | Ok None -> Error (Null { column; row })
         | Ok (Some a) -> Ok a)
