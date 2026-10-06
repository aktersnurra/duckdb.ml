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
val scalar : ('a, _, _) kind -> 'a Scalar.t
val bigarray_kind : (_, 'k, 'e) kind -> ('k, 'e) Bigarray.kind
val blit : ('a, _) Column.t @ local -> ('a, 'k, 'e) kind ->
  into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
val blit_validity : ('a, Codec.nullable) Column.t @ local -> into:mask @ local -> pos:int -> unit [@@zero_alloc]
