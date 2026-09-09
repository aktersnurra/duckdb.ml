open! Base
module E = Duckdb_eio
let check n b = if not b then failwith n
let unwrap = function Ok v -> v | Error _ -> failwith "unexpected adapter error"
let config () = unwrap (Duckdb.Config.create Duckdb.Config.Memory)
let pool sw = unwrap (E.create ~sw (unwrap (E.limits ~connections:1 ~queue_capacity:0)) (config ()))
let post_await_check () =
  Test_support.reset ();
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    Eio.Cancel.sub (fun cc ->
      Test_support.await_then_cancel (fun () -> Eio.Cancel.cancel cc Test_support.Requested);
      try
        ignore (E.execute p "SELECT 1");
        failwith "post-await cancellation was not propagated"
      with Eio.Cancel.Cancelled Test_support.Requested -> ());
    check "completion was resolved before caller cancellation" (Test_support.completion_observed () = 1);
    (* Disabled seams are a no-op control over the same generated adapter. *)
    Test_support.reset ();
    unwrap (E.execute p "SELECT 2");
    unwrap (E.shutdown p))
external reset_native : int -> unit = "eio_foundation_reset"
external counter : int -> int = "eio_foundation_counter"
external held_entry : int -> int = "eio_foundation_held_entry"
external hold_native : bool -> unit = "eio_foundation_hold"
let until clock name f =
  let deadline = Eio.Time.now clock +. 5. in
  let rec loop () =
    if f () then ()
    else if Float.(Eio.Time.now clock > deadline) then failwith name
    else (Eio.Time.sleep clock 0.001; loop ()) in
  loop ()

let dispatch_fault () =
  Test_support.reset ();
  reset_native (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    Test_support.reset ();
    Test_support.raise_dispatch_once ();
    let bt =
      try ignore (E.execute p "SELECT 3"); failwith "dispatch fault was not captured"
      with Test_support.Dispatch_fault as ex ->
        let bt = Stdlib.Printexc.get_raw_backtrace () in
        check "dispatch exception identity delivered by adapter" (phys_equal ex Test_support.Dispatch_fault);
        bt in
    let trace = Stdlib.Printexc.raw_backtrace_to_string bt in
    Stdlib.Printf.printf "dispatch caller raw backtrace:\n%s%!" trace;
    check "original dispatch named source frame delivered to caller"
      (String.is_substring trace ~substring:"Test_support.dispatch_fault_source_frame"
       && String.is_substring trace ~substring:"test/eio/instrumented/test_support.ml");
    check "dispatch Operation phase delivered as original exception"
      (Option.equal Int.equal (Test_support.fault_phase ()) (Some 0));
    check "fault was raised at offload boundary once" (Test_support.dispatch_attempts () = 1);
    check "faulted request entered zero operation workers" (Test_support.operation_workers () = 0);
    check "faulted request executed zero native SQL" (counter 3 = 0);
    (* Retirement/replacement is legitimate cleanup, not request execution. *)
    check "faulted request retired and replaced its slot" (counter 0 = 2 && counter 1 = 1);
    unwrap (E.execute p "SELECT 4");
    check "subsequent request dispatched exactly once" (Test_support.dispatch_attempts () = 2);
    check "independent worker and native observers see subsequent work"
      (Test_support.operation_workers () = 1 && counter 3 = 1);
    unwrap (E.shutdown p));
  check "dispatch failure drain inventory" (counter 0 = 2 && counter 1 = 2 && counter 2 = 1)

(* A's producer has released its permit and settled its private completion.
   Only A's caller is held at the generated seam. B then enters the real native
   gate before A receives cancellation and executes the adapter's cancel path. *)
let delayed_a_cancellation_active_b clock replacement =
  Test_support.reset ();
  reset_native (-1);
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    let retired, publish_retired = Eio.Promise.create () in
    let caller_release, release_caller = Eio.Promise.create () in
    let context, publish_context = Eio.Promise.create () in
    let release_a () =
      if not (Eio.Promise.is_resolved caller_release) then Eio.Promise.resolve release_caller () in
    Exn.protect ~finally:(fun () -> hold_native false; release_a ()) ~f:(fun () ->
      Test_support.await_then_hold (fun () ->
        Eio.Promise.resolve publish_retired ();
        Eio.Promise.await caller_release);
      let a = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
        Eio.Promise.resolve publish_context cc;
        try
          let result = if replacement then
            E.transaction p ~f:(fun tx -> Duckdb.execute_transaction tx "SELECT 10")
            else E.execute p "SELECT 10" in
          ignore result; false
        with Eio.Cancel.Cancelled Test_support.Requested -> true)) in
      Eio.Promise.await retired;
      check "A producer retired while caller is unsettled"
        (Test_support.completion_observed () = 1 && not (Eio.Promise.is_resolved a));
      check "A native slot reuse/replacement completed before B"
        (counter 0 = (if replacement then 2 else 1) && counter 1 = (if replacement then 1 else 0));
      let executions_before_b = counter 3 in
      hold_native true;
      let b = Eio.Fiber.fork_promise ~sw (fun () -> E.execute p "SELECT 11") in
      until clock "B native selected entry or completion"
        (fun () -> held_entry 5 > 0 || Eio.Promise.is_resolved b);
      let active_b () =
        check "B selected native held-entry acknowledged during delayed A cancellation"
          (held_entry 5 = 1 && counter 6 = 0);
        check "B still pending during delayed A cancellation" (not (Eio.Promise.is_resolved b)) in
      active_b ();
      check "B really dispatched its own native execution" (counter 3 = executions_before_b + 1);
      check "B owns sole admission while A caller remains unsettled"
        (match E.execute p "SELECT 12" with Error E.Queue_full -> true | _ -> false);
      let interrupts = counter 4 in
      Eio.Cancel.cancel (Eio.Promise.await context) Test_support.Requested;
      active_b ();
      release_a ();
      check "A original cancellation delivered while B held" (Eio.Promise.await_exn a);
      active_b ();
      check "delayed A cancellation adds zero native interrupts to active B"
        (interrupts = 0 && counter 4 = interrupts);
      hold_native false;
      unwrap (Eio.Promise.await_exn b);
      unwrap (E.execute p "SELECT 13");
      check "B completion and later request preserve capacity without retirement"
        (counter 0 = (if replacement then 2 else 1) && counter 4 = 0);
      unwrap (E.shutdown p)));
  check "active-B final drain inventory"
    (counter 0 = (if replacement then 2 else 1) && counter 1 = counter 0 && counter 2 = 1)

let run env =
  Stdlib.Printexc.record_backtrace true;
  let tests = [
    "post_await_check", post_await_check;
    "dispatch_fault", dispatch_fault;
    "active_b_reuse", (fun () -> delayed_a_cancellation_active_b (Eio.Stdenv.clock env) false);
    "active_b_replacement", (fun () -> delayed_a_cancellation_active_b (Eio.Stdenv.clock env) true);
  ] in
  List.iter tests ~f:(fun (name, test) ->
    if Array.length (Sys.get_argv ()) = 1 || String.equal (Sys.get_argv ()).(1) name then (
      reset_native (-1); test (); Stdlib.Printf.printf "eio gates %s: PASS\n%!" name))
let () = Eio_main.run run
