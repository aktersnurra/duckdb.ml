open! Base
module D = Duckdb
module B = D.Bridge
external reset_counts : unit -> unit = "adapter_bridge_reset"
external count : int -> int = "adapter_bridge_count"
let check label condition = if not condition then failwith label
let ok = function Ok value -> value | Error _ -> failwith "expected Ok"
let rows connection =
  D.Statement.with_prepared connection "SELECT i FROM recovery_rows ORDER BY i" ~f:(fun prepared ->
    D.Statement.fold_chunks prepared ~init:[] ~f:(fun chunk values ->
      let values = ref values and failure = ref None in
      for row = 0 to D.Statement.chunk_length chunk - 1 do
        if Option.is_none !failure then
          (match D.Statement.column chunk ~column:0 ~row D.Codec.Values.int64 with
           | Ok value -> values := value :: !values
           | Error e -> failure := Some e)
      done;
      match !failure with None -> Ok (D.Continue !values) | Some e -> Error e))
let still_admitted request owner =
  check "ordinary rollback leaves the same request Pending"
    (match B.settlement request with Pending -> true | Settled -> false);
  check "ordinary rollback retains the single native installation"
    (count 5 = 1 && count 6 = 0 && count 7 = 0 && count 4 = 0);
  check "owner alias stays Busy after recoverable rollback"
    (match D.execute owner "SELECT 1" with Error { cause = Busy; _ } -> true | _ -> false)
let expect_native_error = function
  | Error { D.Error.cause = Native message; _ } ->
    check "native diagnostic retained" (not (String.is_empty message))
  | _ -> failwith "expected native error, not cancellation or revocation"
type failure = Result_error | Native_error | Callback_exception
exception Recoverable_callback
let raise_recoverable_callback () = raise Recoverable_callback
let transaction_recovery failure owner observer =
  let request = B.create () in
  reset_counts ();
  ok (B.run request owner ~f:(fun facade ->
    let outcome =
      try `Result (D.with_transaction facade ~f:(fun transaction ->
        ok (D.execute transaction "INSERT INTO recovery_rows VALUES (1)");
        match failure with
        | Result_error -> Error { D.Error.context = Transaction; cause = Embedded_nul }
        | Native_error -> D.execute transaction "SELECT missing_recovery_column"
        | Callback_exception -> raise_recoverable_callback ()))
      with Recoverable_callback as exception_ ->
        `Exception (exception_, Stdlib.Printexc.get_raw_backtrace ()) in
    (match failure, outcome with
     | Result_error, `Result (Error { cause = Embedded_nul; _ }) -> ()
     | Native_error, `Result result -> expect_native_error result
     | Callback_exception, `Exception (exception_, backtrace) ->
       check "recoverable exception identity" (phys_equal exception_ Recoverable_callback);
       check "recoverable exception backtrace"
         (String.is_substring (Stdlib.Printexc.raw_backtrace_to_string backtrace)
            ~substring:"raise_recoverable_callback")
     | _ -> failwith "ordinary transaction error changed");
    check "ordinary transaction error rolls back before returning"
      (count 1 = 1 && count 2 = 0 && count 3 = 1);
    still_admitted request owner;
    ok (D.execute facade "INSERT INTO recovery_rows VALUES (2)");
    ok (D.with_transaction facade ~f:(fun transaction ->
      D.execute transaction "INSERT INTO recovery_rows VALUES (3)"));
    check "later user work and transaction commit after rollback"
      (count 1 = 2 && count 2 = 1 && count 3 = 1);
    still_admitted request owner;
    Ok ()));
  check "one request detaches only at Bridge settlement"
    (count 5 = 1 && count 6 = 1 && count 7 = 1 && count 4 = 0);
  check "request settled" (match B.settlement request with Settled -> true | Pending -> false);
  check "observer sees only post-rollback writes"
    (List.equal Int64.equal (ok (rows observer)) [3L; 2L]);
  ok (D.execute owner "SELECT 1")
let snapshot_recovery owner observer =
  let request = B.create () in
  reset_counts ();
  ok (B.run request owner ~f:(fun facade ->
    (* Preparation succeeds; the NOT NULL violation occurs at native execute
       inside the real Query.execute_prepared (under Statement.fold_chunks) ->
       Resource.with_child_snapshot. *)
    ok (D.Statement.with_prepared facade "INSERT INTO recovery_rows VALUES (NULL) RETURNING i"
      ~f:(fun prepared ->
        expect_native_error (D.Statement.execute prepared);
        check "snapshot error rolls back before returning"
          (count 0 = 1 && count 1 = 1 && count 2 = 0 && count 3 = 1);
        still_admitted request owner;
        Ok ()));
    ok (D.execute facade "INSERT INTO recovery_rows VALUES (2)");
    ok (D.Statement.with_prepared facade "INSERT INTO recovery_rows VALUES (3) RETURNING i"
      ~f:D.Statement.execute);
    check "later raw execute and fresh snapshot commit after rollback"
      (count 0 = 3 && count 1 = 2 && count 2 = 1 && count 3 = 1);
    still_admitted request owner;
    Ok ()));
  check "snapshot recovery uses one native request through terminal detach"
    (count 5 = 1 && count 6 = 1 && count 7 = 1 && count 4 = 0);
  check "snapshot request settled" (match B.settlement request with Settled -> true | Pending -> false);
  check "observer sees successful writes after snapshot rollback"
    (List.equal Int64.equal (ok (rows observer)) [3L; 2L]);
  ok (D.execute owner "SELECT 1")
let run () =
  Stdlib.Printexc.record_backtrace true;
  let live = Duckdb_ffi.live_resources () and fallback = Duckdb_ffi.fallback_reclaims () in
  List.iter
    ["transaction result", transaction_recovery Result_error;
     "transaction native error", transaction_recovery Native_error;
     "transaction caught exception", transaction_recovery Callback_exception;
     "snapshot native error", snapshot_recovery]
    ~f:(fun (name, test) ->
      ok (D.with_database (ok (D.Config.create D.Config.Memory)) ~f:(fun database ->
        D.with_connection database ~f:(fun owner ->
          D.with_connection database ~f:(fun observer ->
            ok (D.execute owner "CREATE TABLE recovery_rows (i BIGINT NOT NULL)");
            test owner observer;
            Ok ()))));
      check "ordinary recovery has no live-resource leak" (Duckdb_ffi.live_resources () = live);
      check "ordinary recovery never uses fallback reclamation" (Duckdb_ffi.fallback_reclaims () = fallback);
      Stdlib.print_endline ("safe Bridge recovery: " ^ name ^ " passed"));
  Stdlib.print_endline "existing semantics only: USER disabled; no controller/delivery/race proof"
let () = run ()
