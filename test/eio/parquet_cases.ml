open! Base
module E = Duckdb_eio
module H = Parquet_hooks
module P = Typed_probe
exception Requested
exception Callback_failure
let check name condition = if not condition then failwith name
let unwrap = function Ok value -> value | Error _ -> failwith "unexpected Parquet error"
let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))
let equal_rows = List.equal (fun (x, ()) (y, ()) -> Int64.equal x y)
let pool sw = unwrap (E.create ~sw (unwrap (E.limits ~connections:1 ~queue_capacity:1))
  (unwrap (Duckdb.Config.create Duckdb.Config.Memory)))
let pause clock = Eio.Time.sleep clock 0.001
let until clock name condition =
  let deadline = Eio.Time.now clock +. 5. in
  let rec loop () = if condition () then () else if Float.(Eio.Time.now clock > deadline) then failwith name
    else (pause clock; loop ()) in loop ()
let remove path = if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path
let fixtures f =
  let root = Stdlib.Filename.temp_file "duckdb_eio_parquet_" "" in
  remove root; Unix.mkdir root 0o700;
  Exn.protect ~finally:(fun () -> H.release (); H.fail_unlink false;
    Array.iter (Stdlib.Sys.readdir root) ~f:(fun name -> remove (Stdlib.Filename.concat root name)); Unix.rmdir root)
    ~f:(fun () -> Eio.Switch.run (fun sw -> let p = pool sw in
      f sw p root; unwrap (E.shutdown p)))
let file root name = Stdlib.Filename.concat root (name ^ ".parquet")
let temporaries root = Stdlib.Sys.readdir root |> Array.to_list |> List.filter ~f:(String.is_prefix ~prefix:".duckdb-parquet-")
let read p paths = E.parquet_fold_rows p paths rows ~init:[] ~f:(fun row acc -> Ok (Duckdb.Continue (row :: acc))) |> Result.map ~f:List.rev
let export p destination query = unwrap (E.parquet_export p ~query ~destination)
let whole name f =
  let operations = P.operations () and retired = H.counter 10 in
  let result = f () in
  if P.enabled then check (name ^ " one Operation worker") (P.operations () = operations + 1);
  check (name ^ " retired owner") (H.counter 10 = retired + 1);
  Stdlib.Printf.printf "WHOLE %s operations=%d retirement=%d\n%!" name (P.operations () - operations) (H.counter 10 - retired);
  result
let tls name before count = if P.enabled then check (name ^ " actual worker TLS restored") (P.callbacks () = before + count && P.tls_clear ())
let[@inline never] parquet_callback_failure_frame _ () = raise Callback_failure
let read_semantics () = fixtures (fun _ p root ->
  let first = file root "first" and second = file root "second" and wrong = file root "wrong" and empty = file root "empty" and corrupt = file root "corrupt" in
  export p first "SELECT i::BIGINT AS i FROM range(3000) t(i)";
  export p second "SELECT i::BIGINT AS i FROM range(3000,6000) t(i)";
  export p empty "SELECT i::BIGINT AS i FROM range(0) t(i)";
  export p wrong "SELECT 'wrong'::VARCHAR AS i";
  let out = Stdlib.open_out_bin corrupt in Stdlib.output_string out "not parquet"; Stdlib.close_out out;
  check "ordered multi-file multi-chunk owned rows" (match whole "parquet_read" (fun () -> read p [first; second]) with
    | Ok values -> equal_rows values (List.init 6000 ~f:(fun i -> Int64.of_int i, ())) | _ -> false);
  check "empty file owned result" (match read p [empty] with Ok [] -> true | _ -> false);
  check "empty path list rejected" (match read p [] with Error (E.Core (Duckdb.Invalid_configuration _)) -> true | _ -> false);
  check "corrupt file native error" (match read p [corrupt] with Error (E.Core (Duckdb.Native_error _)) -> true | _ -> false);
  let calls = ref 0 in
  check "later schema mismatch retains error after first callbacks" (match E.parquet_fold_rows p [first; wrong] rows ~init:()
    ~f:(fun _ () -> Int.incr calls; Ok (Duckdb.Continue ())) with Error (E.Core (Duckdb.Data_error _)) -> !calls = 3000 | _ -> false);
  let before = P.callbacks () in
  check "Parquet Stop suppresses later invalid file" (match E.parquet_fold_rows p [first; corrupt] rows ~init:0L
    ~f:(fun (value, ()) _ -> check "Parquet callback TLS rejects reentry" (match E.execute p "SELECT 1" with Error E.Reentrant_call -> true | _ -> false); Ok (Duckdb.Stop value)) with Ok 0L -> true | _ -> false);
  tls "Stop" before 1;
  let before = P.callbacks () in
  check "Parquet callback error constituent" (match E.parquet_fold_rows p [first] rows ~init:()
    ~f:(fun _ () -> Error (Duckdb.Native_error "parquet callback")) with Error (E.Core (Duckdb.Native_error s)) -> String.equal s "parquet callback" | _ -> false);
  tls "error" before 1;
  let before = P.callbacks () and retired = H.counter 10 in
  let raised = try ignore (E.parquet_fold_rows p [first] rows ~init:() ~f:parquet_callback_failure_frame); false with
    | Callback_failure ->
      let trace = Stdlib.Printexc.get_raw_backtrace () |> Stdlib.Printexc.raw_backtrace_to_string in
      check "named Parquet callback frame delivered" (String.is_substring trace ~substring:"parquet_callback_failure_frame");
      check "callback exception delivered after retirement" (H.counter 10 = retired + 1); true in
  check "original Parquet callback exception" raised; tls "exception" before 1;
  check "subsequent operation after callback cleanup" (Result.is_ok (E.execute p "SELECT 1"));
  (* Absolute fixture is beneath /tmp, so a relative path can be expressed
     without mutating process cwd. Actual getcwd is observed on the worker. *)
  let relative = String.concat ~sep:"/" (List.init 20 ~f:(fun _ -> "..")) ^ first in
  H.select 0 first second "";
  check "relative path resolves on worker" (Result.is_ok (read p [relative]));
  if P.enabled then check "actual getcwd on operation worker" (H.counter 11 > 0 && H.counter 12 = 0))
let held clock sw name operation during =
  Exn.protect ~finally:H.release ~f:(fun () ->
    let context, publish = Eio.Promise.create () in
    let request = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc;
      try `Returned (operation ()) with Eio.Cancel.Cancelled Requested -> `Cancelled)) in
    until clock (name ^ " selected released native entry") (fun () -> H.counter 0 = 1);
    check (name ^ " pending completion") (not (Eio.Promise.is_resolved request));
    for _ = 1 to 3 do pause clock done;
    check (name ^ " heartbeat with pending completion") (not (Eio.Promise.is_resolved request));
    during (Eio.Promise.await context) request;
    H.release (); Eio.Promise.await_exn request)
let cancel clock name cc request =
  let before = P.cancellations () in
  Eio.Cancel.cancel cc Requested;
  if P.enabled then until clock (name ^ " actual caller cancellation latched") (fun () -> P.cancellations () = before + 1)
  else pause clock;
  check (name ^ " cancellation waits for native settlement") (not (Eio.Promise.is_resolved request))
let cancelled name = function `Cancelled -> () | _ -> failwith (name ^ " original cancellation")
let between_files clock = fixtures (fun sw p root ->
  let first = file root "first" and second = file root "second" in
  export p first "SELECT 1::BIGINT"; export p second "SELECT 2::BIGINT";
  H.select 1 first second "";
  let callbacks = Stdlib.Atomic.make 0 in
  let result = whole "between_files" (fun () -> held clock sw "between_files"
    (fun () -> E.parquet_fold_rows p [first; second] rows ~init:() ~f:(fun _ () -> ignore (Stdlib.Atomic.fetch_and_add callbacks 1); Ok (Duckdb.Continue ())))
    (fun cc request ->
      Stdlib.Printf.printf "HELD_BETWEEN ack=%d callbacks=%d result=%d prepared=%d chunks=%d second_prepare=%d second_execute=%d\n%!" (H.counter 0) (Stdlib.Atomic.get callbacks) (H.counter 3) (H.counter 4) (H.counter 5) (H.counter 1) (H.counter 2);
      check "first file callbacks and actual children retired before cancellation"
        (Stdlib.Atomic.get callbacks = 1 && H.counter 3 = 1 && H.counter 4 = 1 && H.counter 5 > 0);
      check "second file no prepare before cancellation" (H.counter 1 = 0 && H.counter 2 = 0);
      cancel clock "between_files" cc request)) in
  cancelled "between_files" result;
  check "second file native work and callbacks suppressed" (H.counter 1 = 0 && H.counter 2 = 0 && Stdlib.Atomic.get callbacks = 1);
  Stdlib.Printf.printf "BETWEEN ack=%d first_result=%d first_prepare=%d chunks=%d second_prepare=%d second_execute=%d callbacks=%d\n%!"
    (H.counter 0) (H.counter 3) (H.counter 4) (H.counter 5) (H.counter 1) (H.counter 2) (Stdlib.Atomic.get callbacks);
  check "multi-file success control" (equal_rows (unwrap (read p [first; second])) [1L, (); 2L, ()]))
let published_final_side_effect_mutation _destination = ()
let export_boundaries clock = fixtures (fun sw p root ->
  let first = file root "first" and second = file root "second" in
  List.iter [2, "before_reservation"; 3, "copy_entry"; 4, "copy_return"; 5, "publication_entry"; 6, "publication_return"; 7, "unlink_entry"; 8, "copy_result_destroy"] ~f:(fun (kind, name) ->
    List.iter [false; true] ~f:(fun cancellation ->
      let destination = file root (name ^ Bool.to_string cancellation) in
      H.select kind first second destination;
      let result = whole name (fun () -> held clock sw name
        (fun () -> E.parquet_export p ~query:"SELECT 7::BIGINT AS i" ~destination)
        (fun cc request ->
          if kind = 6 || kind = 7 then (
            check "same request actual publication before cancellation" (H.counter 7 = 1 && Stdlib.Sys.file_exists destination));
          if kind = 2 then check "before reservation no owned temporary or COPY" (List.is_empty (temporaries root) && H.counter 6 = 0);
          if kind = 3 then check "COPY held before real execution" (H.counter 6 = 0);
          if kind = 4 || kind = 8 then check "COPY completed before publication" (H.counter 6 = 1 && H.counter 7 = 0);
          if cancellation then (
            cancel clock name cc request;
            if kind = 6 then published_final_side_effect_mutation destination))) in
      if cancellation then cancelled name result else check (name ^ " successful held control") (match result with `Returned (Ok ()) -> true | _ -> false);
      check "owned temporary removed after settlement" (List.is_empty (temporaries root));
      if cancellation && (kind = 2 || kind = 3 || kind = 4 || kind = 8) then check "cancel before publication no final" (not (Stdlib.Sys.file_exists destination));
      (* At link ENTRY admission has already happened: durable publication is
         permitted despite cancellation, and is verified rather than denied. *)
      if not cancellation || kind = 5 || kind = 6 || kind = 7 then (
        check "published final from cancelled request survives" (Stdlib.Sys.file_exists destination);
        check "published final correct content" (equal_rows (unwrap (read p [destination])) [7L, ()]));
      Stdlib.Printf.printf "EXPORT %s cancel=%b ack=%d copy=%d published=%d unlinks=%d final=%b\n%!" name cancellation
        (H.counter 0) (H.counter 6) (H.counter 7) (H.counter 8) (Stdlib.Sys.file_exists destination))))
let export_errors () = fixtures (fun _ p root ->
  let destination = file root "existing" in
  export p destination "SELECT 8::BIGINT AS i";
  H.select 0 "" "" destination;
  check "existing destination rejected" (match E.parquet_export p ~query:"SELECT 9::BIGINT AS i" ~destination with Error (E.Core Duckdb.Destination_exists) -> true | _ -> false);
  check "failed publication cleaned owned temp" (H.counter 8 = 1 && List.is_empty (temporaries root));
  check "unrelated existing final not deleted" (equal_rows (unwrap (read p [destination])) [8L, ()]);
  let bad = file root "bad_copy" in
  check "COPY native failure retained" (match E.parquet_export p ~query:"SELECT error('parquet native failure')::BIGINT AS i" ~destination:bad with
    | Error (E.Core (Duckdb.Native_error message)) -> String.is_substring message ~substring:"parquet native failure" | _ -> false);
  check "COPY failure cleans temp" (List.is_empty (temporaries root) && not (Stdlib.Sys.file_exists bad));
  H.fail_unlink true;
  let raised = Exn.protect ~finally:(fun () -> H.fail_unlink false) ~f:(fun () ->
    try ignore (E.parquet_export p ~query:"SELECT error('parquet native failure')::BIGINT AS i" ~destination:bad); false with
    | Duckdb.Cleanup_exception (Duckdb.Native_error message, Stdlib.Sys_error cleanup) ->
      String.is_substring message ~substring:"parquet native failure" && String.is_substring cleanup ~substring:"Permission denied") in
  check "native and file cleanup error constituents retained" raised;
  check "failed unlink owned temporary observable" (List.length (temporaries root) = 1);
  check "file error never deletes unrelated final" (equal_rows (unwrap (read p [destination])) [8L, ()]))
let read_boundaries clock = fixtures (fun sw p root ->
  let first = file root "first" and second = file root "second" in
  export p first "SELECT i::BIGINT FROM range(3000) t(i)";
  List.iter [9, "read_execute"; 10, "read_fetch"; 11, "read_result_destroy"] ~f:(fun (kind, name) ->
    List.iter [false; true] ~f:(fun cancellation ->
      H.select kind first second "";
      let callbacks = Stdlib.Atomic.make 0 in
      let result = whole name (fun () -> held clock sw name (fun () -> E.parquet_fold_rows p [first] rows ~init:0
        ~f:(fun _ count -> ignore (Stdlib.Atomic.fetch_and_add callbacks 1); Ok (Duckdb.Continue (count + 1))))
        (fun cc request -> if cancellation then cancel clock name cc request)) in
      if cancellation then cancelled name result else check "read held success all rows" (match result with `Returned (Ok 3000) -> true | _ -> false);
      if cancellation && kind <> 11 then check "read cancellation suppresses callbacks" (Stdlib.Atomic.get callbacks = 0);
      Stdlib.Printf.printf "READ %s cancel=%b ack=%d callbacks=%d first_result=%d first_prepare=%d chunks=%d\n%!" name cancellation
        (H.counter 0) (Stdlib.Atomic.get callbacks) (H.counter 3) (H.counter 4) (H.counter 5))))
let run env =
  let clock = Eio.Stdenv.clock env in
  let selectors = ["read_semantics", read_semantics; "between_files", (fun () -> between_files clock);
    "export_boundaries", (fun () -> export_boundaries clock); "export_errors", export_errors;
    "read_boundaries", (fun () -> read_boundaries clock)] in
  let run_selector (name, test) =
    test (); Stdlib.Printf.printf "parquet_cases %s: PASS generated=%b\n%!" name P.enabled in
  match Array.to_list (Sys.get_argv ()) with
  | [_] -> List.iter selectors ~f:run_selector
  | [_; selector] ->
    (match List.find selectors ~f:(fun (name, _) -> String.equal selector name) with
     | Some selected -> run_selector selected
     | None -> invalid_arg ("unknown parquet_cases selector: " ^ selector))
  | _ -> invalid_arg "parquet_cases accepts at most one selector"
