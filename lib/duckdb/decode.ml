open! Base
module F = Duckdb_ffi
module S = Scalar
module I64 = Stdlib_upstream_compatible.Int64_u
module I32 = Stdlib_upstream_compatible.Int32_u
module F64 = Stdlib_upstream_compatible.Float_u
module F32 = Stdlib_stable.Float32_u
exception Rejected of { column : int; reason : Base.Error.t }

let rec limit_from : type l f r. (l, f, r) Fields.t -> F.prepared @ local -> column:int -> length:int -> int =
  fun fields p ~column ~length ->
  match fields with
  | Fields.[] -> length
  | Fields.(codec :: rest) ->
    let (Codec.Packed_scalar s), nullable = match codec with
      | Codec.Non_null plan -> Codec.plan_scalar plan, false
      | Codec.Nullable plan -> Codec.plan_scalar plan, true in
    if F.column_type p column <> S.native_id s then 0
    else
      let here = if nullable then length
        else match F.view_first_null p column length with -1 -> length | row -> row in
      Int.min here (limit_from rest p ~column:(column + 1) ~length)
let limit fields (chunk @ local) ~length =
  if F.column_count chunk.Borrowed_chunk.native < Fields.length fields then 0
  else limit_from fields chunk.native ~column:0 ~length

let base : type a. a S.t -> F.prepared @ local -> int -> int -> a = fun scalar p column row ->
  match scalar with
  | S.Int64 -> I64.to_int64 (F.view_int64 p column row)
  | S.Timestamp_s -> I64.to_int64 (F.view_int64 p column row)
  | S.Timestamp_ms -> I64.to_int64 (F.view_int64 p column row)
  | S.Timestamp_us -> I64.to_int64 (F.view_int64 p column row)
  | S.Timestamp_ns -> I64.to_int64 (F.view_int64 p column row)
  | S.Timestamp_tz -> I64.to_int64 (F.view_int64 p column row)
  | S.Int32 -> I32.to_int32 (F.view_int32 p column row)
  | S.Date -> I32.to_int32 (F.view_int32 p column row)
  | S.Int16 -> Stdlib_stable.Int16.of_int (F.view_int16 p column row)
  | S.Int8 -> Stdlib_stable.Int8.of_int (F.view_int8 p column row)
  | S.Bool -> F.view_bool p column row
  | S.Float64 -> F64.to_float (F.view_double p column row)
  | S.Float32 -> F32.to_float32 (F.view_float p column row)
  | S.String -> F.chunk_string p column row
  | S.Blob -> F.chunk_string p column row
let plan : type a. a Codec.plan -> F.prepared @ local -> int -> int -> a = fun plan p column row ->
  match plan with
  | Codec.Identity s -> base s p column row
  | Codec.Plan { scalar; decode; _ } ->
    match decode (base scalar p column row) with
    | Ok a -> a
    | Error reason -> Stdlib.raise_notrace (Rejected { column; reason })
let get : type a n. (a, n) Codec.t -> F.prepared @ local -> int -> int -> a = fun codec p column row ->
  match codec with
  | Codec.Non_null pl -> plan pl p column row
  | Codec.Nullable pl -> if F.view_valid p column row then Some (plan pl p column row) else None

let rec curried : type l f r. (l, f, r) Fields.t -> f -> F.prepared @ local -> column:int -> int -> r =
  fun fields fn p ~column row ->
  match fields with
  | Fields.[] -> fn
  | Fields.(c :: rest) -> let x = get c p column row in curried rest (fn x) p ~column:(column + 1) row

(* Saturated application up to arity 8. Each argument is bound in column
   order, so the leftmost failure is the one raised. *)
let row : type l f r. (l, f, r) Fields.t -> f -> Borrowed_chunk.t @ local -> int -> r =
  fun fields fn chunk index ->
  let p = chunk.Borrowed_chunk.native in
  match fields with
  | Fields.[] -> fn
  | Fields.[ a ] -> fn (get a p 0 index)
  | Fields.[ a; b ] -> let a = get a p 0 index in let b = get b p 1 index in fn a b
  | Fields.[ a; b; c ] ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in fn a b c
  | Fields.[ a; b; c; d ] ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in
    let d = get d p 3 index in fn a b c d
  | Fields.[ a; b; c; d; e ] ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in
    let d = get d p 3 index in let e = get e p 4 index in fn a b c d e
  | Fields.[ a; b; c; d; e; f ] ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in
    let d = get d p 3 index in let e = get e p 4 index in let f = get f p 5 index in fn a b c d e f
  | Fields.[ a; b; c; d; e; f; g ] ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in
    let d = get d p 3 index in let e = get e p 4 index in let f = get f p 5 index in
    let g = get g p 6 index in fn a b c d e f g
  | Fields.(a :: b :: c :: d :: e :: f :: g :: h :: rest) ->
    let a = get a p 0 index in let b = get b p 1 index in let c = get c p 2 index in
    let d = get d p 3 index in let e = get e p 4 index in let f = get f p 5 index in
    let g = get g p 6 index in let h = get h p 7 index in
    curried rest (fn a b c d e f g h) p ~column:8 index
