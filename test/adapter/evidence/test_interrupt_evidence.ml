open! Base
module F = Duckdb_ffi
module S = Evidence_support
(* Test-only primitives; no callback-bearing native state. *)
external arm : int -> unit = "stage4_arm" [@@noalloc]
external entered : unit -> int = "stage4_entered" [@@noalloc]
external release : unit -> unit = "stage4_release" [@@noalloc]
external interrupt_count : unit -> int = "stage4_interrupt_count" [@@noalloc]
external disconnect_count : unit -> int = "stage4_disconnect_count" [@@noalloc]
external execute_count : unit -> int = "stage4_execute_count" [@@noalloc]
external expired : unit -> bool = "stage4_expired" [@@noalloc]
external control_count : int -> int = "stage4_control_count" [@@noalloc]

type phase = Queued | Dispatched | Running | Settling | Finished
(* Fresh heap objects provide identity without wrapping generation counters.
   Only [locked] changes phase/latch/tickets/current/native. The owner alone
   performs SQL and close; the controller can only deliver synchronized interrupt. *)
type request = { identity : unit ref; mutable phase : phase; mutable cancelled : bool;
                 mutable tickets : int }
type slot = { mutex : Stdlib.Mutex.t; mutable current : request option;
              mutable native : F.connection option }
let request phase = { identity = ref (); phase; cancelled = false; tickets = 0 }
let slot () = { mutex = Stdlib.Mutex.create (); current = None; native = None }
let locked slot f =
  Stdlib.Mutex.lock slot.mutex;
  Exn.protect ~f ~finally:(fun () -> Stdlib.Mutex.unlock slot.mutex)
let current slot r = Option.exists slot.current ~f:(fun x -> phys_equal x.identity r.identity)
let cancel slot r = locked slot (fun () ->
  match r.phase with Finished -> () | _ -> r.cancelled <- true)
let is_cancelled slot r = locked slot (fun () -> r.cancelled)
let start slot r = locked slot (fun () ->
  slot.current <- Some r;
  match r.phase with
  | Queued | Dispatched when r.cancelled -> r.phase <- Settling; false
  | Dispatched -> r.phase <- Running; true
  | _ -> failwith "invalid start")
let settling slot r = locked slot (fun () -> r.phase <- Settling)
let eligible slot r = current slot r && r.cancelled && (match r.phase with Running -> true | _ -> false)
let deliver slot r ~pause =
  let reserved = locked slot (fun () ->
    if eligible slot r then (r.tickets <- r.tickets + 1; true) else false) in
  if reserved then
    Exn.protect ~finally:(fun () -> locked slot (fun () -> r.tickets <- r.tickets - 1))
      ~f:(fun () ->
        pause ();
        (* Revalidate AFTER the ML pause; the primitive itself cannot unlock.
           Disarm/identity transition/close use this same short mutex. *)
        locked slot (fun () ->
          if eligible slot r then F.interrupt (Option.value_exn slot.native)))
let retire slot r =
  settling slot r;
  S.await ~label:"interrupt tickets retired" (fun () -> locked slot (fun () -> r.tickets = 0));
  locked slot (fun () ->
    r.phase <- Finished;
    if current slot r then slot.current <- None)
let execute c sql control =
  Exn.protect ~finally:(fun () -> F.clear_work c)
    ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
      F.execute c sql control;
      F.connection_status c, F.connection_message c))
let success = function 0, _ -> () | _, text -> failwith text
let owned slot work =
  let db = F.database_owner () in
  Exn.protect ~finally:(fun () ->
    Exn.protect ~f:(fun () -> F.close_database db) ~finally:(fun () -> F.finish_database_close db))
    ~f:(fun () ->
      F.open_database db "" 1 0 false;
      assert (F.database_status db = 0);
      let c = F.connection_owner db in
      Exn.protect ~finally:(fun () ->
        locked slot (fun () -> slot.current <- None; slot.native <- None);
        Exn.protect ~f:(fun () -> F.close_connection c) ~finally:(fun () -> F.finish_connection_close c))
        ~f:(fun () ->
          F.connect c; assert (F.connection_status c = 0);
          locked slot (fun () -> slot.native <- Some c);
          work c))
let clean baseline fallback =
  assert (F.live_resources () = baseline);
  assert (F.fallback_reclaims () = fallback);
  assert (not (expired ()))
let wait_entry point = S.await ~label:"native gate entry" (fun () -> entered () = point)

(* Each owner stays alive until the controller has joined ALL delivery threads.
   Failure cleanup releases native and ML gates before the mandatory owner join. *)
let session slot work ~control =
  let leave = Stdlib.Atomic.make false in
  let baseline = F.live_resources () and fallback = F.fallback_reclaims () in
  Exn.protect ~finally:(fun () -> release (); Stdlib.Atomic.set leave true)
    ~f:(fun () ->
      S.with_worker
        (fun () -> owned slot (fun c ->
          Exn.protect ~f:(fun () -> work c)
            ~finally:(fun () -> S.await ~label:"controller joined before close" (fun () -> Stdlib.Atomic.get leave))))
        ~f:(fun join ->
          Exn.protect ~finally:(fun () -> release (); Stdlib.Atomic.set leave true)
            ~f:(fun () -> control (); Stdlib.Atomic.set leave true; ignore (join ()))));
  clean baseline fallback

let suppressed phase =
  let slot = slot () and r = request phase in
  let entry = Stdlib.Atomic.make false and proceed = Stdlib.Atomic.make false in
  let count = execute_count () in
  arm 0;
  session slot (fun c ->
    Stdlib.Atomic.set entry true;
    S.await ~label:"dispatched release" (fun () -> Stdlib.Atomic.get proceed);
    assert (not (start slot r));
    if not (is_cancelled slot r) then success (execute c "SELECT 1" false);
    retire slot r)
    ~control:(fun () ->
      Exn.protect ~finally:(fun () -> Stdlib.Atomic.set proceed true) ~f:(fun () ->
        S.await ~label:"worker admitted" (fun () -> Stdlib.Atomic.get entry);
        cancel slot r; cancel slot r;
        assert (execute_count () = count)));
  assert (execute_count () = count);
  let calls = interrupt_count () in
  cancel slot r; deliver slot r ~pause:Fn.id;
  assert (interrupt_count () = calls);
  Stdlib.print_endline "interrupt: queued/dispatched latch suppresses execution count=0 terminal-cancel=no-op"

let reset_and_running ~latched ~transaction =
  let slot = slot () and r = request Dispatched in
  let done_ = Stdlib.Atomic.make false and result = Stdlib.Atomic.make None in
  let settled = Stdlib.Atomic.make false in
  let before = interrupt_count () and executions = execute_count () in
  let commits = control_count 1 and rollbacks = control_count 2 in
  arm 1;
  session slot (fun c ->
    if transaction then success (execute c "BEGIN TRANSACTION" true);
    assert (start slot r);
    let sql = if latched then "SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)" else "SELECT sum(i) FROM range(10000) t(i)" in
    let outcome = execute c sql false in
    settling slot r;
    Stdlib.Atomic.set result (Some outcome);
    Stdlib.Atomic.set done_ true;
    S.await ~label:"driver quiescent before rollback" (fun () -> Stdlib.Atomic.get settled);
    retire slot r;
    if transaction then (
      assert (is_cancelled slot r);
      (* Test-owned call-boundary latch. The safe core has NO such callback. *)
      success (execute c "ROLLBACK" true));
    if not latched then success (execute c "SELECT 42" false))
    ~control:(fun () ->
      Exn.protect ~finally:(fun () -> release (); Stdlib.Atomic.set settled true) ~f:(fun () ->
        wait_entry 1;
        assert (execute_count () = executions + 1);
        cancel slot r;
        deliver slot r ~pause:Fn.id;
        assert (interrupt_count () = before + 1);
        assert (not (Stdlib.Atomic.get done_));
        release ();
        if latched then (
          let start = Mtime_clock.counter () in
          while not (Stdlib.Atomic.get done_) do
            if Float.(Mtime.Span.to_float_ns (Mtime_clock.count start) > 10_000_000_000.) then failwith "engine interrupt deadline";
            deliver slot r ~pause:Fn.id;
            Thread.delay 0.001
          done)
        else S.await ~label:"finite reset control completion" (fun () -> Stdlib.Atomic.get done_);
        assert (is_cancelled slot r);
        let status, message = Option.value_exn (Stdlib.Atomic.get result) in
        if latched then (
          assert (status = 1);
          assert (String.is_substring (String.lowercase message) ~substring:"interrupt"))
        else assert (status = 0);
        Stdlib.Atomic.set settled true));
  if transaction then (
    assert (control_count 1 = commits);
    assert (control_count 2 = rollbacks + 1);
    assert (execute_count () = executions + 1));
  Stdlib.Printf.printf "interrupt: pre-engine=1 latched=%b transaction=%b calls=%d foreign-completion=ok commit-delta=%d\n%!"
    latched transaction (interrupt_count () - before) (control_count 1 - commits)

let between_calls () =
  let slot = slot () and r = request Dispatched in
  let boundary = Stdlib.Atomic.make false and proceed = Stdlib.Atomic.make false in
  let next_user_call = Stdlib.Atomic.make false in
  let commits = control_count 1 and rollbacks = control_count 2 and calls = interrupt_count () in
  arm 0;
  session slot (fun c ->
    success (execute c "CREATE TABLE marker(i INTEGER)" false);
    success (execute c "BEGIN TRANSACTION" true);
    assert (start slot r);
    success (execute c "INSERT INTO marker VALUES (1)" false);
    settling slot r;
    Stdlib.Atomic.set boundary true;
    S.await ~label:"between-call latch" (fun () -> Stdlib.Atomic.get proceed);
    retire slot r;
    (* A successful prior native call cannot clear the request cancellation latch.
       This is test-owned control SQL, NOT a hook available in the safe core. *)
    if is_cancelled slot r then success (execute c "ROLLBACK" true)
    else (
      Stdlib.Atomic.set next_user_call true;
      success (execute c "INSERT INTO marker VALUES (2)" false);
      success (execute c "COMMIT" true));
    success (execute c "SELECT CASE WHEN count(*)=0 THEN 1 ELSE error('committed') END FROM marker" false))
    ~control:(fun () ->
      Exn.protect ~finally:(fun () -> Stdlib.Atomic.set proceed true) ~f:(fun () ->
        S.await ~label:"successful native call boundary" (fun () -> Stdlib.Atomic.get boundary);
        cancel slot r; cancel slot r;
        deliver slot r ~pause:Fn.id;
        assert (interrupt_count () = calls)));
  assert (not (Stdlib.Atomic.get next_user_call));
  assert (control_count 1 = commits && control_count 2 = rollbacks + 1);
  Stdlib.print_endline "interrupt: test-owned between-call latch suppresses next statement+COMMIT; rollback=1 rows=0 (safe bridge hook missing)"

let retirement_race () =
  let slot = slot () and r = request Dispatched in
  let pause_entered = Stdlib.Atomic.make false and pause_release = Stdlib.Atomic.make false in
  let completed = Stdlib.Atomic.make false and retirement = Stdlib.Atomic.make false in
  let calls = interrupt_count () and disconnects = disconnect_count () in
  arm 2;
  session slot (fun c ->
    assert (start slot r);
    success (execute c "SELECT 1" false);
    settling slot r;
    Stdlib.Atomic.set completed true;
    retire slot r;
    Stdlib.Atomic.set retirement true)
    ~control:(fun () ->
      wait_entry 2;
      cancel slot r;
      Exn.protect ~finally:(fun () -> Stdlib.Atomic.set pause_release true; release ()) ~f:(fun () ->
        S.with_worker (fun () -> deliver slot r ~pause:(fun () ->
          Stdlib.Atomic.set pause_entered true;
          S.await ~label:"ML ticket release" (fun () -> Stdlib.Atomic.get pause_release)))
          ~f:(fun join ->
            Exn.protect ~finally:(fun () -> Stdlib.Atomic.set pause_release true; release ()) ~f:(fun () ->
              S.await ~label:"ML ticket reserved" (fun () -> Stdlib.Atomic.get pause_entered);
              assert (locked slot (fun () -> r.tickets = 1));
              release ();
              S.await ~label:"A foreign completion" (fun () -> Stdlib.Atomic.get completed);
              assert (not (Stdlib.Atomic.get retirement));
              assert (disconnect_count () = disconnects);
              Stdlib.Atomic.set pause_release true;
              join ();
              S.await ~label:"A retirement" (fun () -> Stdlib.Atomic.get retirement);
              assert (interrupt_count () = calls)))));
  assert (disconnect_count () = disconnects + 1);
  Stdlib.print_endline "interrupt: reserved-ticket blocks retirement/close; post-pause settling check skips native delivery; joined then disconnect=1"

let stale_and_error () =
  let slot = slot () and a = request Dispatched and b = request Dispatched in
  let acquired_b = Stdlib.Atomic.make false and proceed = Stdlib.Atomic.make false in
  let calls = interrupt_count () in
  arm 0;
  session slot (fun c ->
    assert (start slot a);
    let status, _ = execute c "SELECT error('native error control')" false in
    assert (status = 1);
    retire slot a;
    assert (start slot b);
    Stdlib.Atomic.set acquired_b true;
    S.await ~label:"stale notification delivered" (fun () -> Stdlib.Atomic.get proceed);
    success (execute c "SELECT 42" false);
    retire slot b)
    ~control:(fun () ->
      Exn.protect ~finally:(fun () -> Stdlib.Atomic.set proceed true) ~f:(fun () ->
        S.await ~label:"B acquired same engine connection" (fun () -> Stdlib.Atomic.get acquired_b);
        cancel slot a;
        deliver slot a ~pause:Fn.id;
        assert (interrupt_count () = calls)));
  Stdlib.print_endline "interrupt: delayed A after B acquired=suppressed; native-error then known-clean SELECT=ok"

let close_gate () =
  let slot = slot () in
  let baseline = F.live_resources () and fallback = F.fallback_reclaims () in
  arm 4;
  Exn.protect ~finally:release ~f:(fun () ->
    S.with_worker (fun () -> owned slot (fun c -> success (execute c "SELECT 1" false)))
      ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () -> wait_entry 4; release (); join ())));
  clean baseline fallback;
  Stdlib.print_endline "interrupt: actual disconnect gate permits system-thread heartbeat=ok"

exception Handshake_failure
exception Worker_failure
let failed_handshake_join () =
  let started = Stdlib.Atomic.make false and release_worker = Stdlib.Atomic.make false in
  let exited = Stdlib.Atomic.make false in
  let result = S.capture (fun () ->
    Exn.protect ~finally:(fun () -> Stdlib.Atomic.set release_worker true) ~f:(fun () ->
      S.with_worker (fun () ->
        Stdlib.Atomic.set started true;
        S.await ~label:"failure cleanup releases gate" (fun () -> Stdlib.Atomic.get release_worker);
        Stdlib.Atomic.set exited true)
        ~f:(fun _join ->
          Exn.protect ~finally:(fun () -> Stdlib.Atomic.set release_worker true) ~f:(fun () ->
            S.await ~label:"controlled failing handshake started" (fun () -> Stdlib.Atomic.get started);
            raise Handshake_failure)))) in
  assert (Stdlib.Atomic.get exited);
  (match result with S.Raised { exception_ = Handshake_failure; _ } -> () | _ -> assert false);
  let worker = S.capture (fun () -> S.with_worker (fun () -> raise Worker_failure) ~f:(fun join -> join ())) in
  (match worker with
   | S.Raised { exception_ = Worker_failure; backtrace } -> assert (Stdlib.Printexc.raw_backtrace_length backtrace > 0)
   | _ -> assert false);
  let both = S.capture (fun () ->
    S.with_worker (fun () -> raise Worker_failure) ~f:(fun _ -> raise Handshake_failure)) in
  (match both with
   | S.Raised { exception_ = S.Multiple_failures (primary, cleanup); _ } ->
     assert (match primary.exception_ with Handshake_failure -> true | _ -> false);
     assert (match cleanup.exception_ with Worker_failure -> true | _ -> false);
     assert (Stdlib.Printexc.raw_backtrace_length primary.backtrace > 0);
     assert (Stdlib.Printexc.raw_backtrace_length cleanup.backtrace > 0)
   | _ -> assert false);
  S.with_worker (fun () -> 42) ~f:(fun join -> assert (join () = 42); assert (join () = 42));
  Stdlib.print_endline "support: failing handshake releases gate, mandatory join precedes propagation; original/composite backtraces and idempotent join=ok"

let run () =
  Stdlib.Printexc.record_backtrace true;
  failed_handshake_join ();
  suppressed Queued;
  suppressed Dispatched;
  reset_and_running ~latched:false ~transaction:false;
  reset_and_running ~latched:true ~transaction:false;
  reset_and_running ~latched:true ~transaction:true;
  between_calls ();
  retirement_race ();
  stale_and_error ();
  close_gate ();
  arm 0;
  assert (F.live_resources () = 0);
  assert (F.fallback_reclaims () = 0)
let () = run ()
