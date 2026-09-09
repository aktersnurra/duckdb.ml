type t =
  | Open_failed of string
  | Connect_failed
  | Query_failed of string
  | Unsupported_schema
  | Allocation_failed
  | Embedded_nul
