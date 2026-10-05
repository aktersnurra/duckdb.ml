(** Synchronous owner capsule shared by the scheduler adapters. Each adapter
    applies [Make] once and runs these operations only on its reserved
    workers, never on its scheduler. No owner getter is exposed. *)

(** Observation points, injected so tests can watch the capsule without
    patching it. Production adapters use [Silent]. *)
module type Probe = sig

  (** After a user callback, once the callback marker has been restored;
      [active] is the restored marker. *)
  val callback_restored : active:bool -> unit

  (** Immediately before an adapter-requested explicit appender flush. *)
  val explicit_flush : unit -> unit
end

module Silent : Probe

module type S = sig
  type database
  type slot
  val open_database : Duckdb.Config.t -> (database, Duckdb.Error.t) result
  val connect : database -> (slot, Duckdb.Error.t) result
  val close_slot : slot -> (unit, Duckdb.Error.t) result
  val close_database : database -> (unit, Duckdb.Error.t) result
  val execute : slot -> Duckdb.Bridge.request -> string -> (unit, Duckdb.Error.t) result
  val transaction : slot -> Duckdb.Bridge.request -> f:(Duckdb.transaction -> ('a, Duckdb.Error.t) result) -> ('a, Duckdb.Error.t) result
  val query : slot -> Duckdb.Bridge.request -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> ('row list, Duckdb.Error.t) result
  val fold_rows : slot -> Duckdb.Bridge.request -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a Duckdb.step, Duckdb.Error.t) result) -> ('a, Duckdb.Error.t) result
  val parquet_fold_rows : slot -> Duckdb.Bridge.request -> string list -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a Duckdb.step, Duckdb.Error.t) result) -> ('a, Duckdb.Error.t) result
  val parquet_export : slot -> Duckdb.Bridge.request -> query:string -> destination:string -> (unit, Duckdb.Error.t) result

  (** Typed requests (each one bridged request). Bridge failures are reported
      in the request's context; row callbacks run inside the callback marker. *)
  val request_run : slot -> Duckdb.Bridge.request -> ('row, 'out) Duckdb.Owned.shape ->
    ('p, 'row, _) Duckdb.Request.t -> 'p Duckdb.Args.t -> ('out, Duckdb.Error.t) result
  val request_transaction : slot -> Duckdb.Bridge.request ->
    f:(Duckdb.transaction -> ('a, Duckdb.Error.t) result) -> ('a, Duckdb.Error.t) result
  val table_ingest : slot -> Duckdb.Bridge.request -> ('c, _) Duckdb.Table.t -> 'c Duckdb.Args.t list list -> flush:bool ->
    (unit, Duckdb.Error.t) result

  (** Thread-local callback marker; reading it never touches a scheduler. *)
  val is_in_callback : unit -> bool
end

module Make (_ : Probe) : S
