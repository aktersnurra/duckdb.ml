open! Base
open Resource

type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]

(* Runtime multiplicity: the phantom bounds which operations accept a request;
   this tag tells execution how many rows to admit. *)
type multiplicity = Exactly_zero | Exactly_one | At_most_one | Any_count
type 'params params = Params : ('params, _, _) Fields.t -> 'params params
type 'row rows = Rows : (_, 'fn, 'row) Fields.t * 'fn -> 'row rows
type ('params, 'row, 'multiplicity) t =
  { id : int; sql : string; oneshot : bool; multiplicity : multiplicity;
    params : 'params params; rows : 'row rows }
type ('columns, 'row) table =
  Table_def : { schema : string; name : string; columns : ('columns, 'fn, 'row) Columns.t; row : 'fn }
    -> ('columns, 'row) table

val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, one) t
val zero_or_one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, zero_or_one) t
val many : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, many) t
val query : (_, _, _) t -> string

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
val query_of_context : context -> string

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

module Connection : CONNECTION
  with type owner = connection and type error = request_error and type 'a future = 'a
module Transaction : QUERY
  with type owner = transaction and type error = request_error and type 'a future = 'a
