open! Base
module D = Duckdb
module B = D.Bridge
module E = Evidence_support
external reset : unit -> unit = "delivery_reset"
external gate : int -> bool -> unit = "delivery_gate"
external entered : int -> int = "delivery_entered"
external count : int -> int = "delivery_count"
external selected_gate : bool -> unit = "delivery_selected_gate"
external selected_entered : unit -> bool = "delivery_selected_entered"
external fail_start : bool -> unit = "delivery_fail_start"
external arm_drain_wait : bool -> unit = "delivery_arm_drain_wait"
external drain_wait_entered : unit -> bool = "delivery_drain_wait_entered"
let check name condition = if not condition then failwith name
let ok = function Ok x -> x | Error _ -> failwith "expected Ok"
let cancelled = function Error D.Cancelled -> () | _ -> failwith "expected cancellation"
let native_error = function
  | Error (D.Native_error message) -> check "native diagnostic retained" (not (String.is_empty message))
  | _ -> failwith "expected native error"
let release () = for i = 1 to 13 do gate i false done; selected_gate false; fail_start false
let wait id = E.await ~label:("native boundary " ^ Int.to_string id) (fun () -> entered id > 0)
let wait_count id n = E.await ~label:("native count " ^ Int.to_string id) (fun () -> count id >= n)
let pending r = check "request pending" (match B.settlement r with Pending -> true | Settled -> false)
let settled r = check "request settled" (match B.settlement r with Settled -> true | Pending -> false)
let one_controller () = check "one controller started and joined" (count 10 = 1 && count 11 = 1 && count 12 = 1)
let with_owner f = ok (D.with_database (ok (D.Config.create D.Config.Memory)) ~f:(fun db ->
  D.with_connection db ~f:(fun owner -> f owner; Ok ())))
let controller_lifecycle owner =
  reset ();
  let request = B.create () in
  check "Fresh has no controller" (count 10 = 0);
  ok (B.run request owner ~f:(fun facade ->
    check "controller started before callback" (count 10 = 1 && count 12 = 0);
    D.execute facade "SELECT 1"));
  one_controller (); settled request;
  check "no idle delivery" (count 4 = 0);
  ok (D.execute owner "SELECT 1")
exception Start_failure
let start_failure_frame request owner =
  let outcome = B.run request owner ~f:(fun _ -> failwith "start failure callback ran") in
  ignore (Sys.opaque_identity outcome)
let controller_failure owner =
  reset (); Stdlib.Callback.Safe.register_exception "delivery_start_failure" Start_failure;
  let request = B.create () in
  fail_start true;
  Exn.protect ~finally:release ~f:(fun () ->
    (match E.capture (fun () -> start_failure_frame request owner) with
     | E.Raised failure ->
       check "start failure identity" (phys_equal failure.exception_ Start_failure);
       check "start failure backtrace"
         (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string failure.backtrace) ~substring:"start_failure_frame")
     | _ -> failwith "expected controller creation failure");
    settled request;
    check "failed start detached without join or SQL" (count 10 = 1 && count 11 = 0 && count 13 = 1 && count 0 = 0));
  ok (D.execute owner "SELECT 1")
let running ~transaction ~recover owner =
  reset (); gate 5 true; gate 10 true;
  if transaction then gate 11 true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    if recover then (
      (match D.with_transaction facade ~f:(fun _ -> Error D.Embedded_nul) with
       | Error D.Embedded_nul -> () | _ -> failwith "recoverable rollback outcome");
      check "same controller survives ordinary rollback" (count 10 = 1 && count 12 = 0));
    let sql = "SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)" in
    if transaction then D.with_transaction facade ~f:(fun tx -> D.execute_transaction tx sql)
    else D.execute facade sql))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 5;
      let fallback = Duckdb_ffi.fallback_reclaims () in
      Stdlib.Gc.full_major (); Stdlib.Gc.full_major ();
      check "live controller/worker owner graph survives GC" (Duckdb_ffi.fallback_reclaims () = fallback);
      ok (B.cancel request); wait_count 4 1;
      let before = count 4 in
      gate 5 false;
      if transaction then (
        wait 11;
        check "interrupted transaction joins before rollback" (count 12 = 1 && count 14 = count 17);
        gate 11 false);
      wait 10;
      check "disconnect waits for join and all selected retirement" (count 12 = 1 && count 14 = count 17 && count 13 = 1);
      gate 10 false;
      (match join () with
       | Error (D.Native_error message) ->
         check "real native interrupted diagnostic" (String.is_substring (String.lowercase message) ~substring:"interrupt")
       | _ -> failwith "native interrupted return was flattened");
      check "persistent delivery survives real execute reset" (count 4 > before && count 3 = 1);
      one_controller (); settled request;
      check "actual delivered owner discarded" (count 5 = 1);
      check "interrupted owner not reusable" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false)))
let between_subcalls point owner =
  reset (); gate point true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade -> D.execute facade "SELECT 1"))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      E.await ~label:"selected before subcall completion" selected_entered;
      gate point false;
      wait_count 11 1;
      check "next native subcall suppressed" (if point = 2 then count 1 = 0 else count 2 = 0);
      check "no detach before selected retirement" (count 13 = 0 && count 12 = 0 && count 5 = 0);
      selected_gate false; cancelled (join ());
      check "selected delivery rechecked after disarm" (count 4 = 0 && count 16 = 1 && count 17 = 1);
      one_controller (); settled request));
  (* No Delivered: a fresh request can reuse the same owner, never identity A. *)
  ok (B.run (B.create ()) owner ~f:(fun facade -> D.execute facade "SELECT 2"));
  check "stale A never reaches fresh B" (count 4 = 0 && count 10 = 2 && count 12 = 2)
let cleanup_exclusion destructor owner =
  reset (); gate 6 true; gate destructor true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade -> D.execute facade "SELECT 1"))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 6; ok (B.cancel request);
      E.await ~label:"selected after native success" selected_entered;
      gate 6 false; wait destructor;
      pending request;
      check "internal destructor precedes terminal join" (count 11 = 0 && count 13 = 0);
      selected_gate false; wait_count 17 1;
      check "post-pause delivery excluded inside destructor" (count 4 = 0 && count 16 = 1);
      gate destructor false; cancelled (join ());
      one_controller (); settled request));
  ok (D.execute owner "SELECT 2")
let idle_cancel owner =
  reset ();
  let request = B.create () in
  cancelled (B.run request owner ~f:(fun facade ->
    ok (D.execute facade "SELECT 1");
    let before = count 0 in
    ok (B.cancel request); cancelled (D.execute facade "SELECT 2");
    check "idle cancel suppresses next user call" (count 0 = before && count 4 = 0);
    Ok ()));
  one_controller (); ok (D.execute owner "SELECT 3")
let rollback_race ~before owner =
  reset (); gate 11 true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    (match D.with_transaction facade ~f:(fun tx ->
      ok (D.execute_transaction tx "SELECT 1");
      if before then ok (B.cancel request);
      Error D.Embedded_nul) with Error D.Embedded_nul -> () | _ -> failwith "rollback primary preserved");
    cancelled (D.execute facade "SELECT 2"); Ok ()))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 11; pending request;
      if before then check "pre-cancel rollback joins first" (count 12 = 1)
      else (check "ordinary admitted rollback retains controller" (count 12 = 0);
            ok (B.cancel request));
      check "rollback excludes delivery" (count 4 = 0 && count 13 = 0);
      gate 11 false; cancelled (join ());
      one_controller (); settled request;
      check "rollback did not commit" (count 8 = 1 && count 7 = 0)));
  ok (D.execute owner "SELECT 3")
exception Drain_failure
let rollback_drains_foreign owner =
  reset (); gate 5 true; selected_gate true;
  let request = B.create () in
  let child = ref None and outcome = Stdlib.Atomic.make None in
  E.with_worker (fun () ->
    Exn.protect ~finally:(fun () -> arm_drain_wait false; Option.iter !child ~f:Thread.join) ~f:(fun () ->
      B.run request owner ~f:(fun facade ->
        D.with_transaction facade ~f:(fun tx ->
          child := Some (Thread.create (fun () ->
            Stdlib.Atomic.set outcome (Some (E.capture (fun () ->
              D.execute_transaction tx "SELECT sum(i) FROM range(10000) t(i)")))) ());
          wait 5; ok (B.cancel request);
          (* Only this request worker's next Condition.wait can be the drain:
             the foreign child is held at gate 5 and the callback now raises. *)
          arm_drain_wait true; raise Drain_failure))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 5;
      E.await ~label:"request worker drain wait or premature join"
        (fun () -> drain_wait_entered () || count 11 > 0);
      check "rollback drains foreign before stopping controller"
        (drain_wait_entered () && count 11 = 0);
      E.await ~label:"selected while request worker drains foreign" selected_entered;
      gate 5 false; wait_count 11 1;
      selected_gate false;
      (match E.capture join with
       | E.Raised failure when phys_equal failure.exception_ Drain_failure -> ()
       | _ -> failwith "concurrent rollback exception preserved");
      cancelled (E.restore (Option.value_exn (Stdlib.Atomic.get outcome)));
      one_controller (); settled request));
  ok (D.execute owner "SELECT 3")
let snapshot_rollback_race ~before owner =
  ok (D.execute owner "CREATE TABLE snapshot_delivery (i BIGINT NOT NULL)");
  reset (); gate 11 true;
  if before then (gate 6 true; selected_gate true);
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    ok (D.with_prepared facade "INSERT INTO snapshot_delivery VALUES (NULL) RETURNING i" ~f:(fun prepared ->
      native_error (D.execute_prepared prepared); Ok ()));
    cancelled (D.execute facade "SELECT 2"); Ok ()))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      if before then (
        wait 6; ok (B.cancel request);
        E.await ~label:"Query selected before snapshot rollback" selected_entered;
        gate 6 false; wait_count 11 1;
        (* Query execute now admits USER. Retire its deliberately paused attempt
           before rollback, preserving this test's no-delivery recovery case. *)
        selected_gate false);
      wait 11;
      if before then check "snapshot cancellation joins before rollback" (count 12 = 1)
      else (check "ordinary snapshot rollback retains controller" (count 12 = 0); ok (B.cancel request));
      check "snapshot rollback is noninterruptible" (count 4 = 0);
      gate 11 false; cancelled (join ()); one_controller (); settled request;
      check "snapshot rollback no commit" (count 8 = 1 && count 7 = 0)));
  ok (D.execute owner "SELECT 3")
let before_native point owner =
  reset (); gate point true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade -> D.execute facade "SELECT 1"))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; pending request; ok (B.cancel request); gate point false;
      cancelled (join ()); settled request;
      check "cancel before native admission suppresses extraction" (count 0 = 0 && count 4 = 0);
      if point = 12 then check "cancel during binding starts no controller" (count 10 = 0 && count 13 = 1)
      else one_controller ()));
  ok (B.run (B.create ()) owner ~f:(fun facade -> D.execute facade "SELECT 2"))
let cancelled_child_cleanup ~manual owner =
  reset (); gate 6 true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade ->
    let work prepared =
      let result = D.execute facade "SELECT 2" in
      gate 8 true;
      if manual then ok (D.close_prepared prepared);
      result in
    if manual then Result.bind (D.prepare facade "SELECT 1") ~f:work
    else D.with_prepared facade "SELECT 1" ~f:work))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 6; ok (B.cancel request);
      E.await ~label:"child cleanup selected ticket" selected_entered;
      gate 6 false;
      E.await ~label:"child cleanup join or destructor" (fun () -> count 11 > 0 || entered 8 > 0);
      check "cancelled child cleanup joins before destructor" (count 11 = 1 && entered 8 = 0);
      selected_gate false; wait 8;
      check "child destructor follows selected retirement and join" (count 17 = 1 && count 12 = 1);
      gate 8 false; cancelled (join ()); one_controller ()));
  ok (D.execute owner "SELECT 3")
let selected_terminal owner =
  reset (); gate 6 true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun facade -> D.execute facade "SELECT 1"))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 6; ok (B.cancel request);
      E.await ~label:"terminal selected ticket" selected_entered;
      gate 6 false; wait_count 11 1;
      pending request;
      check "no join completion/detach/close while selected" (count 12 = 0 && count 13 = 0 && count 5 = 0);
      check "owner Busy before retirement" (match D.close_connection owner with Error D.Busy -> true | _ -> false);
      check "fresh B cannot reuse before A retirement" (match B.run (B.create ()) owner ~f:(fun _ -> Ok ()) with Error D.Busy -> true | _ -> false);
      selected_gate false; cancelled (join ());
      check "late ticket skipped" (count 4 = 0 && count 16 = 1 && count 17 = 1);
      one_controller (); settled request));
  ok (B.run (B.create ()) owner ~f:(fun facade -> D.execute facade "SELECT 2"));
  check "fresh B receives no stale A delivery" (count 4 = 0)
let tests = ["controller", controller_lifecycle; "start-failure", controller_failure;
  "running-reset", running ~transaction:false ~recover:false;
  "transaction-interrupted", running ~transaction:true ~recover:false;
  "recovered-interruption", running ~transaction:false ~recover:true;
  "cancel-before-binding", before_native 12; "cancel-before-native", before_native 13;
  "after-extract", between_subcalls 2; "after-prepare", between_subcalls 4;
  "result-cleanup", cleanup_exclusion 7; "prepare-cleanup", cleanup_exclusion 8;
  "extracted-cleanup", cleanup_exclusion 9; "idle", idle_cancel;
  "rollback-before", rollback_race ~before:true; "rollback-after", rollback_race ~before:false;
  "rollback-drains-foreign", rollback_drains_foreign;
  "snapshot-rollback-before", snapshot_rollback_race ~before:true;
  "snapshot-rollback-after", snapshot_rollback_race ~before:false;
  "scoped-child-cleanup", cancelled_child_cleanup ~manual:false;
  "manual-child-cleanup", cancelled_child_cleanup ~manual:true;
  "selected-terminal", selected_terminal]
let run () =
  Stdlib.Printexc.record_backtrace true;
  let selected = match Sys.get_argv () with [|_; name|] -> Some name | _ -> None in
  List.iter (tests @ Query_delivery.tests @ Appender_delivery.tests @ Control_publication.tests) ~f:(fun (name, test) ->
    if Option.for_all selected ~f:(fun selected -> String.equal name selected || (String.equal selected "control" && String.is_prefix name ~prefix:"control-") || (String.equal selected "query" && String.is_prefix name ~prefix:"query-") || (String.equal selected "appender" && String.is_prefix name ~prefix:"appender-")) then (
      let live = Duckdb_ffi.live_resources () and fallback = Duckdb_ffi.fallback_reclaims () in
      with_owner test;
      check "ordinary live resources restored" (Duckdb_ffi.live_resources () = live);
      check "ordinary fallback unchanged" (Duckdb_ffi.fallback_reclaims () = fallback);
      Stdlib.print_endline ("native delivery: " ^ name ^ " passed")))
let rec report_exception = function
  | E.Multiple_failures (first, second) ->
    report_exception first.exception_; report_exception second.exception_
  | exn -> Stdlib.prerr_endline (Exn.to_string exn)
let () = try run () with exn -> report_exception exn; raise exn
