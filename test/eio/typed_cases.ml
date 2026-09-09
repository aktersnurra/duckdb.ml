open! Base
module E = Duckdb_eio
module H = Typed_hooks
module P = Typed_probe
exception Requested
exception Callback_failure
let check name condition = if not condition then failwith name
let unwrap = function Ok value -> value | Error _ -> failwith "unexpected typed adapter error"
let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))
let wide_rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int8,
  Column (Duckdb.Scalar.Nullable Duckdb.Scalar.String,
    Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty))))
let equal_rows = List.equal (fun (x, ()) (y, ()) -> Int64.equal x y)
let pause clock = Eio.Time.sleep clock 0.001
let until clock name condition =
  let deadline = Eio.Time.now clock +. 5. in
  let rec loop () =
    if condition () then ()
    else if Float.(Eio.Time.now clock > deadline) then failwith name
    else (pause clock; loop ()) in
  loop ()
let pool ?(connections = 1) sw =
  unwrap (E.create ~sw (unwrap (E.limits ~connections ~queue_capacity:1))
    (unwrap (Duckdb.Config.create Duckdb.Config.Memory)))
let cell value = Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, value)
let whole name f =
  let before = P.operations () and native = H.execute_entries 3 in
  let disconnects = H.execute_entries 1 in
  let result = f () in
  if P.enabled then check (name ^ " one Operation worker") (P.operations () = before + 1);
  check (name ^ " retired owner") (H.execute_entries 1 = disconnects + 1);
  Stdlib.Printf.printf "WHOLE %s operations=%d native_execute=%d disconnects=%d\n%!"
    name (P.operations () - before) (H.execute_entries 3 - native) (H.execute_entries 1 - disconnects);
  result
let callback_tls name before count =
  if P.enabled then check (name ^ " actual worker TLS restored")
    (P.callbacks () = before + count && P.tls_clear ())
let[@inline never] fold_callback_failure_frame _ () = raise Callback_failure
let typed_values_and_failures () =
  H.reset ();
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    check "typed widths and NULL are owned" (match E.query p
      "SELECT 127::TINYINT, NULL::VARCHAR, 9223372036854775807::BIGINT" wide_rows with
      | Ok [127, (None, (value, ()))] -> Int64.equal value Int64.max_value | _ -> false);
    check "ordered multi-chunk query" (match whole "query" (fun () -> E.query p "SELECT i::BIGINT FROM range(3000) t(i)" rows) with
      | Ok values -> equal_rows values (List.init 3000 ~f:(fun i -> Int64.of_int i, ())) | Error _ -> false);
    check "empty typed result" (match E.query p "SELECT i::BIGINT FROM range(0) t(i)" rows with Ok [] -> true | _ -> false);
    check "mismatched decoder returns an error" (match E.query p "SELECT 'wrong'::VARCHAR" rows with Error (E.Core (Duckdb.Data_error _)) -> true | _ -> false);
    let before = P.callbacks () in
    check "fold Stop retains owned accumulator" (match whole "fold" (fun () -> E.fold_rows p "SELECT i::BIGINT FROM range(4) t(i)" rows ~init:0L
      ~f:(fun (value, ()) total ->
        check "fold callback reentry rejected before effects" (match E.execute p "SELECT 1" with Error E.Reentrant_call -> true | _ -> false);
        Ok (if Int64.equal value 2L then Duckdb.Stop Int64.(total + value) else Duckdb.Continue Int64.(total + value)))) with Ok 3L -> true | _ -> false);
    callback_tls "Stop" before 3;
    let before = P.callbacks () in
    check "fold callback error retained" (match E.fold_rows p "SELECT 1::BIGINT" rows ~init:()
      ~f:(fun _ () -> Error (Duckdb.Native_error "typed callback error")) with
      | Error (E.Core (Duckdb.Native_error message)) -> String.equal message "typed callback error" | _ -> false);
    callback_tls "error" before 1;
    let before = P.callbacks () and disconnects = H.execute_entries 1 in
    let raised = try ignore (E.fold_rows p "SELECT 1::BIGINT" rows ~init:() ~f:fold_callback_failure_frame); false with
      | Callback_failure ->
        let trace = Stdlib.Printexc.get_raw_backtrace () |> Stdlib.Printexc.raw_backtrace_to_string in
        check "named fold callback frame delivered at caller" (String.is_substring trace ~substring:"fold_callback_failure_frame");
        check "exception delivered after owner retirement" (H.execute_entries 1 = disconnects + 1); true in
    check "fold callback exception reraised" raised;
    callback_tls "exception" before 1;
    check "subsequent request after callback cleanup" (Result.is_ok (E.execute p "SELECT 1"));
    unwrap (E.shutdown p))
let ingest_semantics () =
  H.reset ();
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    unwrap (E.execute p "CREATE TABLE typed_ingest(i BIGINT NOT NULL)");
    let good = [[[cell 1L]]] in
    let destroys = H.execute_entries 11 in
    check "later batch failure rolls back earlier batches"
      (Result.is_error (E.ingest p ~schema:None ~table:"typed_ingest" ~batches:(good @ [[[]]]) ~flush:false));
    check "failed implicit appender cleanup destroys child" (H.execute_entries 11 = destroys + 1);
    check "rollback leaves no rows" (match E.query p "SELECT i FROM typed_ingest" rows with Ok [] -> true | _ -> false);
    let flushes = H.appender_flushes () and explicit = P.flushes () in
    unwrap (whole "ingest" (fun () -> E.ingest p ~schema:None ~table:"typed_ingest" ~batches:good ~flush:true));
    check "explicit flush reaches native appender flush" (H.appender_flushes () > 0);
    check "explicit flush plus close flush" (H.appender_flushes () = flushes + 2);
    if P.enabled then check "explicit adapter flush before close" (P.flushes () = explicit + 1);
    check "explicit flush commits row" (match E.query p "SELECT i FROM typed_ingest" rows with Ok [1L, ()] -> true | _ -> false);
    let flushes = H.appender_flushes () and destroys = H.execute_entries 11 in
    unwrap (E.ingest p ~schema:None ~table:"typed_ingest" ~batches:[List.init 3000 ~f:(fun i -> [cell (Int64.of_int i)])] ~flush:false);
    check "implicit close flush and destruction" (H.appender_flushes () = flushes + 1 && H.execute_entries 11 = destroys + 1);
    check "implicit flush committed all rows" (match E.query p "SELECT count(*)::BIGINT FROM typed_ingest" rows with Ok [3001L, ()] -> true | _ -> false);
    let duplicates = List.init 220000 ~f:(fun _ -> [cell 0L]) in
    unwrap (E.execute p "CREATE TABLE typed_auto(i BIGINT PRIMARY KEY)");
    H.reset ();
    check "automatic flush reports duplicate before close" (Result.is_error (E.ingest p ~schema:None ~table:"typed_auto" ~batches:[duplicates] ~flush:false));
    Stdlib.Printf.printf "AUTO_CONTROL end_rows=%d errors=%d commits=%d\n%!" (H.appender_end_rows ()) (H.counter 1) (H.counter 2);
    check "automatic flush actual first end-row error at 204800" (H.appender_end_rows () = 204800 && H.counter 1 = 1);
    check "automatic flush no COMMIT" (H.counter 2 = 0);
    check "automatic flush control did not commit duplicates" (match E.query p "SELECT i FROM typed_auto" rows with Ok [] -> true | _ -> false);
    unwrap (E.shutdown p))
(* Gates are always released inside the switch body, before exception unwinding
   can join its producer. Selection follows appender/result identity and runtime
   release; heartbeat alone is not an admission or native-entry observation. *)
let held_request clock sw name kind row operation during =
  H.select kind row;
  Exn.protect ~finally:H.release ~f:(fun () ->
    let context, publish = Eio.Promise.create () in
    let request = Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve publish cc;
      try `Returned (operation ()) with
      | Eio.Cancel.Cancelled Requested -> `Cancelled)) in
    until clock (name ^ " selected released native entry") (fun () -> H.counter 0 = 1);
    check (name ^ " completion pending") (not (Eio.Promise.is_resolved request));
    let beats = ref 0 in
    for _ = 1 to 3 do pause clock; Int.incr beats done;
    check (name ^ " heartbeat while native held") (!beats = 3 && not (Eio.Promise.is_resolved request));
    during (Eio.Promise.await context) request;
    H.release ();
    Eio.Promise.await_exn request)
let native_cancellation clock =
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    unwrap (E.execute p "CREATE TABLE typed_cancel(i BIGINT)");
    let run name kind selected operation expect_rows =
      H.reset ();
      let ops = P.operations () and interrupts = H.execute_entries 4 and disconnects = H.execute_entries 1 in
      let cancellations = P.cancellations () in
      let callbacks = Stdlib.Atomic.make 0 in
      let result = held_request clock sw name kind selected (fun () -> operation callbacks)
        (fun cc request ->
          Eio.Cancel.cancel cc Requested;
          if P.enabled then until clock (name ^ " caller latched Bridge cancellation") (fun () -> P.cancellations () = cancellations + 1);
          if kind <> 5 && kind <> 6 then until clock (name ^ " actual interrupt") (fun () -> H.execute_entries 4 > interrupts)
          else pause clock;
          check (name ^ " cancelled caller awaits cleanup") (not (Eio.Promise.is_resolved request))) in
      check (name ^ " original caller cancellation settled") (match result with `Cancelled -> true | _ -> false);
      if P.enabled then check (name ^ " one Operation offload") (P.operations () = ops + 1);
      check (name ^ " selected owner retired") (H.execute_entries 1 = disconnects + 1);
      if kind = 1 || kind = 2 then check (name ^ " cancelled before callbacks") (Stdlib.Atomic.get callbacks = 0);
      (match expect_rows with None -> () | Some count ->
        check (name ^ " no subsequent end-row work") (H.appender_end_rows () = count);
        check (name ^ " COMMIT suppressed") (H.counter 2 = 0));
      Stdlib.Printf.printf "CANCEL %s kind=%d ack=%d end_rows=%d flushes=%d commits=%d fetches=%d operations=%d retirement=%d callbacks=%d\n%!"
        name kind (H.counter 0) (H.appender_end_rows ()) (H.appender_flushes ()) (H.counter 2) (H.counter 3)
        (P.operations () - ops) (H.execute_entries 1 - disconnects) (Stdlib.Atomic.get callbacks);
      check (name ^ " reusable capacity after retirement") (Result.is_ok (E.execute p "SELECT 1"));
      if Option.is_some expect_rows then check (name ^ " no committed rows") (match E.query p "SELECT i FROM typed_cancel" rows with Ok [] -> true | _ -> false) in
    List.iter [1, "execute"; 2, "fetch"; 6, "result_destroy"] ~f:(fun (kind, boundary) ->
      run ("query_" ^ boundary) kind 0
        (fun _ -> E.query p "SELECT i::BIGINT FROM range(3000) t(i)" rows) None;
      run ("fold_" ^ boundary) kind 0
        (fun calls -> E.fold_rows p "SELECT i::BIGINT FROM range(3000) t(i)" rows ~init:()
          ~f:(fun _ () -> ignore (Stdlib.Atomic.fetch_and_add calls 1); Ok (Duckdb.Continue ()))) None);
    List.iter [3, "end_row"; 4, "flush"; 5, "appender_destroy"] ~f:(fun (kind, boundary) ->
      run ("ingest_" ^ boundary) kind 1
        (fun _ -> E.ingest p ~schema:None ~table:"typed_cancel" ~batches:[[[cell 1L]]; [[cell 2L]]] ~flush:true)
        (Some (if kind = 3 then 1 else 2)));
    run "ingest_auto_204800" 3 204800
      (fun _ -> E.ingest p ~schema:None ~table:"typed_cancel"
        ~batches:[List.init 204801 ~f:(fun i -> [cell (Int64.of_int i)])] ~flush:false) (Some 204800);
    unwrap (E.shutdown p))
let native_success clock =
  Eio.Switch.run (fun sw ->
    let p = pool sw in
    unwrap (E.execute p "CREATE TABLE typed_success(i BIGINT)");
    let run name kind operation =
      H.reset ();
      let result = whole name (fun () -> held_request clock sw name kind 1 operation (fun _ _ -> ())) in
      check (name ^ " held successful result") (match result with `Returned (Ok ()) -> true | _ -> false);
      Stdlib.Printf.printf "SUCCESS %s kind=%d ack=%d end_rows=%d flushes=%d commits=%d\n%!"
        name kind (H.counter 0) (H.appender_end_rows ()) (H.appender_flushes ()) (H.counter 2) in
    List.iter [1; 2; 6] ~f:(fun kind ->
      run ("query_success_" ^ Int.to_string kind) kind (fun () ->
        Result.map (E.query p "SELECT i::BIGINT FROM range(3000) t(i)" rows) ~f:(fun result ->
          check "held query successful ordered control" (equal_rows result (List.init 3000 ~f:(fun i -> Int64.of_int i, ())))));
      run ("fold_success_" ^ Int.to_string kind) kind (fun () ->
        Result.map (E.fold_rows p "SELECT i::BIGINT FROM range(3000) t(i)" rows ~init:0
          ~f:(fun _ count -> Ok (Duckdb.Continue (count + 1)))) ~f:(fun count -> check "held fold successful control" (count = 3000))));
    List.iter [3; 4; 5] ~f:(fun kind ->
      run ("ingest_success_" ^ Int.to_string kind) kind (fun () -> E.ingest p ~schema:None ~table:"typed_success" ~batches:[[[cell 1L]]] ~flush:true));
    check "held ingestion controls committed exact rows" (match E.query p "SELECT count(*)::BIGINT FROM typed_success" rows with Ok [3L, ()] -> true | _ -> false);
    unwrap (E.shutdown p))
let metadata_race clock =
  Eio.Switch.run (fun sw ->
    let p = pool ~connections:2 sw in
    unwrap (E.execute p "CREATE TABLE typed_metadata(i BIGINT)");
    H.reset ();
    let result = held_request clock sw "metadata" 3 1
      (fun () -> E.ingest p ~schema:None ~table:"typed_metadata" ~batches:[[[cell 1L]]] ~flush:false)
      (fun _ request ->
        unwrap (E.execute p "ALTER TABLE typed_metadata ADD COLUMN changed BIGINT");
        check "metadata committed while original ingestion held" (not (Eio.Promise.is_resolved request))) in
    check "metadata invalidates ingestion" (match result with `Returned (Error _) -> true | _ -> false);
    check "metadata race suppresses ingestion COMMIT" (H.counter 2 = 0);
    Stdlib.Printf.printf "METADATA ack=%d end_rows=%d ingestion_commits=%d\n%!" (H.counter 0) (H.appender_end_rows ()) (H.counter 2);
    check "metadata race rolled back" (match E.query p "SELECT i FROM typed_metadata" rows with Ok [] -> true | _ -> false);
    unwrap (E.shutdown p))
let selectors env =
  let clock = Eio.Stdenv.clock env in
  ["typed_values_and_failures", typed_values_and_failures;
   "ingest_semantics", ingest_semantics;
   "native_cancellation", (fun () -> native_cancellation clock);
   "native_success", (fun () -> native_success clock);
   "metadata_race", (fun () -> metadata_race clock)]

let run_if_selected env selector =
  match List.find (selectors env) ~f:(fun (name, _) -> String.equal selector name) with
  | None -> false
  | Some (name, test) ->
    (* Standalone generated target also uses the foundation wrapper: disable its
       connect-fault fixture before creating the first pool. *)
    H.initialize (-1);
    test (); Stdlib.Printf.printf "typed_cases %s: PASS generated=%b\n%!" name P.enabled;
    true

let run env =
  match Array.to_list (Sys.get_argv ()) with
  | [_] ->
    H.initialize (-1);
    List.iter (selectors env) ~f:(fun (name, test) ->
      test (); Stdlib.Printf.printf "typed_cases %s: PASS generated=%b\n%!" name P.enabled)
  | [_; selector] ->
    if not (run_if_selected env selector) then
      invalid_arg ("unknown typed_cases selector: " ^ selector)
  | _ -> invalid_arg "typed_cases accepts at most one selector"
