open Resource

type appender

(** Opens a child in the current database and explicit schema (default main).
    Holds the transaction snapshot and reserves the connection until close.
    Other token operations return Busy. Names use their stored catalog spelling.
    Generated-column tables and metadata larger than one native chunk are rejected.
    An unclosed manual child at transaction exit forces rollback. *)
val open_appender : transaction -> ?schema:string -> string -> (appender, error) result

(** Staging writes only this appender's own chunks and runs outside admission
    (through [native]). [append_staged] then appends them in one admission: a
    poisoned/closed appender reports its failure first, then [null] (a NULL
    staged into a NOT NULL column, as (column, row)) poisons, then an engine
    error (including an automatic flush) or interrupted native work poisons
    this appender and the transaction. Ignoring it cannot commit previous rows.
    Later operations return the first error; close still destroys the handle.
    Staging is cleared on every exit. *)
val native : appender -> Duckdb_ffi.appender
val nullable : appender -> int -> bool
val append_staged : appender -> null:(int * int) option -> (unit, error) result
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
