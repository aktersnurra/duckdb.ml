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
    reservation/publication decisions never enable delivery. Complete B4 review
    and responsiveness gates remain open; these are not accepted guarantees.

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

(** Unsafe transaction-owned appender. Input cells are (type id, is-null,
    integer bits, floating value, bytes). Whole batches are copied before unlock.
    Caller validates shape, types, NULL and ranges and owns transaction rollback. *)
type appender
type append_cell = int * bool * int64 * float * string
val appender_owner : connection -> appender
val create_appender : appender -> string -> string -> unit
val appender_status : appender -> int
val appender_message : appender -> string
val appender_types : appender -> int array
val appender_nullable : appender -> bool array
val append_rows : appender -> append_cell array array -> unit
val clear_appender_input : appender -> unit
val flush_appender : appender -> unit
val close_appender : appender -> bool -> unit
val finish_appender_close : appender -> unit
val appender_is_closed : appender -> bool

val prepared_kind : prepared -> int
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
