open! Base

type ('columns, 'row) t = ('columns, 'row) Request.table
module Columns = Columns

let declare = Request.declare_table
let select (Request.Table_def t : (_, _) t) = t.select
let insert (Request.Table_def t : (_, _) t) = t.insert
(* The payload is global so that a facade function receiving a local appender
   can still pass the internal one to the global internals. *)
type ('columns, 'row) appender = { appender : ('columns, 'row) Request.appender @@ global }
(* A connection owns the appender's transaction; a transaction lends its own. *)
let with_appender (type k) (s : k Session.t) table ~f =
  let f appender = f { appender } in
  match s with
  | Session.Connection c -> Request.with_owned_transaction c ~f:(fun tx -> Request.with_appender_transaction tx table ~f)
  | Session.Transaction tx -> Request.with_appender_transaction tx table ~f
let append { appender } rows = Request.append appender rows
let flush { appender } = Request.flush appender
