open! Base
open Failure
module F = Duckdb_ffi
module I16 = Stdlib_stable.Int16
module I8 = Stdlib_stable.Int8
type ('a, 'n) t = { native : F.prepared; column : int; length : int }
type _ nulls = Non_null : Codec.non_null nulls | Nullable : Codec.nullable nulls
type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Failure.t @@ global

let rejected sql cause = Rejected { context = Query sql; cause }

let view : type a n. Borrowed_chunk.t @ local -> int -> a Scalar.t -> n nulls -> (a, n) opened @ local =
  fun chunk column scalar nulls ->
  let native = chunk.Borrowed_chunk.native in
  let sql = chunk.sql in
  let columns = F.column_count native in
  if column < 0 || column >= columns then rejected sql (Index { index = column; length = columns })
  else
    let actual = F.column_type native column in
    if actual <> Scalar.native_id scalar then
      rejected sql (Type_mismatch { index = column; expected = Scalar.name scalar; actual = type_name actual })
    else
      let length = F.chunk_length native in
      let first_null = match nulls with Non_null -> F.view_first_null native column length | Nullable -> -1 in
      if first_null >= 0 then rejected sql (Null { column; row = first_null })
      else exclave_ Opened { native; column; length }

let length (v @ local) = v.length
let[@inline] check (v @ local) i =
  if i < 0 || i >= v.length then invalid_arg "Duckdb.Statement.Column: row index out of bounds"
let[@zero_alloc] int64 (v @ local) i = check v i; F.view_int64 v.native v.column i
let[@zero_alloc] float (v @ local) i = check v i; F.view_double v.native v.column i
let[@zero_alloc] int32 (v @ local) i = check v i; F.view_int32 v.native v.column i
let[@zero_alloc] float32 (v @ local) i = check v i; F.view_float v.native v.column i
let[@zero_alloc] int16 (v @ local) i = check v i; I16.of_int (F.view_int16 v.native v.column i)
let[@zero_alloc] int8 (v @ local) i = check v i; I8.of_int (F.view_int8 v.native v.column i)
let[@zero_alloc] bool (v @ local) i = check v i; F.view_bool v.native v.column i
let string (v @ local) i = check v i; F.chunk_string v.native v.column i
let[@zero_alloc] is_null (v @ local) i = check v i; not (F.view_valid v.native v.column i)
let[@zero_alloc] int64_or (v @ local) ~default i = if is_null v i then default else F.view_int64 v.native v.column i
let[@zero_alloc] float_or (v @ local) ~default i = if is_null v i then default else F.view_double v.native v.column i
let[@zero_alloc] int32_or (v @ local) ~default i = if is_null v i then default else F.view_int32 v.native v.column i
let[@zero_alloc] float32_or (v @ local) ~default i = if is_null v i then default else F.view_float v.native v.column i
let[@zero_alloc] int16_or (v @ local) ~default i = if is_null v i then default else I16.of_int (F.view_int16 v.native v.column i)
let[@zero_alloc] int8_or (v @ local) ~default i = if is_null v i then default else I8.of_int (F.view_int8 v.native v.column i)
let[@zero_alloc] bool_or (v @ local) ~default i = if is_null v i then default else F.view_bool v.native v.column i
let string_opt (v @ local) i = if is_null v i then None else Some (F.chunk_string v.native v.column i)
let[@inline] room ~message (v @ local) into ~pos =
  if pos < 0 || pos > Bigarray.Array1.dim into - v.length then invalid_arg message
let[@zero_alloc] blit (v @ local) ~into ~pos =
  room ~message:"Duckdb.Bulk.blit: destination too short" v into ~pos;
  F.view_blit v.native v.column v.length into pos
let[@zero_alloc] blit_validity (v @ local) ~into ~pos =
  room ~message:"Duckdb.Bulk.blit_validity: destination too short" v into ~pos;
  F.view_blit_validity v.native v.column v.length into pos
