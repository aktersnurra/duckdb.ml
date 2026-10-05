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
  val open_database : Duckdb.Config.t -> (database, Duckdb.error) result
  val connect : database -> (slot, Duckdb.error) result
  val close_slot : slot -> (unit, Duckdb.error) result
  val close_database : database -> (unit, Duckdb.error) result
  val execute : slot -> Duckdb.Bridge.request -> string -> (unit, Duckdb.error) result
  val transaction : slot -> Duckdb.Bridge.request -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a, Duckdb.error) result
  val query : slot -> Duckdb.Bridge.request -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> ('row list, Duckdb.error) result
  val fold_rows : slot -> Duckdb.Bridge.request -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, Duckdb.error) result
  val ingest : slot -> Duckdb.Bridge.request -> schema:string option -> table:string ->
    batches:Duckdb.cell list list list -> flush:bool -> (unit, Duckdb.error) result
  val parquet_fold_rows : slot -> Duckdb.Bridge.request -> string list -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, Duckdb.error) result
  val parquet_export : slot -> Duckdb.Bridge.request -> query:string -> destination:string -> (unit, Duckdb.error) result

  (** Typed requests (each one bridged request). Bridge failures are reported
      as [Core] request errors; row callbacks run inside the callback marker. *)
  val request_exec : slot -> Duckdb.Bridge.request -> ('p, unit, [< `Zero ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    (unit, Duckdb.Request.request_error) result
  val request_find : slot -> Duckdb.Bridge.request -> ('p, 'row, [< `One ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    ('row, Duckdb.Request.request_error) result
  val request_find_opt : slot -> Duckdb.Bridge.request -> ('p, 'row, [< `Zero | `One ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    ('row option, Duckdb.Request.request_error) result
  val request_collect : slot -> Duckdb.Bridge.request -> ('p, 'row, [< `Zero | `One | `Many ]) Duckdb.Request.t ->
    'p Duckdb.Args.t -> ('row list, Duckdb.Request.request_error) result
  val request_fold : slot -> Duckdb.Bridge.request -> ('p, 'row, [< `Zero | `One | `Many ]) Duckdb.Request.t ->
    'p Duckdb.Args.t -> init:'a -> f:('row -> 'a -> ('a Duckdb.step, Duckdb.Request.request_error) result) ->
    ('a, Duckdb.Request.request_error) result
  val request_transaction : slot -> Duckdb.Bridge.request ->
    f:(Duckdb.transaction -> ('a, Duckdb.Request.request_error) result) -> ('a, Duckdb.Request.request_error) result
  val table_ingest : slot -> Duckdb.Bridge.request -> ('c, _) Duckdb.Table.t -> 'c Duckdb.Args.t list list -> flush:bool ->
    (unit, Duckdb.Request.request_error) result

  (** Thread-local callback marker; reading it never touches a scheduler. *)
  val is_in_callback : unit -> bool
end

module Make (_ : Probe) : S
