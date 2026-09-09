open! Base
module F = Generated_bindings.Bindings (Generated_functions)
module Cleanup = Generated_bindings.Cleanup (Generated_cleanup_functions)
external arm : int -> int -> unit = "stage1_test_arm" [@@noalloc]
external injections : unit -> int = "stage1_test_injections" [@@noalloc]
external live_sql : unit -> int = "stage1_test_live_sql" [@@noalloc]
external arm_cleanup : unit -> unit = "stage1_test_arm_cleanup" [@@noalloc]
external sql_at_signal : unit -> int = "stage1_test_sql_at_signal" [@@noalloc]
external results_at_signal : unit -> int = "stage1_test_results_at_signal" [@@noalloc]
exception Body
let signals_handled = Stdlib.Atomic.make 0

let expect_signal f =
  match Stdlib.Sys.with_async_exns f with
  | exception Stdlib.Sys.Break -> ()
  | _ -> failwith "raising signal was not delivered"

let with_signal f =
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1
    (Stdlib.Sys.Signal_handle (fun _ -> Stdlib.Atomic.incr signals_handled; raise Stdlib.Sys.Break)) in
  Exn.protect ~f:(fun () -> f (); assert (Int.equal (Stdlib.Atomic.get signals_handled) 1)) ~finally:(fun () ->
    arm 0 0;
    Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous)

let assert_empty () =
  assert (Int.equal (live_sql ()) 0);
  assert (Int.equal (Handwritten_probe.live_results ()) 0)

let hand_enter () =
  expect_signal (fun () -> arm 1 0; Handwritten_probe.query_int64 "SELECT 42::BIGINT");
  assert (Int.equal (injections ()) 1);
  assert (Int.equal (sql_at_signal ()) 1);
  assert (Int.equal (results_at_signal ()) 0);
  (* Release can raise before the raw query returns an owner to OCaml.
     This path promises a finalizer backstop, NOT deterministic cleanup. *)
  Stdlib.Gc.compact ();
  Stdlib.Gc.compact ();
  assert_empty ();
  Stdlib.print_endline "hand-enter: SQL finalizer backstop=ok"

let hand_leave () =
  expect_signal (fun () -> arm 0 1; Handwritten_probe.query_int64 "SELECT 42::BIGINT");
  assert (Int.equal (injections ()) 1);
  assert (Int.equal (sql_at_signal ()) 0);
  assert (Int.equal (results_at_signal ()) 1);
  Stdlib.Gc.compact ();
  Stdlib.Gc.compact ();
  assert_empty ();
  Stdlib.print_endline "hand-leave: response handoff/finalizer backstop=ok"

let generated_cleanup () =
  let storage = Ctypes.CArray.of_string "SELECT 42::BIGINT" in
  let slot = Ctypes.CArray.make (Ctypes.ptr Ctypes.void) ~initial:Ctypes.null 1 in
  let pointer = Ctypes.CArray.start slot in
  F.query_into (Ctypes.CArray.start storage) pointer;
  (try
     Stdlib.Sys.with_async_exns (fun () -> Exn.protect
       ~f:(fun () -> arm_cleanup (); raise Body)
       ~finally:(fun () -> Cleanup.destroy_slot pointer))
   with Body | Stdlib.Sys.Break -> ());
  assert (Int.equal (results_at_signal ()) 1);
  (* No GC: destruction must already have happened even on exceptional exit. *)
  assert_empty ();
  assert (Int.equal (injections ()) 1);
  arm 0 0;
  Cleanup.destroy_slot pointer;
  ignore (Sys.opaque_identity slot : unit Ctypes.ptr Ctypes.CArray.t);
  ignore (Sys.opaque_identity storage : char Ctypes.CArray.t);
  Stdlib.print_endline "generated-cleanup: deterministic destruction=ok"

let generated_leave () =
  expect_signal (fun () -> arm 0 1; Generated_probe.query_int64 "SELECT 42::BIGINT");
  assert (Int.equal (injections ()) 1);
  assert (Int.equal (results_at_signal ()) 1);
  assert_empty ();
  Stdlib.print_endline "generated-leave: deterministic response cleanup=ok"

let generated_enter release_number =
  expect_signal (fun () -> arm release_number 0; Generated_probe.query_int64 "SELECT 42::BIGINT");
  assert (Int.equal (injections ()) 1);
  assert (Int.equal (results_at_signal ()) (if release_number = 1 then 0 else 1));
  assert_empty ();
  Stdlib.print_endline "generated-enter: deterministic cleanup=ok"

let () = with_signal (fun () ->
  match Stdlib.Sys.argv.(1) with
  | "hand-enter" -> hand_enter ()
  | "hand-leave" -> hand_leave ()
  | "generated-cleanup" -> generated_cleanup ()
  | "generated-leave" -> generated_leave ()
  | "generated-enter" -> generated_enter 1
  | "generated-decode" -> generated_enter 2
  | _ -> failwith "unknown signal test")
