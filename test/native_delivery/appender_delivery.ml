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
external gate_at_create : int -> unit = "delivery_gate_at_create"
module T = D.Table
let check name condition = if not condition then failwith name
let ok = function Ok x -> x | Error _ -> failwith "Appender expected Ok"
let cancelled = function Error D.Cancelled -> () | _ -> failwith "Appender expected Cancelled"
let reset () = reset_hooks (); query_mode ()
let release () = for i = 1 to 63 do gate i false done; selected_gate false
let wait id = E.await ~label:("Appender native boundary " ^ Int.to_string id) (fun () -> entered id > 0)
let wait_count id n = E.await ~label:("Appender count " ^ Int.to_string id) (fun () -> count id >= n)
let one_controller () = check "Appender sole controller joined" (count 10 = 1 && count 12 = 1)
let row = D.Args.[1L]
let app = T.(declare "app" Columns.[ "i", int64 ] ~row:Fn.id)
let core r = Result.map_error r ~f:(fun (e : D.Request.request_error) ->
  match e.cause with D.Request.Core e -> e | _ -> failwith "Appender unexpected typed failure")
(* Raw execute accepts exactly one statement. The sequence does not roll back:
   observing its next value proves no flush, unlike transactional row counts. *)
let setup owner =
  ok (D.execute owner "CREATE SEQUENCE app_flush");
  ok (D.execute owner "CREATE TABLE app(i BIGINT CHECK(nextval('app_flush') > 0))")
let scalar owner sql =
  let p = ok (D.prepare owner sql) in
  Exn.protect ~finally:(fun () -> ok (D.close_prepared p)) ~f:(fun () ->
    let r = ok (D.execute_prepared p) in
    ok (D.fold_chunks r ~init:0L ~f:(fun chunk _ ->
      match D.column chunk ~column:0 ~row:0 D.Codec.Values.int64 with
      | Ok n -> Ok (D.Continue n)
      | Error e -> Error e)))
let no_flush owner = check "Appender cancelled cleanup never flushes sequence" (Int64.equal (scalar owner "SELECT nextval('app_flush')") 1L)
let next_suppressed c = cancelled (D.execute c "SELECT 42")
let metadata ?(view = false) point ~user ~native_error owner =
  if view then (
    ok (D.execute owner "CREATE SEQUENCE app_flush");
    ok (D.execute owner "CREATE VIEW app AS SELECT 1::BIGINT AS i"))
  else setup owner;
  (* The table's catalog query runs first; gate the appender's own metadata. *)
  reset (); gate_at_create point; if user then selected_gate true;
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let table = if native_error && not view then T.(declare "absent_app" Columns.[ "i", int64 ] ~row:Fn.id) else app in
    let result = core (T.with_appender c table ~f:(fun _ -> failwith "cancelled appender exposed")) in
    next_suppressed c; result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if user then (
        E.await ~label:"Appender metadata selected or premature join" (fun () -> selected_entered () || count 11 > 0);
        check "Appender metadata admits USER" (selected_entered ()));
      gate point false; wait_count 11 1;
      if point = 33 then check "Appender metadata first native admission suppresses extraction" (count 0 = 0 && count 27 = 0);
      if point = 2 then check "Appender metadata prepare suppressed" (count 1 = 0 && count 27 = 0);
      if point = 4 || point = 41 then check "Appender metadata execute suppressed" (count 2 = 0);
      if point = 6 then check "Appender metadata fetch suppressed" (count 24 = 0);
      if point = 31 then check "Appender metadata next fetch/create suppressed" (count 24 = 1 && count 28 = 0);
      if point = 63 then check "Appender create admission suppressed after metadata exhaustion" (count 24 = 2 && count 28 = 0);
      if point = 39 then check "Appender schema admission suppressed" (count 36 = 0);
      selected_gate false;
      (match join () with
       | Error (D.Native_error _) when native_error -> ()
       | result -> cancelled result);
      check "Appender metadata delivery skipped" (count 4 = 0); one_controller ()));
  no_flush owner
let mutation point owner =
  setup owner; reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    core (T.with_appender c app ~f:(fun a ->
      gate point true; if point = 45 then selected_gate true;
      let result = T.append a [row; row] in
      cancelled (core (T.append a [row])); cancelled (core (T.flush a));
      result))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if point = 45 then E.await ~label:"Appender end-row selected" selected_entered;
      gate point false; wait_count 11 1; selected_gate false; cancelled (join ());
      if point = 35 then check "Appender batch admission suppresses begin-row" (count 29 = 0);
      if point = 43 then check "Appender cell admission suppresses append-value" (count 30 = 0);
      if point = 47 || point = 29 then check "Appender end-row admission suppressed" (count 31 = 0);
      if point = 45 then check "Appender next row suppressed" (count 29 = 1 && count 31 = 1);
      check "Appender cancelled append never explicit flushes" (count 32 = 0 && count 33 = 0);
      check "Appender cell/value memory destroyed" (count 26 = count 30);
      one_controller ()));
  no_flush owner
let flush ~close ~before owner =
  setup owner; reset ();
  let request = B.create () in
  let point = if before then 36 else 54 in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    core (T.with_appender c app ~f:(fun a ->
      ok (T.append a [row]); gate point true; if not before then selected_gate true;
      (* [close]: the scope's own close flushes, then clears/destroys. *)
      if close then Ok () else T.flush a))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if not before then E.await ~label:"Appender flush selected" selected_entered;
      gate point false; wait_count 11 1; selected_gate false; cancelled (join ());
      check "Appender flush admission" (count 32 = (if before then 0 else 1));
      check "Appender destruction never requests native close flush" (count 33 = 0);
      one_controller ()));
  if before then no_flush owner
  else check "Appender admitted flush may advance nontransactional sequence" (Int64.(scalar owner "SELECT nextval('app_flush')" > 1L))
let cleanup ?destructor ~internal owner =
  setup owner; reset ();
  let request = B.create () in
  let destructor = Option.value destructor ~default:(if internal then 8 else 48) in
  let point = if internal then (if destructor = 32 then 31 else 4) else 39 in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    D.with_transaction c ~f:(fun tx ->
      (* BEGIN has its own result destruction; arm only after it completes,
         and after the table's catalog query, at the native appender creation. *)
      gate_at_create point; gate_at_create destructor; selected_gate true;
      core (T.with_appender_transaction tx app ~f:(fun _ -> failwith "cancelled create published")))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if internal then E.await ~label:"Appender internal metadata selection" selected_entered;
      gate point false;
      E.await ~label:"Appender cleanup join or destructor" (fun () -> count 11 > 0 || entered destructor > 0);
      if internal then (
        wait destructor; check "Appender internal cleanup before ML join" (count 11 = 0);
        selected_gate false; wait_count 17 1;
        check "Appender internal cleanup excludes delivery" (count 4 = 0))
      else (
        check "Appender direct cleanup joins before destructor" (count 11 = 1);
        selected_gate false; wait destructor;
        check "Appender destructor follows join" (count 40 = 1 && count 12 = 1));
      gate destructor false; cancelled (join ()); one_controller ()));
  no_flush owner
let paired_control owner =
  setup owner; reset ();
  ok (B.run (B.create ()) owner ~f:(fun c -> core (T.with_appender c app ~f:(fun a -> T.append a [row]))));
  one_controller ();
  check "Appender normal close flush paired control" (Int64.(scalar owner "SELECT nextval('app_flush')" > 1L));
  check "Appender normal close commits" (Int64.equal (scalar owner "SELECT count(*) FROM app") 1L)
external auto_gate : int -> unit = "delivery_appender_auto_gate"
let close_cleanup destructor owner =
  setup owner; reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    core (T.with_appender c app ~f:(fun a ->
      (* The scope's own close flushes (54), then clears/destroys. *)
      ok (T.append a [row]); gate 54 true; gate destructor true; selected_gate true;
      Ok ()))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 54; ok (B.cancel request); E.await ~label:"Appender close selected" selected_entered;
      gate 54 false;
      E.await ~label:"Appender close actual join or destructor" (fun () -> count 11 > 0 || entered destructor > 0);
      check "Appender close joins selected before destructor" (count 11 = 1 && entered destructor = 0);
      check "Appender selected cannot detach/disconnect" (count 13 = 0 && count 5 = 0 && count 12 = 0);
      check "Appender selected owner cannot reuse" (match D.execute owner "SELECT 1" with Error D.Busy -> true | _ -> false);
      selected_gate false; wait destructor;
      check "Appender clear/destroy follows retirement and join" (count 12 = 1 && count 14 = count 17 && count 4 = 0);
      gate destructor false; cancelled (join ()); one_controller ()))
let automatic ~running owner =
  if running then ok (D.execute owner "CREATE TABLE app(i BIGINT CHECK(length(sha256(repeat(i::VARCHAR, 100))) > 0))")
  else setup owner;
  reset (); auto_gate 204800;
  let request = B.create () in
  let point = if running then 59 else 61 in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    core (T.with_appender c app ~f:(fun a ->
      gate point true; if not running then selected_gate true;
      T.append a (List.init 220000 ~f:(fun _ -> row))))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request);
      if running then wait_count 4 1 else E.await ~label:"Appender automatic selected" selected_entered;
      let before = count 4 in
      gate point false;
      if not running then (wait_count 11 1; selected_gate false);
      (match join () with
       | Error (D.Native_error message) when running -> check "Appender real automatic flush interrupted diagnostic" (String.is_substring (String.lowercase message) ~substring:"interrupt")
       | result -> if running then failwith "Appender interrupted diagnostic flattened" else cancelled result);
      check "Appender automatic flush suppresses later rows" (count 29 = 204800 && count 31 = 204800);
      if running then (
        check "Appender automatic repeat delivery survives INSERT reset" (count 4 > before && count 39 = 1 && count 5 = 1);
        check "Appender interrupted owner discarded" (match D.execute owner "SELECT 1" with Error D.Closed -> true | _ -> false))
      else check "Appender automatic selection skips" (count 4 = 0);
      one_controller ()));
  if not running then check "Appender actual automatic flush sequence evidence" (Int64.(scalar owner "SELECT nextval('app_flush')" > 1L))
let native_failure ~automatic owner =
  ok (D.execute owner "CREATE TABLE app(i BIGINT CHECK(i < 0))"); reset ();
  let request = B.create () in
  let point = if automatic then 60 else 54 in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    let result = core (T.with_appender c app ~f:(fun a ->
      gate point true; selected_gate true;
      let result = if automatic then T.append a (List.init 220000 ~f:(fun _ -> row))
        else (ok (T.append a [row]); T.flush a) in
      cancelled (core (T.append a [row])); result)) in
    next_suppressed c; result))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait point; ok (B.cancel request); E.await ~label:"Appender native error selected" selected_entered;
      gate point false; wait_count 11 1; selected_gate false;
      (match join () with
       | Error (D.Native_error message) -> check "Appender native constraint diagnostic retained" (String.is_substring message ~substring:"CHECK")
       | _ -> failwith "Appender native diagnostic replaced by cancellation");
      check "Appender native error rolls back without commit" (count 7 = 0 && count 8 = 1);
      one_controller ()))
exception Appender_callback_failure
let[@inline never] appender_callback_failure_frame request =
  ok (B.cancel request); raise Appender_callback_failure
let caught_callback owner =
  setup owner; reset ();
  let request = B.create () in
  cancelled (B.run request owner ~f:(fun c ->
    (match E.capture (fun () -> T.with_appender c app ~f:(fun a ->
      ok (T.append a [row]); appender_callback_failure_frame request)) with
     | E.Raised failure ->
       check "Appender caught exception identity" (phys_equal failure.exception_ Appender_callback_failure);
       check "Appender caught exception source backtrace" (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string failure.backtrace) ~substring:"appender_callback_failure_frame")
     | _ -> failwith "Appender expected callback exception");
    next_suppressed c; Ok ()));
  one_controller (); no_flush owner
let batch_and_transaction ~cancel owner =
  setup owner; reset ();
  let request = B.create () in
  let result = B.run request owner ~f:(fun c ->
    let result = D.with_transaction c ~f:(fun tx ->
      core (T.with_appender_transaction tx app ~f:(fun a ->
        ok (T.append a [row]);
        if cancel then (ok (B.cancel request); cancelled (core (T.append a [row])); Ok ())
        else T.append a [row]))) in
    if cancel then (cancelled result; next_suppressed c; Ok ()) else result) in
  if cancel then (cancelled result; no_flush owner) else (
    ok result; check "Appender transaction variant two batches commit" (Int64.equal (scalar owner "SELECT count(*) FROM app") 2L));
  one_controller ()
let rollback ~cancel owner =
  setup owner; reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    gate 11 true;
    let primary = { D.Request.context = D.Request.Transaction; cause = D.Request.Core D.Unsupported_statement } in
    let result = T.with_appender c app ~f:(fun a ->
      ok (T.append a [row]); Error primary) in
    check "Appender rollback primary error retained" (match result with Error e -> phys_equal e primary | _ -> false);
    if cancel then (next_suppressed c; Ok ()) else D.execute c "SELECT 42"))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 11;
      check "Appender ordinary rollback retains sole controller" (count 10 = 1 && count 11 = 0 && count 12 = 0);
      if cancel then ok (B.cancel request);
      gate 11 false;
      if cancel then cancelled (join ()) else ok (join ());
      check "Appender rollback never USER" (count 4 = 0 && count 8 = 1 && count 7 = 0);
      one_controller ()));
  no_flush owner
let cleanup_admitted destructor owner =
  setup owner; reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c ->
    (* The scope's own close clears/destroys (destructor) after its flush. *)
    core (T.with_appender c app ~f:(fun a ->
      ok (T.append a [row]); gate destructor true; Ok ()))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait destructor;
      check "Appender ordinary destruction retains controller" (count 11 = 0);
      ok (B.cancel request); gate destructor false; cancelled (join ());
      check "Appender cleanup cancellation never delivers" (count 4 = 0 && count 14 = 0);
      one_controller ()))
let temporal_value owner =
  ok (D.execute owner "CREATE TABLE app(i TIMESTAMP_S)"); reset ();
  let request = B.create () in
  let app = T.(declare "app" Columns.[ "i", of_scalar D.Scalar.Timestamp_s ] ~row:Fn.id) in
  E.with_worker (fun () -> B.run request owner ~f:(fun c -> core (T.with_appender c app ~f:(fun a ->
    gate 26 true; T.append a [D.Args.[1L]]))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 26; ok (B.cancel request); gate 26 false; cancelled (join ());
      check "Appender temporary value second admission suppresses append" (count 30 = 0 && count 26 = 1);
      check "Appender temporary value never USER" (count 4 = 0 && count 14 = 0);
      one_controller ()))
let running_flush ~close owner =
  ok (D.execute owner "CREATE TABLE app(i BIGINT CHECK(length(sha256(repeat(i::VARCHAR, 100))) > 0))");
  reset ();
  let request = B.create () in
  E.with_worker (fun () -> B.run request owner ~f:(fun c -> core (T.with_appender c app ~f:(fun a ->
    ok (T.append a (List.init 200000 ~f:(fun _ -> row)));
    gate 53 true;
    (* [close]: the scope's own close flushes (53), then clears/destroys. *)
    if close then Ok () else T.flush a))))
    ~f:(fun join -> Exn.protect ~finally:release ~f:(fun () ->
      wait 53; ok (B.cancel request); wait_count 4 1;
      let before = count 4 in gate 53 false;
      (match join () with
       | Error (D.Native_error message) -> check "Appender real explicit flush interrupted diagnostic" (String.is_substring (String.lowercase message) ~substring:"interrupt")
       | _ -> failwith "Appender explicit flush diagnostic flattened");
      check "Appender explicit flush repeat delivery survives INSERT reset" (count 4 > before && count 5 = 1);
      check "Appender explicit flush destroyed after cancellation" (count 34 = 1 && count 35 = 1 && count 33 = 0);
      one_controller ()))
let tests =
  ["appender-explicit-flush-running", running_flush ~close:false;
   "appender-normal-close-running", running_flush ~close:true;
   "appender-cleanup-admitted-clear", cleanup_admitted 48;
   "appender-cleanup-admitted-destroy", cleanup_admitted 49;
   "appender-temporary-value", temporal_value;
   "appender-metadata-publish", metadata 62 ~user:false ~native_error:false;
   "appender-create-admitted", metadata 38 ~user:false ~native_error:false;
   "appender-schema-admitted", metadata 52 ~user:false ~native_error:false;
   "appender-create-before", metadata 63 ~user:true ~native_error:false;
   "appender-create-failure", metadata ~view:true 39 ~user:false ~native_error:true;
   "appender-metadata-result-cleanup", cleanup ~destructor:7 ~internal:true;
   "appender-metadata-chunk-cleanup", cleanup ~destructor:32 ~internal:true;
   "appender-metadata-extracted-cleanup", cleanup ~destructor:9 ~internal:true;
   "appender-caught-callback", caught_callback;
   "appender-automatic-running", automatic ~running:true;
   "appender-automatic-return", automatic ~running:false;
   "appender-native-failure", native_failure ~automatic:false;
   "appender-automatic-failure", native_failure ~automatic:true;
   "appender-metadata-error", metadata 31 ~user:true ~native_error:true;
   "appender-close-clear-retirement", close_cleanup 48;
   "appender-close-destroy-retirement", close_cleanup 49;
   "appender-transaction-batches", batch_and_transaction ~cancel:false;
   "appender-transaction-cancel", batch_and_transaction ~cancel:true;
   "appender-rollback-recover", rollback ~cancel:false;
   "appender-rollback-cancel-after", rollback ~cancel:true;
   "appender-control", paired_control;
   "appender-internal-cleanup", cleanup ~destructor:8 ~internal:true;
   "appender-create-cleanup", cleanup ~destructor:48 ~internal:false]
  @ List.map [33; 2; 4; 41; 6; 31; 39; 34] ~f:(fun point ->
    "appender-metadata-" ^ Int.to_string point, metadata point ~user:(List.mem [2; 4; 6; 31] point ~equal:Int.equal) ~native_error:false)
  @ List.map [35; 43; 47; 29; 45] ~f:(fun point -> "appender-mutation-" ^ Int.to_string point, mutation point)
  @ List.concat_map [true; false] ~f:(fun close -> List.map [true; false] ~f:(fun before ->
    "appender-" ^ (if close then "close" else "flush") ^ (if before then "-before" else "-return"), flush ~close ~before))
