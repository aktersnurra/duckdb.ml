open! Base
module E = Duckdb_eio_mutant
let unwrap = function Ok v -> v | Error _ -> failwith "unexpected adapter error"
let config () = unwrap (Duckdb.Config.create Duckdb.Config.Memory)
let run _env =
  Test_support.reset ();
  Eio.Switch.run (fun sw ->
    let p = unwrap (E.create ~sw (unwrap (E.limits ~connections:1 ~queue_capacity:0)) (config ())) in
    Eio.Cancel.sub (fun cc ->
      Test_support.await_then_cancel (fun () -> Eio.Cancel.cancel cc Test_support.Requested);
      try ignore (E.execute p "SELECT 1"); failwith "post-await cancellation was not propagated"
      with Eio.Cancel.Cancelled Test_support.Requested -> ());
    unwrap (E.shutdown p))
let () = Eio_main.run run
