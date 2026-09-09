open! Base
module D = Duckdb
module B = D.Bridge
module E = Evidence_support
external reset_hooks : unit -> unit = "delivery_reset"
external query_mode : unit -> unit = "delivery_query_mode"
external gate : int -> bool -> unit = "delivery_gate"
external entered : int -> int = "delivery_entered"
external count : int -> int = "delivery_count"
external selected_gate : bool -> unit = "delivery_selected_gate"
external selected_entered : unit -> bool = "delivery_selected_entered"
let check name condition = if not condition then failwith name
let ok = function Ok x -> x | Error _ -> failwith "Query expected Ok"
let cancelled = function Error D.Cancelled -> () | _ -> failwith "Query expected Cancelled"
let reset () = reset_hooks (); query_mode ()
let release () = for i = 1 to 32 do gate i false done; selected_gate false
let wait id = E.await ~label:("Query native boundary " ^ Int.to_string id) (fun () -> entered id > 0)
let wait_count id n = E.await ~label:("Query count " ^ Int.to_string id) (fun () -> count id >= n)
let one_controller () = check "Query sole controller joined" (count 10 = 1 && count 12 = 1)
let next_suppressed facade = cancelled (D.execute facade "SELECT 42")
let before_prepare owner =
  reset (); gate 14 true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let result = D.prepare c "SELECT 1" in next_suppressed c; Result.map result ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 14; ok (B.cancel request); gate 14 false;
      cancelled (join ()); check "Query prepare native admission suppresses extraction" (count 0 = 0);
      one_controller ()))
let prepare_subcall ~schema point owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let work () = if schema then (
      let p = ok (D.prepare c "SELECT 1") in
      gate point true; selected_gate true;
      Result.map (D.execute_prepared p) ~f:(fun _ -> ()))
    else (gate point true; selected_gate true; Result.map (D.prepare c "SELECT 1") ~f:(fun _ -> ())) in
    let result = work () in next_suppressed c; result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      (* Either selection or premature cleanup join: baseline non-USER must fail
         the assertion, not rely on a selection timeout. *)
      E.await ~label:"Query prepare selection or cleanup" (fun () -> selected_entered () || count 11 > 0);
      check "Query prepare admits USER" (selected_entered ());
      gate point false; wait_count 11 1;
      check "Query next prepare subcall suppressed" (if point = 2 then count 1 = (if schema then 1 else 0) else count 2 = 0);
      check "Query cleanup awaits selected retirement" (count 12 = 0 && count 13 = 0);
      selected_gate false; cancelled (join ());
      check "Query selected prepare delivery skipped" (count 4 = 0 && count 16 = 1); one_controller ()))
let bind_case ~before kind owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let sql, work = match kind with
      | "reset" -> "SELECT ?::BIGINT", (fun p -> D.reset p)
      | "null" -> "SELECT ?::BIGINT", (fun p -> D.bind p 1 (D.Scalar.Nullable D.Scalar.Int64) None)
      | "float" -> "SELECT ?::DOUBLE", (fun p -> D.bind p 1 (D.Scalar.Required D.Scalar.Float64) 1.)
      | "string" -> "SELECT ?::VARCHAR", (fun p -> D.bind p 1 (D.Scalar.Required D.Scalar.String) "x")
      | "temporal" -> "SELECT ?::TIMESTAMP_S", (fun p -> D.bind p 1 (D.Scalar.Required D.Scalar.Timestamp_s) 1L)
      | _ -> "SELECT ?::BIGINT", (fun p -> D.bind p 1 (D.Scalar.Required D.Scalar.Int64) 1L) in
    let p = ok (D.prepare c sql) in
    let point = if before then (if String.equal kind "reset" then 15 else 16)
      else if String.equal kind "reset" then 24 else if String.equal kind "temporal" then 26 else 22 in
    gate point true;
    let result = work p in
    next_suppressed c;
    cancelled (D.execute_prepared p);
    result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      let point = if before then (if String.equal kind "reset" then 15 else 16)
        else if String.equal kind "reset" then 24 else if String.equal kind "temporal" then 26 else 22 in
      wait point; ok (B.cancel request); gate point false; cancelled (join ());
      check "Query binding never arms interruption" (count 4 = 0 && count 14 = 0);
      if before then check "Query bind/reset native admission suppresses mutation" (count 20 = 0 && count 21 = 0 && count 22 = 0)
      else if String.equal kind "temporal" then (
        check "Query temporal second admission suppresses bind" (count 23 = 0);
        check "Query temporal always destroyed" (count 26 = 1));
      one_controller ()))
let execute_case ~before owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c "SELECT 1") in
    gate (if before then 17 else 6) true;
    if not before then selected_gate true;
    let result = D.execute_prepared p in next_suppressed c; Result.map result ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      let point = if before then 17 else 6 in
      wait point; ok (B.cancel request);
      if not before then E.await ~label:"Query execute selected" selected_entered;
      gate point false; wait_count 11 1;
      if before then check "Query execute native admission suppresses execution" (count 2 = 0)
      else check "Query produced result awaits retirement before cleanup" (count 12 = 0 && count 13 = 0);
      selected_gate false; cancelled (join ());
      check "Query produced result not published and next work suppressed" (count 7 = 0 && count 4 = 0);
      one_controller ()))
let running owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c "SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)") in
    ok (D.reset p); gate 5 true;
    Result.map (D.execute_prepared p) ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 5; ok (B.cancel request); wait_count 4 1;
      let before = count 4 in gate 5 false;
      (match join () with
       | Error (D.Native_error message) -> check "Query actual interrupted diagnostic" (String.is_substring (String.lowercase message) ~substring:"interrupt")
       | _ -> failwith "Query native diagnostic flattened");
      check "Query repeat delivery survives execute reset" (count 4 > before && count 3 = 1);
      check "Query actually interrupted owner discarded" (count 5 = 1);
      check "Query discarded owner closed" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false);
      one_controller ()))
let fetch_case ?(empty = false) point owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c (if empty then "SELECT 1 WHERE false" else "SELECT i FROM range(10000) t(i)")) in
    let r = ok (D.execute_prepared p) in
    gate point true; if point = 31 then selected_gate true;
    let callbacks = ref 0 in
    let result = D.fold_chunks r ~init:() ~f:(fun _ () -> Int.incr callbacks; Ok (D.Continue ())) in
    check "Query cancelled fetched chunk not exposed" (!callbacks = 0);
    next_suppressed c; result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if point = 31 then E.await ~label:"Query fetch selected" selected_entered;
      gate point false; wait_count 11 1;
      if point = 18 then check "Query fetch admission suppresses engine call" (count 24 = 0)
      else check "Query fold cleanup waits for selected retirement" (count 12 = 0 && count 25 = 0);
      selected_gate false; cancelled (join ());
      check "Query fetch selected delivery excluded" (count 4 = 0); one_controller ()))
let callback ~stop owner =
  reset ();
  let request = B.create () in
  cancelled (B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c "SELECT i FROM range(10000) t(i)") in
    let r = ok (D.execute_prepared p) in
    let callbacks = ref 0 in
    let result = D.fold_chunks r ~init:() ~f:(fun chunk () ->
      Int.incr callbacks; ok (B.cancel request);
      check "Query borrowed chunk remains live through callback cancellation" (D.chunk_length chunk > 0);
      if stop then Ok (D.Stop ()) else Ok (D.Continue ())) in
    check "Query callback batch cancellation suppresses next fetch" (!callbacks = 1 && count 24 = 1);
    next_suppressed c; result)); one_controller ()
(* Observe actual destructor entry OR join; controller selection alone never
   proves the worker reached cleanup. Every failure releases gates before join. *)
let cleanup_join ~schema ~result owner =
  reset ();
  let request = B.create () in
  let point = if result then 31 else 4 in
  let destructor = if result then 32 else 8 in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = if schema || result then Some (ok (D.prepare c "SELECT 1")) else None in
    let r = if result then Some (ok (D.execute_prepared (Option.value_exn p))) else None in
    gate point true; gate destructor true; selected_gate true;
    match r, p with
    | Some r, _ -> D.fold_chunks r ~init:() ~f:(fun _ () -> failwith "cancelled chunk exposed")
    | None, Some p -> Result.map (D.execute_prepared p) ~f:(fun _ -> ())
    | None, None -> Result.map (D.prepare c "SELECT 1") ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request); E.await ~label:"Query cleanup selection" selected_entered;
      gate point false;
      E.await ~label:"Query worker join or destructor" (fun () -> count 11 > 0 || entered destructor > 0);
      check "Query direct cleanup joins before destructor" (count 11 = 1 && entered destructor = 0);
      check "Query no detach or owner close while selected" (count 13 = 0 && count 5 = 0);
      check "Query owner cannot reuse while selected" (match D.execute owner "SELECT 1" with Error D.Busy -> true | _ -> false);
      selected_gate false; wait destructor;
      check "Query destructor follows retirement and join" (count 12 = 1 && count 14 = count 17);
      gate destructor false; cancelled (join ()); one_controller ()))
let extracted_cleanup owner =
  reset (); gate 4 true; gate 9 true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c -> Result.map (D.prepare c "SELECT 1") ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 4; ok (B.cancel request); E.await ~label:"Query extracted selection" selected_entered;
      gate 4 false; wait 9;
      check "Query native extracted cleanup precedes ML join" (count 11 = 0);
      selected_gate false; wait_count 17 1;
      check "Query native extracted cleanup excludes delivery" (count 4 = 0 && count 16 = 1);
      gate 9 false; cancelled (join ()); one_controller ()))
let old_chunk owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c "SELECT i FROM range(10000) t(i)") in
    let r = ok (D.execute_prepared p) in
    let callbacks = ref 0 in
    let result = D.fold_chunks r ~init:() ~f:(fun chunk () ->
      Int.incr callbacks;
      check "Query old chunk valid before callback return" (D.chunk_length chunk > 0 && count 25 = 0);
      gate 32 true; Ok (D.Continue ())) in
    check "Query old chunk cancellation stops next batch" (!callbacks = 1 && count 24 = 1);
    result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 32; ok (B.cancel request); gate 32 false; cancelled (join ());
      check "Query old chunk cleanup remains noninterruptible" (count 4 = 0 && count 14 = 0);
      one_controller ()))
let returned_prepare ~schema owner =
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let p = if schema then Some (ok (D.prepare c "SELECT 1")) else None in
    gate 19 true;
    let result = match p with
      | None -> Result.map (D.prepare c "SELECT 1") ~f:(fun _ -> ())
      | Some p -> Result.map (D.execute_prepared p) ~f:(fun _ -> ()) in
    next_suppressed c; result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 19; ok (B.cancel request); gate 19 false; cancelled (join ());
      check "Query post-prepare cancellation suppresses execution" (count 2 = 0 && count 4 = 0);
      one_controller ()))
let prepare_error owner =
  reset (); gate 4 true; selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    Result.map (D.prepare c "SELECT missing_query_column") ~f:(fun _ -> ())))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 4; ok (B.cancel request); E.await ~label:"Query error selection" selected_entered;
      gate 4 false; wait_count 11 1; selected_gate false;
      (match join () with
       | Error (D.Native_error message) -> check "Query prepare native error retained" (String.is_substring message ~substring:"missing_query_column")
       | _ -> failwith "Query prepare error flattened by cancellation");
      one_controller ()))
exception Query_callback_failure
let query_callback_failure_frame chunk request =
  check "Query exception callback has live chunk" (D.chunk_length chunk > 0);
  ok (B.cancel request); raise Query_callback_failure
let caught_callback owner =
  reset ();
  let request = B.create () in
  cancelled (B.run request owner ~f:(fun c ->
    let p = ok (D.prepare c "SELECT 1") in
    let r = ok (D.execute_prepared p) in
    (match E.capture (fun () -> D.fold_chunks r ~init:() ~f:(fun chunk () -> query_callback_failure_frame chunk request)) with
     | E.Raised failure ->
       check "Query caught exception identity" (phys_equal failure.exception_ Query_callback_failure);
       check "Query caught exception backtrace" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string failure.backtrace) ~substring:"query_callback_failure_frame")
     | _ -> failwith "Query expected callback exception");
    next_suppressed c; Ok ()));
  check "Query caught exception cannot clear cancellation" (count 24 = 1); one_controller ()
let tests =
  ["query-caught-callback", caught_callback;
   "query-empty-fetch-return", fetch_case ~empty:true 31;
   "query-prepared-cleanup", cleanup_join ~schema:false ~result:false;
   "query-schema-cleanup", cleanup_join ~schema:true ~result:false;
   "query-chunk-cleanup", cleanup_join ~schema:false ~result:true;
   "query-extracted-cleanup", extracted_cleanup;
   "query-old-chunk", old_chunk;
   "query-prepare-return", returned_prepare ~schema:false;
   "query-schema-return", returned_prepare ~schema:true;
   "query-prepare-error", prepare_error;
   "query-before-prepare", before_prepare;
   "query-after-extract", prepare_subcall ~schema:false 2;
   "query-after-prepare", prepare_subcall ~schema:false 4;
   "query-schema-extract", prepare_subcall ~schema:true 2;
   "query-schema-prepare", prepare_subcall ~schema:true 4;
   "query-execute-before", execute_case ~before:true;
   "query-execute-return", execute_case ~before:false;
   "query-running-reset", running;
   "query-fetch-before", fetch_case 18;
   "query-fetch-return", fetch_case 31;
   "query-callback-continue", callback ~stop:false;
   "query-callback-stop", callback ~stop:true]
  @ List.concat_map ["reset"; "int"; "null"; "float"; "string"; "temporal"] ~f:(fun kind ->
    List.map [true; false] ~f:(fun before ->
      "query-" ^ kind ^ (if before then "-before" else "-return"), bind_case ~before kind))
