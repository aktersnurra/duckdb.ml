(* Independent unsafe consumer: establish ownership and async cleanup explicitly. *)
module F = Duckdb_ffi
let () =
  let db = F.database_owner () in
  Fun.protect ~finally:(fun () -> F.finish_database_close db) (fun () ->
    Sys.with_async_exns (fun () ->
      F.open_database db "" 1 0 false; assert (F.database_status db = 0);
      let c = F.connection_owner db in
      Fun.protect ~finally:(fun () -> F.finish_connection_close c) (fun () ->
        Sys.with_async_exns (fun () ->
          F.connect c; assert (F.connection_status c = 0);
          let p = F.prepared_owner c in
          Fun.protect ~finally:(fun () -> F.finish_prepared_close p) (fun () ->
            Sys.with_async_exns (fun () ->
              F.prepare p "SELECT ?::BIGINT"; assert (F.prepared_status p = 0);
              F.bind_int64 p 1 5 Int64.min_int; assert (F.prepared_status p = 0);
              F.execute_prepared p; assert (F.prepared_status p = 0);
              assert (F.column_type p 0 = 5); assert (F.fetch p = 1);
              assert (F.chunk_valid p 0 0);
              assert (F.box_int64 (F.chunk_int64 p 0 0) = Int64.min_int);
              F.close_result p; F.close_prepared p));
          F.close_connection c));
      F.close_database db));
  assert (F.live_resources () = 0); print_endline "installed duckdb-ffi prepared alone: ok"
