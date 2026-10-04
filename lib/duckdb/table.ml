open! Base

type ('columns, 'row) t = ('columns, 'row) Request.table
module Columns = Columns

let declare = Request.declare_table
let select (Request.Table_def t : (_, _) t) = t.select
let insert (Request.Table_def t : (_, _) t) = t.insert
type ('columns, 'row) appender = ('columns, 'row) Request.appender
let with_appender c table ~f = Request.Connection.with_transaction c ~f:(fun tx -> Request.with_appender_transaction tx table ~f)
let with_appender_transaction = Request.with_appender_transaction
let append = Request.append
let flush = Request.flush
