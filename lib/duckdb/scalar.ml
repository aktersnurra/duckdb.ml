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
  | Parameter_schema_changed


let name : type a. a t -> string = function
  | Bool -> "BOOLEAN" | Int8 -> "TINYINT" | Int16 -> "SMALLINT"
  | Int32 -> "INTEGER" | Int64 -> "BIGINT" | Float32 -> "FLOAT"
  | Float64 -> "DOUBLE" | String -> "VARCHAR" | Blob -> "BLOB"
  | Date -> "DATE" | Timestamp_s -> "TIMESTAMP_S" | Timestamp_ms -> "TIMESTAMP_MS"
  | Timestamp_us -> "TIMESTAMP" | Timestamp_ns -> "TIMESTAMP_NS" | Timestamp_tz -> "TIMESTAMPTZ"
module Id = Duckdb_ffi.Type_id
let native_id : type a. a t -> int = function
  | Bool -> Id.boolean | Int8 -> Id.tinyint | Int16 -> Id.smallint
  | Int32 -> Id.integer | Int64 -> Id.bigint | Float32 -> Id.float
  | Float64 -> Id.double | Timestamp_us -> Id.timestamp | Date -> Id.date
  | String -> Id.varchar | Blob -> Id.blob | Timestamp_s -> Id.timestamp_s
  | Timestamp_ms -> Id.timestamp_ms | Timestamp_ns -> Id.timestamp_ns
  | Timestamp_tz -> Id.timestamp_tz

type packed = Packed : _ t -> packed
let all =
  [ Packed Bool; Packed Int8; Packed Int16; Packed Int32; Packed Int64
  ; Packed Float32; Packed Float64; Packed String; Packed Blob; Packed Date
  ; Packed Timestamp_s; Packed Timestamp_ms; Packed Timestamp_us
  ; Packed Timestamp_ns; Packed Timestamp_tz ]

type _ repr =
  | Integer : { encode : 'a -> int64; decode : int64 -> 'a } -> 'a repr
  | Floating : float repr
  | Bytes : string repr

let small_int = Integer { encode = Int64.of_int; decode = Int64.to_int_exn }
let int32 = Integer { encode = Stdlib.Int64.of_int32; decode = Stdlib.Int64.to_int32 }
let int64 = Integer { encode = Fn.id; decode = Fn.id }
let repr : type a. a t -> a repr = function
  | Bool -> Integer { encode = (fun b -> if b then 1L else 0L); decode = (fun n -> not (Int64.equal n 0L)) }
  | Int8 -> small_int | Int16 -> small_int
  | Int32 -> int32 | Date -> int32
  | Int64 -> int64 | Timestamp_s -> int64 | Timestamp_ms -> int64
  | Timestamp_us -> int64 | Timestamp_ns -> int64 | Timestamp_tz -> int64
  | Float32 -> Floating | Float64 -> Floating
  | String -> Bytes | Blob -> Bytes
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
let validate_option typ = function None -> Ok () | Some value -> validate typ value
let witness : type a. a field -> packed = function Required typ -> Packed typ | Nullable typ -> Packed typ
