(** Native values: dates are signed days since 1970-01-01; timestamps are signed
    ticks since that epoch. Timestamp_* are timezone-free; Timestamp_tz is a UTC
    instant in microseconds (no original timezone retained). Native infinity
    sentinels are preserved. No calendar or float-time conversion is performed. *)
type _ t =
  | Bool : bool t | Int8 : int8 t | Int16 : int16 t | Int32 : int32 t | Int64 : int64 t
  | Float32 : float32 t | Float64 : float t | String : string t | Blob : string t
  | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
  | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t

type error =
  | Type_mismatch of { index : int; expected : string; actual : int }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Column_count of { expected : int; actual : int }
  | Unbound_parameter of int
  | Parameter_schema_changed
  | Encode_rejected of { index : int; reason : Base.Error.t }
  | Decode_rejected of { column : int; row : int; reason : Base.Error.t }

val name : 'a t -> string

val native_id : 'a t -> int

(** Every witness, for tables derived from the scalar universe. *)
type packed = Packed : _ t -> packed
val all : packed list

(** How a witness crosses the native boundary: as integer bits or as a double
    (with an encode/decode pair; [decode] is exact only for values the engine
    produces for that type), or as owned bytes. *)
type _ repr =
  | Integer : { encode : 'a -> int64; decode : int64 -> 'a } -> 'a repr
  | Floating : { encode : 'a -> float; decode : float -> 'a } -> 'a repr
  | Bytes : string repr
val repr : 'a t -> 'a repr
