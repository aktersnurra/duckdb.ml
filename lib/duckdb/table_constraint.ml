(* A declared table constraint, by column name, with its expressions
   rendered. Built once by [Table.declare]; used by create, verify and
   lookup. *)
type t =
  | Primary_key of string list
  | Unique of string list
  | Foreign_key of { columns : string list; table : string; references : string list }
  | Check of { sql : string; columns : string list }
  | Default of { column : string; sql : string }
