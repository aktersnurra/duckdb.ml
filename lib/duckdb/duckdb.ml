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
type database = R.database
type connection = R.connection
type transaction = R.transaction
module Bridge = struct
  include R.Bridge
  let cancel request = within Connection (cancel request)
end
let open_database config = within Database (R.open_database config)
let close_database db = within Database (R.close_database db)
let connect db = within Connection (R.connect db)
let close_connection c = within Connection (R.close_connection c)
let execute c sql = within (Query sql) (R.execute c sql)
let execute_transaction tx sql = within (Query sql) (R.execute_transaction tx sql)
let with_database = R.with_database
let with_connection = R.with_connection
let with_transaction = Request.Connection.with_transaction

type prepared = Q.prepared
type query_result = Q.query_result
type chunk = Q.chunk
type 'a step = 'a Q.step = Continue of 'a | Stop of 'a
let in_statement p result = within (Query (Q.sql p)) result
let prepare c sql = within (Query sql) (Q.prepare c sql)
let prepare_transaction tx sql = within (Query sql) (Q.prepare_transaction tx sql)
let close_prepared p = in_statement p (Q.close_prepared p)
let parameter_count p = in_statement p (Q.parameter_count p)
let bind p index codec value = in_statement p (Q.bind p index codec value)
let reset p = in_statement p (Q.reset p)
let execute_prepared p = in_statement p (Q.execute_prepared p)
let close_result r = within (Query (Q.result_sql r)) (Q.close_result r)
let with_prepared c sql ~f = Q.with_prepared ~lifting:(Flat (Query sql)) c sql ~f
let with_prepared_transaction tx sql ~f = Q.with_prepared_transaction ~lifting:(Flat (Query sql)) tx sql ~f
let fold_chunks r ~init ~f = Q.fold_chunks ~lifting:(Flat (Query (Q.result_sql r))) r ~init ~f
let chunk_length = Q.chunk_length
let column (chunk @ local) ~column ~row codec =
  within (Query (Q.chunk_sql chunk)) (Q.column chunk ~column ~row codec)

module Fields = Fields
module Args = Args
module Request = Request
module Table = Table
module Parquet = Parquet
