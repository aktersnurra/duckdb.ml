open Resource

type path

(** Exact local filenames only: nonempty, NUL/colon/backslash/glob-free.
    Relative names are made absolute at construction; tilde is not expanded.
    No URI, remote storage, glob expansion or extension management. *)
val path : string -> (path, error) result

(** Export one engine-parsed, parameter-free SELECT through DuckDB COPY.
    Omit a trailing statement terminator. The destination is a bound parameter.
    Only supported scalar types are accepted; TIMESTAMP_S/MS are rejected
    because this pinned writer/reader normalizes them to microseconds. Explicit
    SQL conversion opts into that change. No implicit overwrite: a same-parent
    private temporary file is copied, then hard-linked without replacing an
    existing destination. Only that owned temporary file is cleaned up.
    Filesystem effects are not rolled back by DuckDB transactions. A failure or
    interruption during/after publication can follow a published output. No
    crash durability, hostile-directory or atomic transaction/file claim. *)
val export : connection -> query:string -> path -> (unit, error) result
val fold : connection -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a Query.step, Request.request_error) result) -> ('a, Request.request_error) result
val fold_table : connection -> path list -> (_, 'row) Request.table -> init:'a ->
  f:('row -> 'a -> ('a Query.step, Request.request_error) result) -> ('a, Request.request_error) result
