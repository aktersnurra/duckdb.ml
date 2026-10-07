(** One flat error: where it happened and why. *)
type context =
  | Database | Connection | Transaction
  | Query of string | Table of { schema : string; name : string } | Parquet of string
type cause =
  | Invalid_configuration of string | Embedded_nul | Closed | Busy | Cancelled
  | Native of string | Unsupported_statement | Effects_not_allowed
  | Type_mismatch of { index : int; expected : string; actual : string }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Length_mismatch of { column : int; expected : int; actual : int }
  | Unbound_parameter of int
  | Parameter_count of { expected : int; actual : int }
  | Column_count of { expected : int; actual : int }
  | Parameter_schema_changed
  | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
  | Unknown_column of { name : string } | Missing_column of { name : string }
  | Unknown_table of { schema : string; name : string }
  | Constraint_mismatch of { constraint_kind : string; expected : string; actual : string }
  | Encode_rejected of { index : int; reason : Base.Error.t }
  | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
  | Destination_exists | Unsupported_parquet_type of { column : int; actual : string }
  | Rollback_failed of { primary : t; rollback : t }
and t = { context : context; cause : cause }
exception Cleanup_exception of t * exn

(* Attaches [context] to a core cause. *)
val within : context -> ('a, cause) result -> ('a, t) result

(* Engine type id to its SQL name; unknown ids render as "type <id>". *)
val type_name : int -> string
