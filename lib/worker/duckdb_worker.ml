open! Base
module D = Duckdb

module type Probe = sig
  val callback_restored : active:bool -> unit
  val explicit_flush : unit -> unit
end

module Silent = struct
  let callback_restored ~active:_ = ()
  let explicit_flush () = ()
end

module type S = sig
  type database
  type slot
  val open_database : D.Config.t -> (database, D.error) result
  val connect : database -> (slot, D.error) result
  val close_slot : slot -> (unit, D.error) result
  val close_database : database -> (unit, D.error) result
  val execute : slot -> D.Bridge.request -> string -> (unit, D.error) result
  val transaction : slot -> D.Bridge.request -> f:(D.transaction -> ('a, D.error) result) -> ('a, D.error) result
  val query : slot -> D.Bridge.request -> string -> 'row D.Row.t -> ('row list, D.error) result
  val fold_rows : slot -> D.Bridge.request -> string -> 'row D.Row.t -> init:'a ->
    f:('row -> 'a -> ('a D.step, D.error) result) -> ('a, D.error) result
  val ingest : slot -> D.Bridge.request -> schema:string option -> table:string ->
    batches:D.cell list list list -> flush:bool -> (unit, D.error) result
  val parquet_fold_rows : slot -> D.Bridge.request -> string list -> 'row D.Row.t -> init:'a ->
    f:('row -> 'a -> ('a D.step, D.error) result) -> ('a, D.error) result
  val parquet_export : slot -> D.Bridge.request -> query:string -> destination:string -> (unit, D.error) result
  val is_in_callback : unit -> bool
end

module Make (Probe : Probe) = struct
  let ( let* ) x f = Result.bind x ~f
  type database = Database of D.database
  type slot = Slot of D.connection

  let active = Thread.TLS.new_key (fun () -> false)
  let is_in_callback () = Thread.TLS.get active
  let with_callback f =
    let previous = Thread.TLS.get active in
    Thread.TLS.set active true;
    Exn.protect ~f ~finally:(fun () ->
      Thread.TLS.set active previous;
      Probe.callback_restored ~active:(Thread.TLS.get active))
  (* Lifts a row callback so each invocation runs inside the callback marker. *)
  let in_callback f value accumulator = with_callback (fun () -> f value accumulator)

  let open_database config = Result.map (D.open_database config) ~f:(fun db -> Database db)
  let connect (Database db) = Result.map (D.connect db) ~f:(fun c -> Slot c)
  let close_slot (Slot c) = D.close_connection c
  let close_database (Database db) = D.close_database db

  (* Every slot operation is one bridged request; [work] sees only the facade. *)
  let bridged (Slot c) request work = D.Bridge.run request c ~f:work
  let fold_query c sql row ~init ~f =
    D.with_prepared c sql ~f:(fun prepared ->
      let* result = D.execute_prepared prepared in
      D.fold_rows result row ~init ~f)

  let execute slot request sql = bridged slot request (fun c -> D.execute c sql)
  let transaction slot request ~f =
    bridged slot request (fun c -> D.with_transaction c ~f:(fun tx -> with_callback (fun () -> f tx)))
  let query slot request sql row =
    bridged slot request (fun c ->
      fold_query c sql row ~init:[] ~f:(fun value values -> Ok (D.Continue (value :: values)))
      |> Result.map ~f:List.rev)
  let fold_rows slot request sql row ~init ~f =
    bridged slot request (fun c -> fold_query c sql row ~init ~f:(in_callback f))
  let ingest slot request ~schema ~table ~batches ~flush =
    let append appender = List.fold_result batches ~init:() ~f:(fun () batch -> D.append_rows appender batch) in
    bridged slot request (fun c ->
      D.with_transaction c ~f:(fun transaction ->
        D.with_appender_transaction transaction ?schema table ~f:(fun appender ->
          let* () = append appender in
          if flush then (Probe.explicit_flush (); D.flush_appender appender) else Ok ())))
  let parquet_fold_rows slot request names row ~init ~f =
    bridged slot request (fun c ->
      let* paths = Result.all (List.map names ~f:D.Parquet.path) in
      D.Parquet.fold_rows c paths row ~init ~f:(in_callback f))
  let parquet_export slot request ~query ~destination =
    bridged slot request (fun c ->
      let* path = D.Parquet.path destination in
      D.Parquet.export c ~query path)
end
