module Scalar = Scalar
module Codec = Codec
module Error = Failure
exception Cleanup_exception = Failure.Cleanup_exception
module R = Resource
module Q = Query
let within = Failure.within

module Config = struct
  include R.Config
  let create ?threads ?memory_limit_bytes ?statement_cache ?access storage =
    within Database (create ?threads ?memory_limit_bytes ?statement_cache ?access storage)
end
type database = Session.database
type 'k session = 'k Session.t
type connection = [ `Connection ] session
type transaction = [ `Transaction ] session
module Bridge = struct
  type canceller = R.Bridge.canceller
  (* A fresh record per request carries the uniqueness; the payload is aliased
     so that consuming the record does not consume the canceller's state (P1). *)
  type request = { cell : R.Bridge.handle @@ aliased }
  type settlement = R.Bridge.settlement = Pending | Settled
  let canceller = R.Bridge.canceller
  let request k : request @ unique = { cell = R.Bridge.request k }
  let cancel = R.Bridge.cancel
  let settlement = R.Bridge.settlement
  let run (r @ unique) (Session.Connection c : connection @ local) ~f =
    R.Bridge.run r.cell c ~f:(fun facade -> f (Session.Connection facade))
end
let execute (s @ local) sql = within (Query sql) (match Session.within s with
  | None -> R.execute (Session.connection s) sql
  | Some tx -> R.execute_transaction tx sql)
let with_database config ~f = R.with_database config ~f:(fun database -> f { Session.database })
let with_connection (db : database @ local) ~f =
  R.with_connection db.database ~f:(fun c -> f (Session.Connection c))
let with_transaction = Request.Session.with_transaction

type 'a step = 'a Q.step = Continue of 'a | Stop of 'a
module Statement = struct
  (* The payload is global so that a facade function receiving a local
     statement can still pass the internal one to the global internals
     (execution records it as the result's owner). *)
  type prepared = { prepared : Q.prepared @@ global }
  type chunk = Q.chunk
  let in_statement p result = within (Query (Q.sql p)) result
  let with_prepared (s @ local) sql ~f =
    let f prepared = f { prepared } in
    match Session.within s with
    | None -> Q.with_prepared ~lifting:(Flat (Query sql)) (Session.connection s) sql ~f
    | Some tx -> Q.with_prepared_transaction ~lifting:(Flat (Query sql)) tx sql ~f
  let parameter_count ({ prepared = p } @ local) = in_statement p (Q.parameter_count p)
  let bind ({ prepared = p } @ local) index codec value = in_statement p (Q.bind p index codec value)
  let reset ({ prepared = p } @ local) = in_statement p (Q.reset p)
  let fold_chunks ({ prepared = p } @ local) ~init ~f = Q.fold_prepared ~lifting:(Flat (Query (Q.sql p))) p ~init ~f
  let execute (p @ local) = fold_chunks p ~init:() ~f:(fun _ () -> Ok (Continue ()))
  let chunk_length = Q.chunk_length
  let column (chunk @ local) ~column ~row codec =
    within (Query (Q.chunk_sql chunk)) (Q.column chunk ~column ~row codec)
  module Column = Column
end

module Fields = Fields
module Args = Args
module Request = Request
module Table = Table
module Parquet = Parquet

module Owned = struct
  let open_database config =
    within Database (Result.map (fun database -> { Session.database }) (R.open_database config))
  let close_database (db : database) = within Database (R.close_database db.database)
  let connect (db : database) =
    within Connection (Result.map (fun c -> Session.Connection c) (R.connect db.database))
  let close_connection (Session.Connection c : connection) = within Connection (R.close_connection c)
  type ('row, 'out) shape = ('row, 'out) Request.shape =
    | Exec : (unit, unit) shape
    | Find : ('row, 'row) shape
    | Find_opt : ('row, 'row option) shape
    | Collect : ('row, 'row list) shape
    | Fold : { init : 'a; f : 'row -> 'a -> ('a step, Error.t) result } -> ('row, 'a) shape
  let run = Request.Session.run
end
