open Resource

(** Complete owned rows, not a decoder. Every cell carries its exact witness.
    Required cells cannot represent NULL. Entire batches are checked before any
    native row mutation, including table NOT NULL constraints. *)
type cell = Cell : 'a Scalar.field * 'a -> cell
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

(** The connection scope owns BEGIN/COMMIT/ROLLBACK; the transaction scope
    never settles its caller. Callback errors/exceptions/effect denial poison
    settlement even after manual appender close. Unjoined admitted work is
    drained on exit; a Busy implicit close rolls back rather than committing. *)
val with_appender : connection -> ?schema:string -> string -> f:(appender -> ('a, error) result) -> ('a, error) result
val with_appender_transaction : transaction -> ?schema:string -> string -> f:(appender -> ('a, error) result) -> ('a, error) result
