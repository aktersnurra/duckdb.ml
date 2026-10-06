(* Local typed views of one column of a borrowed chunk. *)
type ('a, 'n) t
type _ nulls = Non_null : Codec.non_null nulls | Nullable : Codec.nullable nulls
type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Failure.t @@ global
val view : Borrowed_chunk.t @ local -> int -> 'a Scalar.t -> 'n nulls -> ('a, 'n) opened @ local
val length : _ t @ local -> int
val int64 : (int64, Codec.non_null) t @ local -> int -> int64# [@@zero_alloc]
val float : (float, Codec.non_null) t @ local -> int -> float# [@@zero_alloc]
val int32 : (int32, Codec.non_null) t @ local -> int -> int32# [@@zero_alloc]
val float32 : (float32, Codec.non_null) t @ local -> int -> float32# [@@zero_alloc]
val int16 : (int16, Codec.non_null) t @ local -> int -> int16 [@@zero_alloc]
val int8 : (int8, Codec.non_null) t @ local -> int -> int8 [@@zero_alloc]
val bool : (bool, Codec.non_null) t @ local -> int -> bool [@@zero_alloc]
val string : (string, Codec.non_null) t @ local -> int -> string
val is_null : (_, Codec.nullable) t @ local -> int -> bool [@@zero_alloc]
val int64_or : (int64, Codec.nullable) t @ local -> default:int64# -> int -> int64# [@@zero_alloc]
val float_or : (float, Codec.nullable) t @ local -> default:float# -> int -> float# [@@zero_alloc]
val int32_or : (int32, Codec.nullable) t @ local -> default:int32# -> int -> int32# [@@zero_alloc]
val float32_or : (float32, Codec.nullable) t @ local -> default:float32# -> int -> float32# [@@zero_alloc]
val int16_or : (int16, Codec.nullable) t @ local -> default:int16 -> int -> int16 [@@zero_alloc]
val int8_or : (int8, Codec.nullable) t @ local -> default:int8 -> int -> int8 [@@zero_alloc]
val bool_or : (bool, Codec.nullable) t @ local -> default:bool -> int -> bool [@@zero_alloc]
val string_opt : (string, Codec.nullable) t @ local -> int -> string option

(* Private, for Bulk: copy this chunk's column (0 at NULL rows) or its
   validity into [into] at [pos]; raise [Invalid_argument] if [into] is too
   short. *)
val blit : (_, _) t @ local -> into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
val blit_validity : (_, Codec.nullable) t @ local ->
  into:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
