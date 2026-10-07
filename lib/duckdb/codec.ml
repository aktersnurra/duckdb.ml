open! Base

type non_null = private Non_null_codec
type nullable = private Nullable_codec
type ('a, 'n) slot = private Slot
type 'a plan =
  | Identity : 'a Scalar.t -> 'a plan
  | Plan : { scalar : 'b Scalar.t; decode : 'b -> 'a Or_error.t; encode : 'a -> 'b Or_error.t } -> 'a plan

type packed_scalar = Packed_scalar : 'b Scalar.t -> packed_scalar
let plan_scalar : type a. a plan -> packed_scalar = function
  | Identity s -> Packed_scalar s
  | Plan p -> Packed_scalar p.scalar

type ('a, 'nullability) t =
  | Non_null : 'a plan -> ('a, non_null) t
  | Nullable : 'a plan -> ('a option, nullable) t

module Values = struct
  let of_scalar scalar = Non_null (Identity scalar)
  let bool = of_scalar Scalar.Bool
  let int8 = of_scalar Scalar.Int8
  let int16 = of_scalar Scalar.Int16
  let int32 = of_scalar Scalar.Int32
  let int64 = of_scalar Scalar.Int64
  let float32 = of_scalar Scalar.Float32
  let float64 = of_scalar Scalar.Float64
  let string = of_scalar Scalar.String
  let blob = of_scalar Scalar.Blob
  let date = of_scalar Scalar.Date
  let timestamp_s = of_scalar Scalar.Timestamp_s
  let timestamp_ms = of_scalar Scalar.Timestamp_ms
  let timestamp_us = of_scalar Scalar.Timestamp_us
  let timestamp_ns = of_scalar Scalar.Timestamp_ns
  let timestamp_tz = of_scalar Scalar.Timestamp_tz
  let nullable (Non_null plan) = Nullable plan
  let custom ~encode ~decode (Non_null base) =
    match base with
    | Identity scalar -> Non_null (Plan { scalar; decode; encode })
    | Plan base ->
      Non_null (Plan { scalar = base.scalar;
                       decode = (fun b -> Or_error.bind (base.decode b) ~f:decode);
                       encode = (fun a -> Or_error.bind (encode a) ~f:base.encode) })
end
