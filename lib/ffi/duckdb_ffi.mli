(** UNSAFE low-level bridge, not the safe API contract. No concurrent calls
    (except independently lifetime/identity-synchronized [interrupt]), use after
    owner release, or database close with children is allowed. Callers establish
    async exception boundaries and cleanup before acquisition/work.
    Owners start empty; open/connect each at most once. [close_*] clears native
    resources but retains the shell; [finish_*_close] also releases that shell and
    clears the custom slot, idempotently. Status/message require a live shell.
    Execute's boolean is true only for internal transaction-control SQL; false
    applies the safe layer's single-statement/type allowlist. Status 0 is success,
    1 a native error, 2 an unsupported statement, and 3 cancellation-suppressed
    raw execute admission. Execute with false and Query prepare/execute/fetch
    admit interruptible subcalls; true control SQL remains noninterruptible. *)
type database
type connection
val database_owner : unit -> database
val connection_owner : database -> connection
val open_database : database -> string -> int -> int -> bool -> unit
val connect : connection -> unit
val execute : connection -> string -> bool -> unit

(** Fixed private control SQL. Begin/Commit are individually interruptible and
    latch-admitted; Rollback is exclusive noninterruptible cleanup. Status 3
    means no control call was admitted. The legacy bool entry is unchanged. *)
type control_statement = Begin | Commit | Rollback
val execute_control : connection -> control_statement -> unit
val database_status : database -> int
val database_message : database -> string
val connection_status : connection -> int
val connection_message : connection -> string
val clear_work : connection -> unit
val close_database : database -> unit
val close_connection : connection -> unit

(** Nonallocating held-runtime-lock completion, after exclusive draining only.
    May block. Used on interrupted close entry and as finalizer fallback. *)
val finish_database_close : database -> unit
val finish_connection_close : connection -> unit

(** Internal seam, not cancellation: caller must independently synchronize
    lifetime and operation identity. Never expose as a public cancellation API. *)
val interrupt : connection -> unit

(** Unsafe, provisional lifecycle used by private Resource. Raw execute and
    Query extraction/prepare/execute/fetch subcalls admit USER delivery. Query
    bind/reset and Appender scalar mutations admit without delivery. Named
    Begin/Commit admit USER; Rollback is noninterruptible cleanup. Filesystem
    reservation/publication decisions never enable delivery. Delivery
    responsiveness is provisional and not a guarantee.

    Callers exclusively serialize worker operations on requests and owner trees,
    including close, disposal and GC root bookkeeping. The sole system-thread
    controller may reserve/deliver/retire while admitted user work runs; it must retain
    the entire owner/request graph and join before detach/disposal/close.
    Runtime serialization does NOT make these externals domain-safe. Install
    only on an idle connected owner. Foreign activity is separate from cleanup
    eligibility. Detach after foreign completion and reservation retirement,
    before explicit owner/parent close. Other concurrent unsafe work is unsupported.

    A request binds successfully at most once; failed installation leaves a fresh
    request fresh. While bound it retains the ML connection slot and a native
    shell reference. The owner's request pointer is non-owning. Live work and any
    sole controller/selected attempt MUST retain the entire request until
    completion/retirement. Root all live children as well: an unreachable bound
    request or child must be quiescent, with no same-owner guard user. Finalizers
    try once, fail closed on invariant violation and never wait. Native references
    are released outside the guard. Finalizer order need not preserve ML roots
    once both are dead; the native shell reference handles that case. Fallback
    destruction may block. Held-runtime controller entries serialize with
    held-runtime finalizers; no guard is held while releasing the runtime. *)
module Native_request : sig
  type t
  type installation
  type install_result =
    | Installed
    | Install_contended
    | Connection_closed
    | Connection_leased
    | Request_used
    | Connection_active
  type uninstall_result =
    | Uninstalled
    | Uninstall_contended
    | Native_work_pending
    | Delivery_pending
    | Not_installed
  type reserve_result = Reserved | Ineligible | Reservation_pending
  type interrupt_result = Delivered | Skipped | Not_reserved
  type dispose_error = Still_installed

  val create : unit -> t

  (** Cancellation latches permanently. On disposed aliases it is a no-op. *)
  val cancel : t -> unit

  (** Preallocate all ML owner roots before taking request synchronization.
      An installation retains its request and connection until dropped; preparing
      it does not bind or consume either. The native single-use check is unchanged. *)
  val prepare_install : connection -> t -> installation

  (** Publication using preallocated roots; no ML allocation or runtime release. *)
  val try_install_prepared : installation -> install_result

  (** Convenience for callers not holding a request mutex. *)
  val try_install : connection -> t -> install_result

  (** At most one reservation, owned and retired only by the sole
      controller in a protected finally. No other caller may retire it. *)
  val reserve_delivery : t -> reserve_result
  val try_interrupt : t -> interrupt_result

  (** Normal allocating ABI; delegates immediately to the same nonblocking
      try-delivery. A test-linked wrapper may pause before that recheck. *)
  val deliver : t -> interrupt_result

  (** Idempotent with no reservation, including on disposed aliases. *)
  val retire_delivery : t -> unit
  val try_uninstall : t -> uninstall_result

  (** Deterministic and idempotent; refuses installed requests. Disposed aliases
      remain valid tombstones: install reports Request_used, uninstall
      Not_installed, reserve Ineligible, and interrupt Not_reserved. *)
  val dispose : t -> (unit, dispose_error) result
end

val live_resources : unit -> int

(** Advances around every CREATE/ALTER/DROP and when a transaction that ran
    one settles. Equal reads bracket a window with no visible schema change. *)
val schema_epoch : unit -> int
val fallback_reclaims : unit -> int

(** Unsafe prepared/result/chunk owner. Retains a native connection shell, not
    permission to use a closed connection. Caller exclusively serializes the
    entire child tree. All statuses/messages require a live owner. *)
type prepared
val prepared_owner : connection -> prepared
val prepare : prepared -> string -> unit
(* Native status ABI: 0 success, 1 native error (prepared_message),
   2 unsupported statement, 3 cancellation suppressed native admission.
   An admitted native failure retains status 1 and its original diagnostic. *)
val prepared_status : prepared -> int
val prepared_message : prepared -> string
val parameter_count : prepared -> int
val parameter_type : prepared -> int -> int
val bind_null : prepared -> int -> unit
val bind_int64 : prepared -> int -> int -> int64 -> unit
val bind_float : prepared -> int -> int -> float -> unit
val bind_string : prepared -> int -> int -> string -> unit
val reset : prepared -> unit
val execute_prepared : prepared -> unit
val fetch : prepared -> int
val close_result : prepared -> unit
val finish_result_close : prepared -> unit
val close_prepared : prepared -> unit
val finish_prepared_close : prepared -> unit
val clear_prepared_input : prepared -> unit
val column_count : prepared @ local -> int
val column_type : prepared @ local -> int -> int
val chunk_length : prepared @ local -> int
val chunk_valid : prepared @ local -> int -> int -> bool
val chunk_int64 : prepared @ local -> int -> int -> int64#
val box_int64 : int64# -> int64
val chunk_float : prepared @ local -> int -> int -> float
val chunk_string : prepared @ local -> int -> int -> string
external view_int64 : prepared @ local -> int -> int -> int64#
  = "ml_duckdb_view_int64_byte" "ml_duckdb_view_int64" [@@noalloc]
external view_int32 : prepared @ local -> int -> int -> int32#
  = "ml_duckdb_view_int32_byte" "ml_duckdb_view_int32" [@@noalloc]
external view_double : prepared @ local -> int -> int -> float#
  = "ml_duckdb_view_double_byte" "ml_duckdb_view_double" [@@noalloc]
external view_float : prepared @ local -> int -> int -> float32#
  = "ml_duckdb_view_float_byte" "ml_duckdb_view_float" [@@noalloc]
external view_int16 : prepared @ local -> int -> int -> int = "ml_duckdb_view_int16" [@@noalloc]
external view_int8 : prepared @ local -> int -> int -> int = "ml_duckdb_view_int8" [@@noalloc]
external view_bool : prepared @ local -> int -> int -> bool = "ml_duckdb_view_bool" [@@noalloc]
external view_valid : prepared @ local -> int -> int -> bool = "ml_duckdb_view_valid" [@@noalloc]
external view_first_null : prepared @ local -> int -> int -> int = "ml_duckdb_view_first_null" [@@noalloc]
external view_blit : prepared @ local -> int -> int -> ('a, 'b, Bigarray.c_layout) Bigarray.Array1.t @ local -> int -> unit
  = "ml_duckdb_view_blit" [@@noalloc]
external view_blit_validity : prepared @ local -> int -> int ->
  (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t @ local -> int -> unit
  = "ml_duckdb_view_blit_validity" [@@noalloc]

(** Unsafe transaction-owned appender. Batches are staged into the appender's
    own reusable data chunks, then appended chunk by chunk. Caller validates
    shape, types, NULL and ranges and owns transaction rollback. *)
type appender
val appender_owner : connection -> appender
val create_appender : appender -> string -> string -> unit
val appender_status : appender -> int
val appender_message : appender -> string
val appender_types : appender -> int array
val appender_nullable : appender -> bool array

(** Restricts the appender to the named catalog columns, given with their
    physical indices; omitted columns take defaults. Status reports failure. *)
val appender_select_columns : appender -> string array -> int array -> unit

(** Staging. [stage_begin a rows] prepares (and resets) chunks for [rows] rows;
    the [stage_*] writers then set (column, row) in the active column order,
    converting to the column's physical type. Writes outside the staged range,
    of the wrong kind for the column, or to a closed appender are ignored.
    [append_staged] appends every staged chunk in one native work section and
    clears the staging; [clear_stage] drops it without appending. *)
external stage_begin : appender -> int -> unit = "ml_duckdb_stage_begin" [@@noalloc]
external stage_int64 : appender -> int -> int -> int64# -> unit
  = "ml_duckdb_stage_int64_byte" "ml_duckdb_stage_int64" [@@noalloc]
external stage_float : appender -> int -> int -> float# -> unit
  = "ml_duckdb_stage_float_byte" "ml_duckdb_stage_float" [@@noalloc]
external stage_string : appender -> int -> int -> string -> unit = "ml_duckdb_stage_string" [@@noalloc]
external stage_null : appender -> int -> int -> unit = "ml_duckdb_stage_null" [@@noalloc]
external clear_stage : appender -> unit = "ml_duckdb_clear_stage" [@@noalloc]
val append_staged : appender -> unit
val flush_appender : appender -> unit
val close_appender : appender -> bool -> unit
val finish_appender_close : appender -> unit
val appender_is_closed : appender -> bool

val prepared_kind : prepared -> int

(** CREATE, ALTER or DROP: executing it advances [schema_epoch]. *)
val prepared_changes_schema : prepared -> bool
val prepared_column_types : prepared -> int array

(** Local no-replace hard-link publication; returns errno (0 on success).
    Inputs are copied before releasing the runtime lock. One publish/remove per
    work owner; finish is idempotent. Remove treats ENOENT as success for cleanup
    retry, but reports other errno values. *)
type local_file_work
val local_file_work : unit -> local_file_work
val publish_local_file : local_file_work -> string -> string -> int

(** Noninterruptible native decision for one immediate filesystem reservation.
    Caller holds exclusive Resource admission across this AND the reservation.
    No reusable ticket; phase/work ends before return. *)
type file_admission = File_admitted | File_cancelled
val admit_local_file : connection -> file_admission

(** Same no-replace link, with the owner's persistent latch decision before
    actual link. Caller holds exclusive transaction admission and roots owner.
    Returns -1 if suppressed, otherwise 0/errno; never enables interruption. *)
val publish_local_file_admitted : connection -> local_file_work -> string -> string -> int
val remove_local_file : local_file_work -> string -> int
val finish_local_file_work : local_file_work -> unit
val file_error_message : int -> string
val file_exists_error : int -> bool

(** Typed views of the integer ABI above; the integer entries stay for callers
    that inspect raw codes. *)
module Status : sig
  (** [Native_failure] carries its diagnostic in the owner's [*_message];
      [Suppressed] means the cancellation latch refused native admission. *)
  type t = Success | Native_failure | Unsupported | Suppressed
  val of_code : int -> t
end

(** [Fetch_failed] always leaves a non-success [prepared_status]. *)
type fetch_outcome = Chunk | Exhausted | Fetch_failed
val next_chunk : prepared -> fetch_outcome

(** DuckDB [duckdb_type] identifiers used by the safe layer. *)
module Type_id : sig
  val invalid : int
  val boolean : int
  val tinyint : int
  val smallint : int
  val integer : int
  val bigint : int
  val float : int
  val double : int
  val timestamp : int
  val date : int
  val varchar : int
  val blob : int
  val timestamp_s : int
  val timestamp_ms : int
  val timestamp_ns : int
  val timestamp_tz : int
  val any : int
end

(** DuckDB [duckdb_statement_type] identifiers used by the safe layer. *)
module Statement_kind : sig
  val select : int
end
