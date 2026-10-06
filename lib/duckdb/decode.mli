(* Fast decoding of whole rows from a borrowed chunk whose result types were
   validated. *)
exception Rejected of { column : int; reason : Base.Error.t }

(* Rows [0, limit) can take the fast path: every declared column has exactly
   its declared engine type in this chunk and no non-null column has a NULL
   before [limit]. The engine type is per result; it can differ from the
   declared one only when validation accepted an unresolved type. *)
val limit : (_, _, _) Fields.t -> Borrowed_chunk.t @ local -> length:int -> int

(* Decodes row [row]; raises [Rejected] for a custom decoder's rejection,
   evaluating columns left to right. Only for rows below [limit]. *)
val row : ('l, 'f, 'r) Fields.t -> 'f -> Borrowed_chunk.t @ local -> int -> 'r
