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

module Bulk = struct
  include Bulk
  module A1 = Bigarray.Array1
  module C = Statement.Column
  (* Grows by doubling; the result is a [sub] of the final buffer (shared, no copy). *)
  let grow make a ~used ~need =
    if A1.dim a >= need then a
    else let b = make (Int.max need (2 * A1.dim a)) in
      A1.blit (A1.sub a 0 used) (A1.sub b 0 used); b
  let absolute ~used (e : Error.t) = match e.cause with
    | Null { column; row } -> { e with cause = Null { column; row = used + row } }
    | _ -> e
  (* Checks the column against the result's types before any chunk, so an
     empty result (whose chunks are never folded) is checked too. The views
     repeat the check per chunk. *)
  let check_column ~column scalar types =
    let length = Array.length types in
    if column < 0 || column >= length then Error (Error.Index { index = column; length })
    else if types.(column) <> Scalar.native_id scalar then
      Error (Error.Type_mismatch { index = column; expected = Scalar.name scalar;
                                   actual = Error.type_name types.(column) })
    else Ok ()
  let fold_column ({ Statement.prepared = q } @ local) ~column scalar ~init ~f =
    Q.fold_prepared_validated ~lifting:(Flat (Query (Q.sql q))) q ~validate:(check_column ~column scalar) ~init ~f
  let collect (type a k e n) (p : Statement.prepared @ local) ~column (kind : (a, k, e) kind)
      (nulls : n C.nulls) : ((k, e, n) t, Error.t) result =
    let make n = A1.create (bigarray_kind kind) Bigarray.c_layout n in
    let make_mask n = A1.create Bigarray.int8_unsigned Bigarray.c_layout n in
    let initial = 2048 in
    let mask_initial = match nulls with C.Non_null -> 0 | C.Nullable -> initial in
    let folded = fold_column p ~column (scalar kind) ~init:(make initial, make_mask mask_initial, 0)
      ~f:(fun chunk (data, mask, used) ->
        match C.view chunk column (scalar kind) nulls with
        | C.Rejected e -> Error (absolute ~used e)
        | C.Opened v ->
          let n = C.length v in
          let data = grow make data ~used ~need:(used + n) in
          blit v kind ~into:data ~pos:used;
          let mask = match nulls with
            | C.Non_null -> mask
            | C.Nullable -> let mask = grow make_mask mask ~used ~need:(used + n) in
              blit_validity v ~into:mask ~pos:used; mask in
          Ok (Continue (data, mask, used + n))) in
    Stdlib.Result.map (fun (data, mask, used) ->
      let validity : n validity = match nulls with
        | C.Non_null -> All_valid
        | C.Nullable -> Mask (A1.sub mask 0 used) in
      { data = A1.sub data 0 used; validity }) folded
  (* One array per chunk, filled by [fill] from the chunk's view. *)
  let fold_strings (type m b) (p : Statement.prepared @ local) ~column scalar (nulls : m C.nulls)
      ~(empty : b) ~(fill : (string, m) C.t @ local -> b array -> unit) : (b array, Error.t) result =
    let folded = fold_column p ~column scalar ~init:([], 0) ~f:(fun chunk (parts, used) ->
      match C.view chunk column scalar nulls with
      | C.Rejected e -> Error (absolute ~used e)
      | C.Opened v ->
        let values = Array.make (C.length v) empty in
        fill v values;
        Ok (Continue (values :: parts, used + Array.length values))) in
    Stdlib.Result.map (fun (parts, _) -> Array.concat (List.rev parts)) folded
  let collect_strings (type n) (p : Statement.prepared @ local) ~column scalar (nulls : n C.nulls)
      : (n strings, Error.t) result =
    match nulls with
    | C.Non_null ->
      Stdlib.Result.map (fun all : n strings -> Strings all)
        (fold_strings p ~column scalar nulls ~empty:"" ~fill:(fun v values ->
          for i = 0 to Array.length values - 1 do values.(i) <- C.string v i done))
    | C.Nullable ->
      Stdlib.Result.map (fun all : n strings -> Strings_opt all)
        (fold_strings p ~column scalar nulls ~empty:None ~fill:(fun v values ->
          for i = 0 to Array.length values - 1 do values.(i) <- C.string_opt v i done))
end

module Fields = Fields
module Args = Args
module Request = Request
module Table = Table
module Sql = Sql
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
