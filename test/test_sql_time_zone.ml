open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module S = D.Sql
let ok = function Ok x -> x | Error (e : D.Error.t) ->
  failwith (match e.cause with Native s -> "Native: " ^ s | _ -> "unexpected error")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])

(* Sql.value of dates, timestamps and blobs round-trips exactly. Run by dune
   with TZ=America/New_York (the library refuses SET, and DuckDB takes its
   default time zone from TZ at startup): casting a TIMESTAMP to TIMESTAMPTZ
   would shift by the zone offset. *)
let () =
  let module V = D.Codec.Values in
  let one = T.(declare "one" Columns.["id", int64] ~row:Fn.id) in
  let stamps = S.(query Params.[] (fun [] -> from one (fun [_] ->
    select Exprs.[value V.date (-719162l); value V.date 19000l; value V.timestamp_us 1700000000123456L;
                  value V.timestamp_ms (-1700000000123L); value V.timestamp_s 1700000000L;
                  value V.timestamp_ns 1700000000123456789L; value V.timestamp_tz 1700000000123456L;
                  value V.blob "\xAA\x00'\xFF"]
      ~row:(fun a b c d e f g h -> (a, b, c, d, e, f, g, h))))) in
  connected (fun c ->
    assert (String.equal (ok (R.Session.find c (R.one D.Fields.[] D.Fields.[string] ~row:Fn.id
      "SELECT current_setting('TimeZone')") D.Args.[])) "America/New_York");
    ddl c "CREATE TABLE one(id BIGINT NOT NULL)";
    ddl c "INSERT INTO one VALUES (1)";
    match ok (R.Session.collect c stamps D.Args.[]) with
    | [ (-719162l, 19000l, 1700000000123456L, -1700000000123L, 1700000000L, 1700000000123456789L,
         1700000000123456L, "\xAA\x00'\xFF") ] -> ()
    | _ -> failwith "stamps");
  Stdlib.print_endline "sql: value dates, timestamps and blobs round-trip under a non-UTC time zone=ok"
