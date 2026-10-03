(** Native values: dates are signed days since 1970-01-01; timestamps are signed
    ticks since that epoch. Timestamp_* are timezone-free; Timestamp_tz is a UTC
    instant in microseconds (no original timezone retained). Native infinity
    sentinels are preserved. No calendar or float-time conversion is performed. *)
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

val name : 'a t -> string

(** Int8/16 bounds and lossless Float32 conversion are checked before binding.
    Float32 accepts NaN, infinities and signed zero. Finite values must roundtrip
    exactly through binary32; use [round_float32] for explicit rounding. *)
val validate : 'a t -> 'a -> (unit, error) result
val round_float32 : float -> float

(** [None] (SQL NULL) is always valid. *)
val validate_option : 'a t -> 'a option -> (unit, error) result

val native_id : 'a t -> int

(** Every witness, for tables derived from the scalar universe. *)
type packed = Packed : _ t -> packed
val all : packed list

(** How a witness crosses the native boundary: as integer bits (with the exact
    lossless conversion pair), as a double, or as owned bytes. *)
type _ repr =
  | Integer : { encode : 'a -> int64; decode : int64 -> 'a } -> 'a repr
  | Floating : float repr
  | Bytes : string repr
val repr : 'a t -> 'a repr

(** The witness inside a field, NULL-ability erased. *)
val witness : 'a field -> packed
