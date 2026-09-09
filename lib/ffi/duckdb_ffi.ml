type database
type connection
external database_owner : unit -> database = "ml_duckdb_database_owner"
external connection_owner : database -> connection = "ml_duckdb_connection_owner"
external open_database : database -> string -> int -> int -> bool -> unit = "ml_duckdb_open"
external connect : connection -> unit = "ml_duckdb_connect"
external execute : connection -> string -> bool -> unit = "ml_duckdb_execute"
type control_statement = Begin | Commit | Rollback
external execute_control : connection -> control_statement -> unit = "ml_duckdb_execute_control"
external database_status : database -> int = "ml_duckdb_database_status" [@@noalloc]
external database_message : database -> string = "ml_duckdb_database_message"
external connection_status : connection -> int = "ml_duckdb_connection_status" [@@noalloc]
external connection_message : connection -> string = "ml_duckdb_connection_message"
external clear_work : connection -> unit = "ml_duckdb_clear_work" [@@noalloc]
external close_database : database -> unit = "ml_duckdb_close_database"
external close_connection : connection -> unit = "ml_duckdb_close_connection"
external finish_database_close : database -> unit = "ml_duckdb_finish_database_close" [@@noalloc]
external finish_connection_close : connection -> unit = "ml_duckdb_finish_connection_close" [@@noalloc]
external interrupt : connection -> unit = "ml_duckdb_interrupt" [@@noalloc]

module Native_request = struct
  type slot
  type t = { slot : slot; mutable owner_root : connection option }
  type installation = { request : t; connection : connection; root : connection option }
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

  external create_slot : unit -> slot = "ml_duckdb_native_request_create"
  external cancel_slot : slot -> unit = "ml_duckdb_native_request_cancel" [@@noalloc]
  external install_slot : connection -> slot -> install_result = "ml_duckdb_native_request_install" [@@noalloc]
  external reserve_slot : slot -> reserve_result = "ml_duckdb_native_request_reserve_delivery" [@@noalloc]
  external interrupt_slot : slot -> interrupt_result = "ml_duckdb_native_request_try_interrupt" [@@noalloc]
  external deliver_slot : slot -> interrupt_result = "ml_duckdb_native_request_deliver"
  external retire_slot : slot -> unit = "ml_duckdb_native_request_retire_delivery" [@@noalloc]
  external uninstall_slot : slot -> uninstall_result = "ml_duckdb_native_request_uninstall" [@@noalloc]
  external dispose_slot : slot -> bool = "ml_duckdb_native_request_dispose" [@@noalloc]

  let create () = { slot = create_slot (); owner_root = None }
  let cancel request = cancel_slot request.slot
  let prepare_install connection request = { request; connection; root = Some connection }
  let try_install_prepared installation =
    (* Every root was allocated before request synchronization. No allocation or
       runtime transition separates native binding from ML root publication. *)
    let result = install_slot installation.connection installation.request.slot in
    (match result with
     | Installed -> installation.request.owner_root <- installation.root
     | Install_contended | Connection_closed | Connection_leased | Request_used | Connection_active -> ());
    result
  let try_install connection request = try_install_prepared (prepare_install connection request)
  let reserve_delivery request = reserve_slot request.slot
  let try_interrupt request = interrupt_slot request.slot
  let deliver request = deliver_slot request.slot
  let retire_delivery request = retire_slot request.slot
  let try_uninstall request =
    let result = uninstall_slot request.slot in
    (* Keep the actual ML owner slot live through the native reference drop. *)
    ignore (Sys.opaque_identity request.owner_root);
    (match result with
     | Uninstalled -> request.owner_root <- None
     | Uninstall_contended | Native_work_pending | Delivery_pending | Not_installed -> ());
    result
  let dispose request =
    if dispose_slot request.slot then Ok () else Error Still_installed
end

external live_resources : unit -> int = "ml_duckdb_live_resources" [@@noalloc]
external fallback_reclaims : unit -> int = "ml_duckdb_fallback_reclaims" [@@noalloc]

type prepared
external prepared_owner : connection -> prepared = "ml_duckdb_prepared_owner"
external prepare : prepared -> string -> unit = "ml_duckdb_prepare"
external prepared_status : prepared -> int = "ml_duckdb_prepared_status" [@@noalloc]
external prepared_message : prepared -> string = "ml_duckdb_prepared_message"
external parameter_count : prepared -> int = "ml_duckdb_parameter_count" [@@noalloc]
external parameter_type : prepared -> int -> int = "ml_duckdb_parameter_type" [@@noalloc]
external bind_null : prepared -> int -> unit = "ml_duckdb_bind_null"
external bind_int64 : prepared -> int -> int -> int64 -> unit = "ml_duckdb_bind_int64"
external bind_float : prepared -> int -> int -> float -> unit = "ml_duckdb_bind_float"
external bind_string : prepared -> int -> int -> string -> unit = "ml_duckdb_bind_string"
external reset : prepared -> unit = "ml_duckdb_reset"
external execute_prepared : prepared -> unit = "ml_duckdb_execute_prepared"
external fetch : prepared -> int = "ml_duckdb_fetch"
external close_result : prepared -> unit = "ml_duckdb_close_result"
external finish_result_close : prepared -> unit = "ml_duckdb_finish_result_close" [@@noalloc]
external close_prepared : prepared -> unit = "ml_duckdb_close_prepared"
external finish_prepared_close : prepared -> unit = "ml_duckdb_finish_prepared_close" [@@noalloc]
external clear_prepared_input : prepared -> unit = "ml_duckdb_clear_prepared_input" [@@noalloc]
external column_count : prepared @ local -> int = "ml_duckdb_column_count" [@@noalloc]
external column_type : prepared @ local -> int -> int = "ml_duckdb_column_type" [@@noalloc]
external chunk_length : prepared @ local -> int = "ml_duckdb_chunk_length" [@@noalloc]
external chunk_valid : prepared @ local -> int -> int -> bool = "ml_duckdb_chunk_valid" [@@noalloc]
external chunk_int64 : prepared @ local -> int -> int -> int64#
  = "ml_duckdb_chunk_int64" "ml_duckdb_chunk_int64_unboxed" [@@noalloc]
external box_int64 : int64# -> int64 = "%box_int64"
external chunk_float : prepared @ local -> int -> int -> float = "ml_duckdb_chunk_float"
external chunk_string : prepared @ local -> int -> int -> string = "ml_duckdb_chunk_string"

type appender
type append_cell = int * bool * int64 * float * string
external appender_owner : connection -> appender = "ml_duckdb_appender_owner"
external create_appender : appender -> string -> string -> unit = "ml_duckdb_create_appender"
external appender_status : appender -> int = "ml_duckdb_appender_status" [@@noalloc]
external appender_message : appender -> string = "ml_duckdb_appender_message"
external appender_types : appender -> int array = "ml_duckdb_appender_types"
external appender_nullable : appender -> bool array = "ml_duckdb_appender_nullable"
external append_rows : appender -> append_cell array array -> unit = "ml_duckdb_append_rows"
external clear_appender_input : appender -> unit = "ml_duckdb_clear_appender_input" [@@noalloc]
external flush_appender : appender -> unit = "ml_duckdb_flush_appender"
external close_appender : appender -> bool -> unit = "ml_duckdb_close_appender"
external finish_appender_close : appender -> unit = "ml_duckdb_finish_appender_close" [@@noalloc]
external appender_is_closed : appender -> bool = "ml_duckdb_appender_is_closed" [@@noalloc]
external prepared_kind : prepared -> int = "ml_duckdb_prepared_kind" [@@noalloc]
external prepared_column_types : prepared -> int array = "ml_duckdb_prepared_column_types"
type local_file_work
external local_file_work : unit -> local_file_work = "ml_duckdb_local_file_work"
external publish_local_file : local_file_work -> string -> string -> int = "ml_duckdb_publish_local_file"
type file_admission = File_admitted | File_cancelled
external admit_local_file : connection -> file_admission = "ml_duckdb_admit_local_file"
external publish_local_file_admitted : connection -> local_file_work -> string -> string -> int = "ml_duckdb_publish_local_file_admitted"
external remove_local_file : local_file_work -> string -> int = "ml_duckdb_remove_local_file"
external finish_local_file_work : local_file_work -> unit = "ml_duckdb_finish_local_file_work" [@@noalloc]
external file_error_message : int -> string = "ml_duckdb_file_error_message"
external file_exists_error : int -> bool = "ml_duckdb_file_exists_error" [@@noalloc]
