open! Base
open Resource

type ('columns, 'row) t = ('columns, 'row) Request.table
module Columns = Columns

let unimplemented () = failwith "Duckdb.Table: not implemented"
let declare ?(schema = "main") name columns ~row = Request.Table_def { schema; name; columns; row }
let select _ = unimplemented ()
let insert _ = unimplemented ()
type ('columns, 'row) appender = { table : ('columns, 'row) t; core : Appender.appender }
let with_appender (_ : connection) _ ~f:_ = unimplemented ()
let with_appender_transaction (_ : transaction) _ ~f:_ = unimplemented ()
let append (_ : (_, _) appender) _ = unimplemented ()
let flush (_ : (_, _) appender) = unimplemented ()
