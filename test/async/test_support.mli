val require : string -> bool -> unit
val ok : ('a, 'e) result -> 'a
val wait_scheduler : (unit -> bool) -> unit Async.Deferred.t
val wait_worker : bool Stdlib.Atomic.t -> unit
val reset : int -> unit
val observe_callback_cleanup : bool -> unit
val callback_cleanup_observations : unit -> int
val callback_cleanup_is_clear : unit -> bool
val observe_explicit_flush : unit -> unit
val explicit_flush_observations : unit -> int
external opens : unit -> int = "stage4c_opens" [@@noalloc]
external connects : unit -> int = "stage4c_connects" [@@noalloc]
external disconnects : unit -> int = "stage4c_disconnects" [@@noalloc]

(** Test-only ML insertion points, inactive in the equivalence control. *)
exception Injected_dispatch
exception Injected_reservation
exception Injected_worker
val fail_worker : bool -> unit
val configure : reserve_at:int -> dispatch_at:int -> entry:bool -> returned:bool -> unit
val before_reserve : unit -> unit
val helper_released : unit -> unit
val before_dispatch : unit -> unit
val worker_entry : unit -> unit
val worker_returned : unit -> unit
val entry_seen : unit -> bool
val return_seen : unit -> bool
val release_workers : unit -> unit
val reservation_count : unit -> int
val release_count : unit -> int
val dispatch_count : unit -> int

(** Native gates run only at existing unlocked engine boundaries. *)
type seam = Open | Connect | Execute | Execute_return | Rollback | Result
  | Prepared | Extracted | Chunk | Appender_clear | Appender_destroy
  | Disconnect | Database_close | Fetch | Commit | Commit_return | Prepared_return
  | Appender_end_row | Appender_flush
val hold_publication : bool -> unit
val publication_entries : unit -> int
val temporary_unlinks : unit -> int
val seam_id : seam -> int
val native_hold : seam -> unit
val native_release : seam -> unit
val native_entered : seam -> int
val native_release_all : unit -> unit
external interrupts : unit -> int = "stage4c_interrupts" [@@noalloc]
external executions : unit -> int = "stage4c_executions" [@@noalloc]
external native_errors : unit -> int = "stage4c_native_errors" [@@noalloc]
external joins : unit -> int = "stage4c_joins" [@@noalloc]
external locked_calls : unit -> int = "stage4c_locked_calls" [@@noalloc]
external commits : unit -> int = "stage4c_commits" [@@noalloc]
external appender_end_rows : unit -> int = "stage4c_appender_end_rows" [@@noalloc]
external appender_end_row_errors : unit -> int = "stage4c_appender_end_row_errors" [@@noalloc]
external select_appender_end_row : int -> unit = "stage4c_select_appender_end_row" [@@noalloc]
external appender_flushes : unit -> int = "stage4c_appender_flushes" [@@noalloc]
external metadata_changes : unit -> int = "stage4c_metadata_changes" [@@noalloc]
external select_parquet_first : bool -> unit = "stage4c_select_parquet_first" [@@noalloc]
external parquet_second_exec : unit -> int = "stage4c_parquet_second_exec" [@@noalloc]
external hold_selected : bool -> unit = "stage4c_hold_selected" [@@noalloc]
external selected_seen : unit -> bool = "stage4c_selected_seen" [@@noalloc]
external distinct_interrupted : unit -> int = "stage4c_distinct_interrupted" [@@noalloc]
exception Cleanup_failure
exception Cleanup_failure_index of int
external indexed_close_failure : bool -> unit = "stage4c_indexed_close_failure" [@@noalloc]
val register_cleanup_failure : unit -> unit
external fail_close : bool -> unit = "stage4c_fail_close" [@@noalloc]
external fail_rollback : int -> unit = "stage4c_fail_rollback" [@@noalloc]
external force_locked_destructor : bool -> unit = "stage4c_force_locked_destructor" [@@noalloc]
