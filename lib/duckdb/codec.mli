open! Base

type non_null = Non_null_codec
type nullable = Nullable_codec

(** A non-null value crosses the native boundary as one base scalar; [decode]
    and [encode] convert between it and the user type. *)
type 'a plan = Plan : { scalar : 'b Scalar.t; decode : 'b -> 'a Or_error.t; encode : 'a -> 'b Or_error.t } -> 'a plan
type ('a, 'nullability) t =
  | Non_null : 'a plan -> ('a, non_null) t
  | Nullable : 'a plan -> ('a option, nullable) t

module Values : sig
  val bool : (bool, non_null) t
  val int8 : (int, non_null) t
  val int16 : (int, non_null) t
  val int32 : (int32, non_null) t
  val int64 : (int64, non_null) t
  val float32 : (float, non_null) t
  val float64 : (float, non_null) t
  val string : (string, non_null) t
  val blob : (string, non_null) t
  val date : (int32, non_null) t
  val timestamp_s : (int64, non_null) t
  val timestamp_ms : (int64, non_null) t
  val timestamp_us : (int64, non_null) t
  val timestamp_ns : (int64, non_null) t
  val timestamp_tz : (int64, non_null) t
  val of_scalar : 'a Scalar.t -> ('a, non_null) t
  val nullable : ('a, non_null) t -> ('a option, nullable) t
  val custom : encode:('a -> 'b Or_error.t) -> decode:('b -> 'a Or_error.t) ->
    ('b, non_null) t -> ('a, non_null) t
end
