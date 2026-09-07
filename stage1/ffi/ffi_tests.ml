open! Base
module Atomic = Stdlib.Atomic

let check_values query sql expected =
  match query sql with
  | Ok actual -> assert (Array.equal Int64.equal actual expected)
  | Error (Probe_error.Query_failed message) -> failwith message
  | Error _ -> failwith ("query failed: " ^ sql)

let check_query name query =
  check_values query "SELECT i::BIGINT FROM range(3) t(i)" [| 0L; 1L; 2L |];
  check_values query "SELECT 1::BIGINT WHERE false" [||];
  check_values query
    "SELECT x FROM (VALUES ('-9223372036854775808'::BIGINT), ('9223372036854775807'::BIGINT)) t(x)"
    [| Int64.min_value; Int64.max_value |];
  check_values query "SELECT i::BIGINT FROM range(5000) t(i)" (Array.init 5000 ~f:Int64.of_int);
  List.iter [ "SELECT 1"; "SELECT NULL::BIGINT"; "SELECT 1::BIGINT, 2::BIGINT" ]
    ~f:(fun sql -> assert (Poly.equal (query sql) (Error Probe_error.Unsupported_schema)));
  assert (Poly.equal (query "SELECT 1::BIGINT\000; ignored") (Error Probe_error.Embedded_nul));
  for _ = 1 to 30 do
    (match query "not valid SQL" with
     | Error (Probe_error.Query_failed message) -> assert (not (String.is_empty message))
     | _ -> failwith "invalid SQL was accepted");
    check_values query "SELECT 42::BIGINT" [| 42L |]
  done;
  assert (Int.equal (Handwritten_probe.live_results ()) 0);
  Stdlib.print_endline (name ^ ": query/errors/chunks/cleanup=ok")

let check_lock name ~unlocked slow =
  let ready = Atomic.make false in
  let finished = Atomic.make false in
  let ticks = Atomic.make 0 in
  let thread = Thread.create (fun () ->
    Atomic.set ready true;
    while not (Atomic.get finished) do
      if Int.equal (Handwritten_probe.active ()) 1 then
        Atomic.set ticks (Atomic.get ticks + 1);
      Stdlib.Gc.full_major ();
      Thread.delay 0.001
    done) () in
  while not (Atomic.get ready) do Thread.delay 0.001 done;
  slow ();
  Atomic.set finished true;
  Thread.join thread;
  assert (Bool.equal (Atomic.get ticks > 0) unlocked);
  Stdlib.print_endline (name ^ ": lock-control=ok")

let check_gc name query =
  let finished = Atomic.make false in
  let thread = Thread.create (fun () ->
    while not (Atomic.get finished) do
      ignore (Sys.opaque_identity (Array.create ~len:4096 "gc stress") : string array);
      Stdlib.Gc.compact ();
      Thread.delay 0.001
    done) () in
  Exn.protect
    ~f:(fun () ->
      for _ = 1 to 3 do
        (* Dynamic SQL is deliberately movable, not an immortal string constant. *)
        let sql = "SELECT sum(i)::BIGINT FROM range(10000000) t(i) --" ^ String.make 4096 'x' in
        check_values query sql [| 49999995000000L |]
      done)
    ~finally:(fun () -> Atomic.set finished true; Thread.join thread);
  assert (Int.equal (Handwritten_probe.live_results ()) 0);
  Stdlib.print_endline (name ^ ": gc-stress=ok")

let () =
  check_lock "held-lock negative control" ~unlocked:false Handwritten_probe.slow_locked;
  check_lock "handwritten" ~unlocked:true Handwritten_probe.slow;
  check_lock "generated" ~unlocked:true Generated_probe.slow;
  check_query "handwritten boxed" Handwritten_probe.query_int64;
  check_query "handwritten native int64#" Handwritten_probe.query_int64_unboxed;
  check_query "generated int64_t" Generated_probe.query_int64;
  check_gc "handwritten" Handwritten_probe.query_int64;
  check_gc "generated" Generated_probe.query_int64
