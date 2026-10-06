open! Base
type ('a, 'k, 'e) kind =
  | Int64 : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
  | Int32 : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
  | Int16 : (int16, int, Bigarray.int16_signed_elt) kind
  | Int8 : (int8, int, Bigarray.int8_signed_elt) kind
  | Bool : (bool, int, Bigarray.int8_unsigned_elt) kind
  | Float64 : (float, float, Bigarray.float64_elt) kind
  | Float32 : (float32, float, Bigarray.float32_elt) kind
type mask = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
type 'n validity = All_valid : Codec.non_null validity | Mask : mask -> Codec.nullable validity
type ('k, 'e, 'n) t = { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }
type _ strings =
  | Strings : string array -> Codec.non_null strings
  | Strings_opt : string option array -> Codec.nullable strings
module Columns = struct
  type _ col =
    | Int64 : int64 Scalar.t * (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> int64 col
    | Int32 : int32 Scalar.t * (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t -> int32 col
    | Int16 : (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int16 col
    | Int8 : (int, Bigarray.int8_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int8 col
    | Bool : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> bool col
    | Float64 : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> float col
    | Float32 : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t -> float32 col
    | Strings : string Scalar.t * string array -> string col
    | Nullable : 'a col * mask -> 'a option col
  type _ t = [] : unit t | (::) : 'a col * 'l t -> ('a * 'l) t
end
let scalar : type a k e. (a, k, e) kind -> a Scalar.t = function
  | Int64 s -> s | Int32 s -> s | Int16 -> Scalar.Int16 | Int8 -> Scalar.Int8
  | Bool -> Scalar.Bool | Float64 -> Scalar.Float64 | Float32 -> Scalar.Float32
let bigarray_kind : type a k e. (a, k, e) kind -> (k, e) Bigarray.kind = function
  | Int64 _ -> Bigarray.int64 | Int32 _ -> Bigarray.int32 | Int16 -> Bigarray.int16_signed
  | Int8 -> Bigarray.int8_signed | Bool -> Bigarray.int8_unsigned
  | Float64 -> Bigarray.float64 | Float32 -> Bigarray.float32
(* The kind only fixes the types: the view's column type was checked when it
   was opened, and the C copy refuses a width mismatch silently (leaving
   [into] untouched). *)
let[@zero_alloc] blit (v @ local) (_ : (_, _, _) kind) ~into ~pos = Column.blit v ~into ~pos
let[@zero_alloc] blit_validity (v @ local) ~into ~pos = Column.blit_validity v ~into ~pos
