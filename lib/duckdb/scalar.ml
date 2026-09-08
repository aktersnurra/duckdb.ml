open! Base
type _ t =
  | Bool : bool t | Int8 : int t | Int16 : int t | Int32 : int32 t | Int64 : int64 t
  | Float32 : float t | Float64 : float t | String : string t | Blob : string t
  | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
  | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t

type _ field = Required : 'a t -> 'a field | Nullable : 'a t -> 'a option field

type error =
  | Range of { expected : string; value : string }
  | Type_mismatch of { index : int; expected : string; actual : int }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Column_count of { expected : int; actual : int }
  | Unbound_parameter of int


let name : type a. a t -> string = function
  | Bool -> "BOOLEAN" | Int8 -> "TINYINT" | Int16 -> "SMALLINT"
  | Int32 -> "INTEGER" | Int64 -> "BIGINT" | Float32 -> "FLOAT"
  | Float64 -> "DOUBLE" | String -> "VARCHAR" | Blob -> "BLOB"
  | Date -> "DATE" | Timestamp_s -> "TIMESTAMP_S" | Timestamp_ms -> "TIMESTAMP_MS"
  | Timestamp_us -> "TIMESTAMP" | Timestamp_ns -> "TIMESTAMP_NS" | Timestamp_tz -> "TIMESTAMPTZ"
let native_id : type a. a t -> int = function
  | Bool -> 1 | Int8 -> 2 | Int16 -> 3 | Int32 -> 4 | Int64 -> 5
  | Float32 -> 10 | Float64 -> 11 | Timestamp_us -> 12 | Date -> 13
  | String -> 17 | Blob -> 18 | Timestamp_s -> 20 | Timestamp_ms -> 21
  | Timestamp_ns -> 22 | Timestamp_tz -> 31
let round_float32 x = Stdlib.Int32.float_of_bits (Stdlib.Int32.bits_of_float x)
let validate : type a. a t -> a -> (unit, error) result = fun typ value ->
  let range value = Error (Range { expected = name typ; value }) in
  match typ with
  | Int8 -> if value < -128 || value > 127 then range (Int.to_string value) else Ok ()
  | Int16 -> if value < -32768 || value > 32767 then range (Int.to_string value) else Ok ()
  | Float32 ->
    if Float.is_nan value || Float.equal (round_float32 value) value then Ok ()
    else range (Float.to_string value)
  | _ -> Ok ()
