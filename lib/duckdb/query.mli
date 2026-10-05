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
    allowed; NULL is supplied as [None] to a nullable codec. The codec's encoder
    runs first, outside connection admission, so an [Encode_rejected] takes
    precedence over index/Busy/Closed/type errors. Encode/index/type/range errors
    leave previous bindings unchanged; native bind failure/interruption marks
    that parameter unbound. Reset failure/interruption marks all unbound. *)
val bind : prepared -> int -> ('a, _) Codec.t -> 'a -> (unit, error) result
(* Private: binds an already-encoded base value ([None] is NULL). *)
val bind_scalar : prepared -> int -> 'a Scalar.t -> 'a option -> (unit, error) result
val reset : prepared -> (unit, error) result

(** All parameters must be bound. The result exclusively leases the connection
    until closed; reset/reexecute/prepared close return Busy. *)
val execute_prepared : prepared -> (query_result, error) result
val close_result : query_result -> (unit, error) result
(* Scopes over any callback error type, as [Resource.scope]. *)
val with_prepared : lifting:'e lifting -> connection -> string ->
  f:(prepared -> ('a, 'e) result) -> ('a, 'e) result
val with_prepared_transaction : lifting:'e lifting -> transaction -> string ->
  f:(prepared -> ('a, 'e) result) -> ('a, 'e) result

(** After admission, consumes/closes the result on every exit. Busy admission
    rejects without consuming it. The callback is synchronous, local,
    and guarded against outward effects. No owner transition is exposed through
    a chunk. Aliases attempting mutation/fetch/close during a callback get Busy.
    Non-null codecs reject NULL on access, not on empty-result schema validation. *)
val fold_chunks : lifting:'e lifting -> query_result -> init:'a ->
  f:(chunk @ local -> 'a -> ('a step, 'e) result) -> ('a, 'e) result
(* Executes with the current bindings and folds the result inside its lease;
   no result handle escapes. Execution failures are lifted as the fold's. *)
val fold_prepared : lifting:'e lifting -> prepared -> init:'a ->
  f:(chunk @ local -> 'a -> ('a step, 'e) result) -> ('a, 'e) result
val chunk_length : chunk @ local -> int

(** Zero-based column and row indices, checked before reading. Each access
    validates the exact engine type; returned strings/blobs/scalars are owned.
    [Decode_rejected.row] and [Null.row] are chunk-relative. Errors are bare
    causes; the facade attaches the statement's SQL ([chunk_sql]). *)
val column : chunk @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, error) result

(* Private, engine-prepared SELECT metadata; no execution or result lease. *)
val select_schema : prepared -> (int array, error) result

(* Private typed-request seam. A cached statement is owned by its connection's
   statement cache instead of being a live child. *)
val prepare_cached : connection -> string -> (prepared, error) result
val child : prepared -> child

(* The statement's SQL, for error context. *)
val sql : prepared -> string
val result_sql : query_result -> string
val chunk_sql : chunk @ local -> string
val parameter_types : prepared -> int array

(* Engine result column types known at preparation (INVALID when unresolved). *)
val column_types : prepared -> (int array, error) result

(* Cancellation checkpoint on the result's connection, for per-row loops. *)
val result_checkpoint : query_result -> (unit, error) result

(* [fold_chunks] after [validate] accepts the result's column types; a cleanup
   exception is paired in [context]. *)
val fold_validated : context:Failure.context -> query_result -> validate:(int array -> (unit, error) result) -> init:'a ->
  f:(chunk @ local -> 'a -> ('a step, error) result) -> ('a, error) result
