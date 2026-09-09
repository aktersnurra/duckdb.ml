open! Base
module E = Duckdb_eio
exception Requested
let unwrap = function Ok x -> x | Error _ -> failwith "adapter error"
let ok = function Ok x -> x | Error _ -> failwith "DuckDB error"
let run () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let limits = unwrap (E.limits ~connections:1 ~queue_capacity:1) in
      let pool = unwrap (E.create ~sw limits (ok (Duckdb.Config.create Duckdb.Config.Memory))) in
      assert (Result.is_ok (E.execute pool "CREATE TABLE t(x INTEGER)"));
      let value = unwrap (E.transaction pool ~f:(fun tx ->
        Result.map (Duckdb.execute_transaction tx "INSERT INTO t VALUES (7)") ~f:(fun () -> 7L))) in
      assert (Int64.equal value 7L);
      (* An exception in the worker callback must settle its producer rather
         than strand the sole permit/completion.  The following SQL proves a
         subsequent producer can drain and run. *)
      let callback_raised =
        try
          ignore (E.transaction pool ~f:(fun _ -> raise Requested));
          false
        with Requested -> true
      in
      assert callback_raised;
      assert (Result.is_ok (E.execute pool "INSERT INTO t VALUES (8)"));
      let cancelled = ref false in
      Eio.Cancel.sub (fun cc ->
        Eio.Cancel.cancel cc Requested;
        try ignore (E.execute pool "INSERT INTO t VALUES (99)") with Eio.Cancel.Cancelled _ -> cancelled := true);
      assert !cancelled;
      assert (Result.is_ok (E.shutdown pool))))
let () = run ()
