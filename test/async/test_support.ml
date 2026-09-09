module System_thread = Thread
open! Core
open! Async
let require name pass = if not pass then failwith name
let ok = function Ok x -> x | Error _ -> failwith "expected success"
let wait_scheduler predicate =
  let start = Time_ns.now () in
  let rec loop () =
    if predicate () then return ()
    else if Time_ns.Span.( > ) (Time_ns.diff (Time_ns.now ()) start) (Time_ns.Span.of_sec 10.)
    then failwith "scheduler handshake failed"
    else Clock_ns.after (Time_ns.Span.of_ms 1.) >>= loop
  in loop ()
let wait_worker gate =
  let rec loop () = if Stdlib.Atomic.get gate then () else (System_thread.delay 0.001; loop ()) in loop ()
let callback_observations = Stdlib.Atomic.make 0
let callback_tls_clear = Stdlib.Atomic.make true
let explicit_flushes = Stdlib.Atomic.make 0
external native_reset : int -> unit = "stage4c_reset" [@@noalloc]
let reset at =
  native_reset at;
  Stdlib.Atomic.set callback_observations 0;
  Stdlib.Atomic.set callback_tls_clear true;
  Stdlib.Atomic.set explicit_flushes 0
let observe_callback_cleanup clear =
  Stdlib.Atomic.incr callback_observations;
  if not clear then Stdlib.Atomic.set callback_tls_clear false
let callback_cleanup_observations () = Stdlib.Atomic.get callback_observations
let callback_cleanup_is_clear () = Stdlib.Atomic.get callback_tls_clear
let observe_explicit_flush () = Stdlib.Atomic.incr explicit_flushes
let explicit_flush_observations () = Stdlib.Atomic.get explicit_flushes
external opens : unit -> int = "stage4c_opens" [@@noalloc]
external connects : unit -> int = "stage4c_connects" [@@noalloc]
external disconnects : unit -> int = "stage4c_disconnects" [@@noalloc]
exception Injected_dispatch
exception Injected_reservation
exception Injected_worker
let worker_failure = Stdlib.Atomic.make false
let fail_worker enabled = Stdlib.Atomic.set worker_failure enabled
let reserve_at = ref (-1)
let dispatch_at = ref (-1)
let reserved = ref 0
let released = ref 0
let dispatched = ref 0
let entry_gate = Stdlib.Atomic.make true
let return_gate = Stdlib.Atomic.make true
let entered_worker = Stdlib.Atomic.make false
let returned_worker = Stdlib.Atomic.make false
let configure ~reserve_at:r ~dispatch_at:d ~entry ~returned =
  reserve_at := r; dispatch_at := d;
  reserved := 0; released := 0; dispatched := 0;
  Stdlib.Atomic.set entry_gate (not entry); Stdlib.Atomic.set return_gate (not returned);
  Stdlib.Atomic.set entered_worker false; Stdlib.Atomic.set returned_worker false
let before_reserve () =
  if !reserved = !reserve_at then raise Injected_reservation;
  incr reserved
let helper_released () = incr released
let before_dispatch () =
  let index = !dispatched in incr dispatched;
  if index = !dispatch_at then raise Injected_dispatch
let worker_entry () =
  Stdlib.Atomic.set entered_worker true; wait_worker entry_gate;
  if Stdlib.Atomic.get worker_failure then raise Injected_worker
let worker_returned () = Stdlib.Atomic.set returned_worker true; wait_worker return_gate
let entry_seen () = Stdlib.Atomic.get entered_worker
let return_seen () = Stdlib.Atomic.get returned_worker
let release_workers () = Stdlib.Atomic.set entry_gate true; Stdlib.Atomic.set return_gate true
let reservation_count () = !reserved
let release_count () = !released
let dispatch_count () = !dispatched
type seam = Open | Connect | Execute | Execute_return | Rollback | Result
  | Prepared | Extracted | Chunk | Appender_clear | Appender_destroy
  | Disconnect | Database_close | Fetch | Commit | Commit_return | Prepared_return
  | Appender_end_row | Appender_flush
external hold_publication : bool -> unit = "stage4c_hold_publication" [@@noalloc]
external publication_entries : unit -> int = "stage4c_publication_entries" [@@noalloc]
external temporary_unlinks : unit -> int = "stage4c_temporary_unlinks" [@@noalloc]
let seam_id = function Open -> 0 | Connect -> 1 | Execute -> 2 | Execute_return -> 3
  | Rollback -> 4 | Result -> 5 | Prepared -> 6 | Extracted -> 7 | Chunk -> 8
  | Appender_clear -> 9 | Appender_destroy -> 10 | Disconnect -> 11 | Database_close -> 12
  | Fetch -> 13 | Commit -> 14 | Commit_return -> 15 | Prepared_return -> 16
  | Appender_end_row -> 17 | Appender_flush -> 18
external set_native_gate : int -> bool -> unit = "stage4c_gate" [@@noalloc]
external entered_native : int -> int = "stage4c_entered" [@@noalloc]
let native_hold seam = set_native_gate (seam_id seam) true
let native_release seam = set_native_gate (seam_id seam) false
let native_entered seam = entered_native (seam_id seam)
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
let native_release_all () =
  for i = 0 to 18 do set_native_gate i false done;
  select_appender_end_row (-1); hold_selected false
external distinct_interrupted : unit -> int = "stage4c_distinct_interrupted" [@@noalloc]
exception Cleanup_failure
exception Cleanup_failure_index of int
external indexed_close_failure : bool -> unit = "stage4c_indexed_close_failure" [@@noalloc]
let register_cleanup_failure () =
  Stdlib.Callback.Safe.register_exception "stage4c_cleanup_failure" Cleanup_failure;
  Stdlib.Callback.Safe.register_exception "stage4c_cleanup_failure_index" (Cleanup_failure_index 0)
external fail_close : bool -> unit = "stage4c_fail_close" [@@noalloc]
external fail_rollback : int -> unit = "stage4c_fail_rollback" [@@noalloc]
external force_locked_destructor : bool -> unit = "stage4c_force_locked_destructor" [@@noalloc]
