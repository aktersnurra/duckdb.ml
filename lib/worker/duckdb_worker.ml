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

  (** Typed requests (each one bridged request). Bridge failures are reported
      as [Core] request errors; row callbacks run inside the callback marker. *)
  val request_exec : slot -> D.Bridge.request -> ('p, unit, [< `Zero ]) D.Request.t -> 'p D.Args.t ->
    (unit, D.Request.request_error) result
  val request_find : slot -> D.Bridge.request -> ('p, 'row, [< `One ]) D.Request.t -> 'p D.Args.t ->
    ('row, D.Request.request_error) result
  val request_find_opt : slot -> D.Bridge.request -> ('p, 'row, [< `Zero | `One ]) D.Request.t -> 'p D.Args.t ->
    ('row option, D.Request.request_error) result
  val request_collect : slot -> D.Bridge.request -> ('p, 'row, [< `Zero | `One | `Many ]) D.Request.t ->
    'p D.Args.t -> ('row list, D.Request.request_error) result
  val request_fold : slot -> D.Bridge.request -> ('p, 'row, [< `Zero | `One | `Many ]) D.Request.t ->
    'p D.Args.t -> init:'a -> f:('row -> 'a -> ('a D.step, D.Request.request_error) result) ->
    ('a, D.Request.request_error) result
  val request_transaction : slot -> D.Bridge.request ->
    f:(D.transaction -> ('a, D.Request.request_error) result) -> ('a, D.Request.request_error) result
  val table_ingest : slot -> D.Bridge.request -> ('c, _) D.Table.t -> 'c D.Args.t list list -> flush:bool ->
    (unit, D.Request.request_error) result
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

  module R = D.Request
  let typed slot request ~context work =
    match bridged slot request (fun c -> Ok (work c)) with
    | Ok result -> result
    | Error error -> Error { R.context; cause = R.Core error }
  let in_query r = R.Query (R.query r)
  let request_exec slot request r args = typed slot request ~context:(in_query r) (fun c -> R.Connection.exec c r args)
  let request_find slot request r args = typed slot request ~context:(in_query r) (fun c -> R.Connection.find c r args)
  let request_find_opt slot request r args =
    typed slot request ~context:(in_query r) (fun c -> R.Connection.find_opt c r args)
  let request_collect slot request r args =
    typed slot request ~context:(in_query r) (fun c -> R.Connection.collect c r args)
  let request_fold slot request r args ~init ~f =
    typed slot request ~context:(in_query r) (fun c -> R.Connection.fold c r args ~init ~f:(in_callback f))
  let request_transaction slot request ~f =
    typed slot request ~context:R.Transaction (fun c ->
      R.Connection.with_transaction c ~f:(fun tx -> with_callback (fun () -> f tx)))
  let table_ingest slot request table batches ~flush =
    typed slot request ~context:R.Transaction (fun c ->
      R.Connection.with_transaction c ~f:(fun tx -> D.Table.with_appender_transaction tx table ~f:(fun appender ->
        let* () = List.fold_result batches ~init:() ~f:(fun () batch -> D.Table.append appender batch) in
        if flush then (Probe.explicit_flush (); D.Table.flush appender) else Ok ())))
end
