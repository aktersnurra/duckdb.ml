open! Base
open Resource

type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]
type multiplicity = Exactly_zero | Exactly_one | At_most_one | Any_count
type 'params params = Params : ('params, _, _) Fields.t -> 'params params
type 'row rows = Rows : (_, 'fn, 'row) Fields.t * 'fn -> 'row rows
type ('params, 'row, 'multiplicity) t =
  { id : int; sql : string; oneshot : bool; multiplicity : multiplicity;
    params : 'params params; rows : 'row rows }
type ('columns, 'row) table =
  Table_def : { schema : string; name : string; columns : ('columns, 'fn, 'row) Columns.t; row : 'fn }
    -> ('columns, 'row) table

(* Cache identity: two requests never share a statement, even with equal SQL. *)
let next_id = Stdlib.Atomic.make 0
let make ?(oneshot = false) multiplicity params rows sql =
  { id = Stdlib.Atomic.fetch_and_add next_id 1; sql; oneshot; multiplicity; params = Params params; rows }
let exec ?oneshot params sql = make ?oneshot Exactly_zero params (Rows (Fields.[], ())) sql
let one ?oneshot params fields ~row sql = make ?oneshot Exactly_one params (Rows (fields, row)) sql
let zero_or_one ?oneshot params fields ~row sql = make ?oneshot At_most_one params (Rows (fields, row)) sql
let many ?oneshot params fields ~row sql = make ?oneshot Any_count params (Rows (fields, row)) sql
let query r = r.sql

type context = Query of string | Table of { schema : string; name : string }
type cause =
  | Core of error
  | Parameter_count of { expected : int; actual : int }
  | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
  | Unknown_column of { name : string }
  | Missing_column of { name : string }
  | Encode_rejected of { index : int; reason : Error.t }
  | Decode_rejected of { column : int; row : int; reason : Error.t }
  | Rollback_failed of { primary : request_error; rollback : error }
and request_error = { context : context; cause : cause }
let query_of_context = function
  | Query sql -> sql
  | Table { schema; name } -> schema ^ "." ^ name

module type QUERY = sig
  type owner
  type error
  type 'a future
  val exec : owner -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
  val find : owner -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
  val find_opt : owner -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
    ('row option, error) result future
  val collect : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    ('row list, error) result future
  val fold : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    init:'a -> f:('row -> 'a -> ('a Query.step, request_error) result) -> ('a, error) result future
end

module type CONNECTION = sig
  include QUERY
  val with_transaction : owner -> f:(transaction -> ('a, request_error) result) -> ('a, error) result future
  val ingest : owner -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
    (unit, error) result future
end

let unimplemented () = failwith "Duckdb.Request: not implemented"
module Connection = struct
  type owner = connection
  type error = request_error
  type 'a future = 'a
  let exec _ _ _ = unimplemented ()
  let find _ _ _ = unimplemented ()
  let find_opt _ _ _ = unimplemented ()
  let collect _ _ _ = unimplemented ()
  let fold _ _ _ ~init:_ ~f:_ = unimplemented ()
  let with_transaction _ ~f:_ = unimplemented ()
  let ingest _ _ _ ~flush:_ = unimplemented ()
end
module Transaction = struct
  type owner = transaction
  type error = request_error
  type 'a future = 'a
  let exec _ _ _ = unimplemented ()
  let find _ _ _ = unimplemented ()
  let find_opt _ _ _ = unimplemented ()
  let collect _ _ _ = unimplemented ()
  let fold _ _ _ ~init:_ ~f:_ = unimplemented ()
end
