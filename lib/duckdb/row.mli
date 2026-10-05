(** An owned decoder describes every result column in order. Schema types are
    checked before fetching (even for an empty result). Non-null codecs reject
    NULL per row; DuckDB arbitrary-SQL metadata does not prove non-nullability. *)
type _ t =
  | Empty : unit t
  | Column : ('a, _) Codec.t * 'b t -> ('a * 'b) t
  | Map : 'a t * ('a -> 'b) -> 'b t
