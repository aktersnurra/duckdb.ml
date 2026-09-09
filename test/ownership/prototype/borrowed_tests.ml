open! Base
module B = Borrowed
module Atomic = Stdlib.Atomic
let ok = function Ok x -> x | Error _ -> failwith "unexpected error"
let clean () =
  assert (Borrowed_ffi.live_resources () = 0);
  assert (Borrowed_ffi.fallback_reclaims () = 0)
let collect sql = ok (B.fold sql ~init:[] ~f:(fun v xs ->
  B.Continue (List.rev_append (B.copy v) xs))) |> List.rev
let () =
  assert (List.is_empty (collect "select 1::bigint where false")); clean ();
  let chunks, rows = ok (B.fold "select i::bigint from range(5000) t(i)" ~init:(0, 0)
    ~f:(fun v (chunks, rows) ->
      let alias = v in
      assert (B.length alias = B.length v);
      for i = 0 to B.length v - 1 do
        assert (Option.equal Int64.equal (ok (B.get v i)) (Some (Int64.of_int (rows+i))))
      done;
      assert (Result.is_error (B.get v (-1)));
      assert (Result.is_error (B.get v (B.length v)));
      Stdlib.Gc.full_major (); Stdlib.Gc.compact ();
      B.Continue (chunks+1, rows+B.length v))) in
  assert (chunks > 1 && rows = 5000); clean ();
  let extrema = collect "select v from (values ('-9223372036854775808'::bigint), (NULL::bigint), ('9223372036854775807'::bigint)) t(v)" in
  assert (List.equal (Option.equal Int64.equal) extrema
    [Some Int64.min_value; None; Some Int64.max_value]); clean ();
  assert (Stdlib.Domain.join (Stdlib.Domain.Safe.spawn (fun () ->
    List.length extrema)) = 3);
  let sparse = collect "select case when i%65=0 then NULL else i end::bigint from range(5000) t(i)" in
  List.iteri sparse ~f:(fun i x -> assert (Option.equal Int64.equal x
    (if i % 65 = 0 then None else Some (Int64.of_int i)))); clean ();
  List.iter ["select 1"; "select 1::bigint, 2::bigint"] ~f:(fun sql ->
    match B.fold sql ~init:() ~f:(fun _ () -> B.Stop ()) with
    | Error B.Unsupported_schema -> () | _ -> assert false);
  (match B.fold "not sql" ~init:() ~f:(fun _ () -> B.Stop ()) with
   | Error (B.Native_error _) -> () | _ -> assert false); clean ();
  (match B.fold "select 1\000" ~init:() ~f:(fun _ () -> B.Stop ()) with
   | Error B.Embedded_nul -> () | _ -> assert false); clean ();
  let first = ok (B.fold "select i::bigint from range(5000) t(i)" ~init:[]
    ~f:(fun v _ -> B.Stop (B.copy v))) in
  assert (List.length first > 0 && List.length first < 5000); clean ();
  (try ignore (B.fold "select 42::bigint" ~init:() ~f:(fun _ () ->
    failwith "callback exception")); assert false with
   | Failure message -> assert (String.equal message "callback exception")); clean ();
  ignore (ok (B.fold "select 42::bigint" ~init:() ~f:(fun v () ->
    ignore (collect "select 7::bigint");
    assert (Option.equal Int64.equal (ok (B.get v 0)) (Some 42L));
    B.Stop ()))); clean ();
  for _ = 1 to 100 do ignore (collect "select NULL::bigint"); clean () done;
  let done_ = Atomic.make false in
  let ticks = Atomic.make 0 in
  let worker = Thread.create (fun () ->
    while not (Atomic.get done_) do
      ignore (Sys.opaque_identity (Array.create ~len:4096 "pressure") : string array);
      Stdlib.Gc.compact ();
      Atomic.set ticks (Atomic.get ticks + 1);
      Thread.delay 0.001
    done) () in
  Exn.protect ~finally:(fun () -> Atomic.set done_ true; Thread.join worker)
    ~f:(fun () ->
      for _ = 1 to 3 do
        let sql = "select sum(i)::bigint from range(10000000) t(i) --"
          ^ String.make 4096 'x' in
        assert (List.equal (Option.equal Int64.equal) (collect sql) [Some 49999995000000L]);
        clean ()
      done);
  assert (Atomic.get ticks > 0);
  let raw = Borrowed_ffi.create () in
  Borrowed_ffi.close raw; Borrowed_ffi.close raw; clean ();
  Stdlib.Printf.printf "borrowed: chunks=%d rows=%d null/extrema/copy/domain/GC/stop/exn/reentrant/cleanup=ok\n%!" chunks rows
