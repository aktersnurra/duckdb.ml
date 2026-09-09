module Thread = Thread
open! Base
module D = Duckdb
type database = Database of D.database
type slot = Slot of D.connection
let active = Thread.TLS.new_key (fun () -> false)
let is_in_callback () = Thread.TLS.get active
let open_database c = Result.map (D.open_database c) ~f:(fun x -> Database x)
let connect (Database d) = Result.map (D.connect d) ~f:(fun x -> Slot x)
let close_slot (Slot s) = D.close_connection s
let close_database (Database d) = D.close_database d
let execute (Slot s) r sql = D.Bridge.run r s ~f:(fun c -> D.execute c sql)
let with_callback f =
  let previous = Thread.TLS.get active in
  Thread.TLS.set active true;
  Exn.protect ~f ~finally:(fun () -> Thread.TLS.set active previous)
let transaction (Slot s) r ~f =
  D.Bridge.run r s ~f:(fun c -> D.with_transaction c ~f:(fun tx -> with_callback (fun () -> f tx)))
let query (Slot s) r sql row =
  D.Bridge.run r s ~f:(fun c ->
    D.with_prepared c sql ~f:(fun prepared ->
      Result.bind (D.execute_prepared prepared) ~f:(fun result ->
        D.fold_rows result row ~init:[] ~f:(fun value values -> Ok (D.Continue (value :: values)))
        |> Result.map ~f:List.rev)))
let fold_rows (Slot s) r sql row ~init ~f =
  D.Bridge.run r s ~f:(fun c ->
    D.with_prepared c sql ~f:(fun prepared ->
      Result.bind (D.execute_prepared prepared) ~f:(fun result ->
        D.fold_rows result row ~init ~f:(fun value accumulator -> with_callback (fun () -> f value accumulator)))))
let ingest (Slot s) r ~schema ~table ~batches ~flush =
  let rec append appender = function
    | [] -> Ok ()
    | batch :: rest -> Result.bind (D.append_rows appender batch) ~f:(fun () -> append appender rest) in
  D.Bridge.run r s ~f:(fun c ->
    D.with_transaction c ~f:(fun transaction ->
      D.with_appender_transaction transaction ?schema table ~f:(fun appender ->
        Result.bind (append appender batches) ~f:(fun () -> if flush then D.flush_appender appender else Ok ()))))
let paths names =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | name :: rest -> Result.bind (D.Parquet.path name) ~f:(fun path -> loop (path :: reversed) rest) in
  loop [] names
let parquet_fold_rows (Slot s) r names row ~init ~f =
  D.Bridge.run r s ~f:(fun c ->
    Result.bind (paths names) ~f:(fun paths ->
      D.Parquet.fold_rows c paths row ~init ~f:(fun value accumulator -> with_callback (fun () -> f value accumulator))))
let parquet_export (Slot s) r ~query ~destination =
  D.Bridge.run r s ~f:(fun c ->
    Result.bind (D.Parquet.path destination) ~f:(fun path -> D.Parquet.export c ~query path))
