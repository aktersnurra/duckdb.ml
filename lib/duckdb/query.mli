open Resource

(** Prepared statements retain their parent. Bindings persist across execution;
    [reset] clears all of them. SQL policy is identical to [execute]. Manual
    parent close rejects live children; scopes drain and close them. A statement
    prepared through a transaction is revoked/closed before its settlement. *)
type prepared
type query_result
type chunk
type 'a step = Continue of 'a | Stop of 'a
val prepare : connection -> string -> (prepared, error) result
val prepare_transaction : transaction -> string -> (prepared, error) result
val close_prepared : prepared -> (unit, error) result
val parameter_count : prepared -> (int, error) result

(** One-based parameter indices; known engine parameter types must match exactly.
    Unresolved ANY/INVALID parameters accept the supplied witness. Rebinding is
    allowed; NULL is supplied as [Nullable witness, None]. Index/type/range errors
    leave previous bindings unchanged; native bind failure/interruption marks
    that parameter unbound. Reset failure/interruption marks all unbound. *)
val bind : prepared -> int -> 'a Scalar.field -> 'a -> (unit, error) result
val reset : prepared -> (unit, error) result

(** All parameters must be bound. The result exclusively leases the connection
    until closed; reset/reexecute/prepared close return Live_children. *)
val execute_prepared : prepared -> (query_result, error) result
val close_result : query_result -> (unit, error) result
val with_prepared : connection -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result
val with_prepared_transaction : transaction -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result

(** After admission, consumes/closes the result on every exit. Busy admission
    rejects without consuming it. The callback is synchronous, local,
    and guarded against outward effects. No owner transition is exposed through
    a chunk. Aliases attempting mutation/fetch/close during a callback get Busy.
    Required NULL fields fail on access, not on empty-result schema validation. *)
val fold_chunks : query_result -> init:'a -> f:(chunk @ local -> 'a -> ('a step, error) result) -> ('a, error) result
val chunk_length : chunk @ local -> int

(** Zero-based column and row indices, checked before reading. Each access
    validates the exact engine type; returned strings/blobs/scalars are owned. *)
val column : chunk @ local -> column:int -> row:int -> 'a Scalar.field -> ('a, error) result
val fold_rows : query_result -> 'row Row.t -> init:'a -> f:('row -> 'a -> ('a step, error) result) -> ('a, error) result
