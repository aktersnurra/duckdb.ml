(** Private stage-1 errors, not a proposed public error model. *)
type t =
  | Open_failed of string
  | Connect_failed
  | Query_failed of string
  | Unsupported_schema
  | Allocation_failed
  | Embedded_nul
