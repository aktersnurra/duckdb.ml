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
  val open_database : D.Config.t -> (database, D.Error.t) result
  val connect : database -> (slot, D.Error.t) result
  val close_slot : slot -> (unit, D.Error.t) result
  val close_database : database -> (unit, D.Error.t) result
  val execute : slot -> D.Bridge.request -> string -> (unit, D.Error.t) result
  val transaction : slot -> D.Bridge.request -> f:(D.transaction @ local -> ('a, D.Error.t) result) -> ('a, D.Error.t) result
  val query : slot -> D.Bridge.request -> string -> (_, 'fn, 'row) D.Fields.t -> row:'fn -> ('row list, D.Error.t) result
  val fold_rows : slot -> D.Bridge.request -> string -> (_, 'fn, 'row) D.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a D.step, D.Error.t) result) -> ('a, D.Error.t) result
  val parquet_fold_rows : slot -> D.Bridge.request -> string list -> (_, 'fn, 'row) D.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a D.step, D.Error.t) result) -> ('a, D.Error.t) result
  val parquet_export : slot -> D.Bridge.request -> query:string -> destination:string -> (unit, D.Error.t) result

  (** Typed requests (each one bridged request). Bridge failures are reported
      in the request's context; row callbacks run inside the callback marker. *)
  val request_run : slot -> D.Bridge.request -> ('row, 'out) D.Owned.shape -> ('p, 'row, _) D.Request.t ->
    'p D.Args.t -> ('out, D.Error.t) result
  val request_transaction : slot -> D.Bridge.request ->
    f:(D.transaction @ local -> ('a, D.Error.t) result) -> ('a, D.Error.t) result
  val table_ingest : slot -> D.Bridge.request -> ('c, _) D.Table.t -> 'c D.Args.t list list -> flush:bool ->
    (unit, D.Error.t) result
  val is_in_callback : unit -> bool
end

module Make (Probe : Probe) = struct
  type database = Database of D.database
  type slot = Slot of D.connection

  let active = Thread.TLS.new_key (fun () -> false)
  let is_in_callback () = Thread.TLS.get active
  let with_callback (f @ local) =
    let previous = Thread.TLS.get active in
    Thread.TLS.set active true;
    Exn.protect ~f ~finally:(fun () ->
      Thread.TLS.set active previous;
      Probe.callback_restored ~active:(Thread.TLS.get active))
  (* Lifts a row callback so each invocation runs inside the callback marker. *)
  let in_callback f value accumulator = with_callback (fun () -> f value accumulator)

  let open_database config = Result.map (D.Owned.open_database config) ~f:(fun db -> Database db)
  let connect (Database db) = Result.map (D.Owned.connect db) ~f:(fun c -> Slot c)
  let close_slot (Slot c) = D.Owned.close_connection c
  let close_database (Database db) = D.Owned.close_database db

  (* Every slot operation is one bridged request; [work] sees only the facade. *)
  let bridged (Slot c) request work = D.Bridge.run request c ~f:work
  let raw sql fields ~row = D.Request.many ~oneshot:true D.Fields.[] fields ~row sql

  let execute slot request sql = bridged slot request (fun c -> D.execute c sql)
  let transaction slot request ~f =
    bridged slot request (fun c -> D.with_transaction c ~f:(fun tx -> with_callback (fun () -> f tx) [@nontail]))
  let query slot request sql fields ~row =
    bridged slot request (fun c -> D.Request.Session.collect c (raw sql fields ~row) D.Args.[])
  let fold_rows slot request sql fields ~row ~init ~f =
    bridged slot request (fun c -> D.Request.Session.fold c (raw sql fields ~row) D.Args.[] ~init ~f:(in_callback f))
  let parquet_fold_rows slot request names fields ~row ~init ~f =
    bridged slot request (fun c ->
      (* Binding-operator continuations are global; [c] is local. *)
      match Result.all (List.map names ~f:D.Parquet.path) with
      | Error _ as error -> error
      | Ok paths -> D.Parquet.fold c paths fields ~row ~init ~f:(in_callback f))
  let parquet_export slot request ~query ~destination =
    bridged slot request (fun c ->
      match D.Parquet.path destination with
      | Error _ as error -> error
      | Ok path -> D.Parquet.export c ~query path)

  module R = D.Request
  let typed slot request ~context work =
    match bridged slot request (fun c -> Ok (work c)) with
    | Ok result -> result
    | Error error -> Error { error with D.Error.context }
  let in_query r = D.Error.Query (R.query r)
  let marked : type row out. (row, out) D.Owned.shape -> (row, out) D.Owned.shape = function
    | D.Owned.Fold { init; f } -> D.Owned.Fold { init; f = in_callback f }
    | D.Owned.Exec -> D.Owned.Exec
    | D.Owned.Find -> D.Owned.Find
    | D.Owned.Find_opt -> D.Owned.Find_opt
    | D.Owned.Collect -> D.Owned.Collect
  let request_run slot request shape r args =
    typed slot request ~context:(in_query r) (fun c -> D.Owned.run c (marked shape) r args)
  let request_transaction slot request ~f =
    typed slot request ~context:D.Error.Transaction (fun c ->
      R.Session.with_transaction c ~f:(fun tx -> with_callback (fun () -> f tx) [@nontail]))
  let table_ingest slot request table batches ~flush =
    typed slot request ~context:D.Error.Transaction (fun c ->
      R.Session.with_transaction c ~f:(fun tx -> D.Table.with_appender tx table ~f:(fun appender ->
        match List.fold_result batches ~init:() ~f:(fun () batch -> D.Table.append appender batch) with
        | Error _ as error -> error
        | Ok () -> if flush then (Probe.explicit_flush (); D.Table.flush appender) else Ok ())))
end
