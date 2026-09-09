module System_thread = Thread
open! Base
module D = Duckdb
type database = Database of D.database
type slot = Slot of D.connection
let active = System_thread.TLS.new_key (fun () -> false)
let is_in_callback () = System_thread.TLS.get active
let open_database config = Result.map (D.open_database config) ~f:(fun db -> Database db)
let connect (Database db) = Result.map (D.connect db) ~f:(fun c -> Slot c)
let close_slot (Slot c) = D.close_connection c
let close_database (Database db) = D.close_database db
let execute (Slot c) request sql = D.Bridge.run request c ~f:(fun facade -> D.execute facade sql)
let with_callback f =
  let previous = System_thread.TLS.get active in
  System_thread.TLS.set active true;
  Exn.protect ~f ~finally:(fun () -> System_thread.TLS.set active previous)
let transaction (Slot c) request ~f =
  D.Bridge.run request c ~f:(fun facade -> D.with_transaction facade ~f:(fun tx -> with_callback (fun () -> f tx)))
let query (Slot c) request sql row =
  D.Bridge.run request c ~f:(fun facade ->
    D.with_prepared facade sql ~f:(fun prepared ->
      Result.bind (D.execute_prepared prepared) ~f:(fun result ->
        D.fold_rows result row ~init:[] ~f:(fun value values -> Ok (D.Continue (value :: values)))
        |> Result.map ~f:List.rev)))
let fold_rows (Slot c) request sql row ~init ~f =
  D.Bridge.run request c ~f:(fun facade ->
    D.with_prepared facade sql ~f:(fun prepared ->
      Result.bind (D.execute_prepared prepared) ~f:(fun result ->
        D.fold_rows result row ~init ~f:(fun value accumulator ->
          with_callback (fun () -> f value accumulator)))))
let ingest (Slot c) request ~schema ~table ~batches ~flush =
  let rec append appender = function
    | [] -> Ok ()
    | batch :: rest -> Result.bind (D.append_rows appender batch) ~f:(fun () -> append appender rest) in
  D.Bridge.run request c ~f:(fun facade ->
    D.with_transaction facade ~f:(fun transaction ->
      D.with_appender_transaction transaction ?schema table ~f:(fun appender ->
        Result.bind (append appender batches) ~f:(fun () ->
          if flush then D.flush_appender appender else Ok ()))))
let paths names =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | name :: rest -> Result.bind (D.Parquet.path name) ~f:(fun path -> loop (path :: reversed) rest) in
  loop [] names
let parquet_fold_rows (Slot c) request names row ~init ~f =
  D.Bridge.run request c ~f:(fun facade ->
    Result.bind (paths names) ~f:(fun paths ->
      D.Parquet.fold_rows facade paths row ~init ~f:(fun value accumulator ->
        with_callback (fun () -> f value accumulator))))
let parquet_export (Slot c) request ~query ~destination =
  D.Bridge.run request c ~f:(fun facade ->
    Result.bind (D.Parquet.path destination) ~f:(fun path -> D.Parquet.export facade ~query path))
