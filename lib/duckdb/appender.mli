open Resource

(** Complete owned rows, not a decoder. Every cell carries its exact witness.
    [None] is NULL. Entire batches are checked before any native row mutation;
    NOT NULL columns reject [None] there. *)
type cell = Cell : 'a Scalar.t * 'a option -> cell
type appender

(** Opens a child in the current database and explicit schema (default main).
    Holds the transaction snapshot and reserves the connection until close.
    Other token operations return Busy. Names use their stored catalog spelling.
    Generated-column tables and metadata larger than one native chunk are rejected.
    An unclosed manual child at transaction exit forces rollback. *)
val open_appender : transaction -> ?schema:string -> string -> (appender, error) result

(** One admission/unlock for a complete batch. An engine error (including an
    automatic flush), interrupted native work, or validation error poisons this
    appender and the transaction. Ignoring it cannot commit previous rows.
    Later operations return the first error; close still destroys the handle. *)
val append_rows : appender -> cell list list -> (unit, error) result
val flush_appender : appender -> (unit, error) result

(** Flushes on success, then clears/destroys. Never commits the transaction.
    Poisoned owners discard buffered data; repeated completed close succeeds.
    Failure after an auto/explicit flush requires outer rollback. *)
val close_appender : appender -> (unit, error) result

(* Private typed-table seam. [select_columns] restricts an open appender to the
   named catalog columns (with their physical indices); omitted columns take
   their defaults and [types] then follows the active order. *)
val child : appender -> child
val types : appender -> int array
val select_columns : appender -> names:string array -> indices:int array -> (unit, error) result
