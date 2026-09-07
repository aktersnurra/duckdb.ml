open! Base
external arm : int -> int -> bool -> unit = "stage2_test_arm" [@@noalloc]
external trigger : unit -> unit = "stage2_test_trigger" [@@noalloc]
external injections : unit -> int = "stage2_test_injections" [@@noalloc]
external live_at_signal : unit -> int = "stage2_test_live_at_signal" [@@noalloc]
exception Body
let handled = Stdlib.Atomic.make 0
let () =
  let mode = Stdlib.Sys.argv.(1) in
  let enter, leave, cleanup, expected = match mode with
    | "query-enter" -> 1, 0, false, 2
    | "query-leave" -> 0, 1, false, 4
    | "fetch-enter" -> 2, 0, false, 4
    | "fetch-leave" -> 0, 2, false, 5
    | "advance-enter" -> 3, 0, false, 5
    | "advance-leave" -> 0, 3, false, 5
    | "cleanup" | "cleanup-exn" -> 0, 0, true, 5
    | "callback" -> 0, 0, false, 5
    | _ -> failwith "unknown mode"
  in
  let previous = Stdlib.Sys.Safe.signal Stdlib.Sys.sigusr1
    (Stdlib.Sys.Signal_handle (fun _ -> Stdlib.Atomic.incr handled; raise Stdlib.Sys.Break)) in
  Exn.protect ~finally:(fun () -> arm 0 0 false;
    Stdlib.Sys.Safe.set_signal Stdlib.Sys.sigusr1 previous) ~f:(fun () ->
    arm enter leave cleanup;
    (match Stdlib.Sys.with_async_exns (fun () ->
      let result = Borrowed.fold "select i::bigint from range(5000) t(i)" ~init:0
        ~f:(fun view n ->
          if String.equal mode "callback" then (trigger (); Stdlib.Gc.minor ());
          if String.equal mode "cleanup-exn" then raise Body;
          if cleanup then Borrowed.Stop (Borrowed.length view)
          else Borrowed.Continue (n + Borrowed.length view)) in
      assert (Borrowed_ffi.live_resources () = 0);
      (* Force pending post-cleanup signal delivery before restoring handler. *)
      Stdlib.Gc.minor (); result) with
     | exception Stdlib.Sys.Break -> ()
     | exception Body when String.equal mode "cleanup-exn" ->
       assert (Borrowed_ffi.live_resources () = 0); Stdlib.Gc.minor ()
     | _ -> failwith "signal was not delivered");
    assert (injections () = 1);
    assert (Stdlib.Atomic.get handled = 1);
    assert (live_at_signal () = expected);
    (* No GC/finalizer recovery is used after exception delivery. *)
    assert (Borrowed_ffi.live_resources () = 0);
    assert (Borrowed_ffi.fallback_reclaims () = 0);
    Stdlib.Printf.printf "%s: live-at-signal=%d deterministic-cleanup=ok\n%!" mode expected)
