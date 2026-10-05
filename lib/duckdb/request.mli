open! Base
open Resource

type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]

type 'params params = Params : ('params, _, _) Fields.t -> 'params params
type 'row rows = Rows : (_, 'fn, 'row) Fields.t * 'fn -> 'row rows | No_rows : unit rows
type ('params, 'row, 'multiplicity) t =
  { id : int; sql : string; oneshot : bool; params : 'params params; rows : 'row rows }
(* A declared table; its SELECT and INSERT are built once so that they share
   statement-cache entries. *)
type ('columns, 'row) table =
  Table_def : { schema : string; name : string; columns : ('columns, 'fn, 'row) Columns.t; row : 'fn;
                select : (unit, 'row, many) t; insert : ('columns, unit, zero) t }
    -> ('columns, 'row) table

val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, one) t
val zero_or_one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, zero_or_one) t
val many : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, many) t
val query : (_, _, _) t -> string

type context = Query of string | Table of { schema : string; name : string } | Transaction
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
exception Cleanup_exception of request_error * exn

val declare_table : ?schema:string -> string -> ('columns, 'fn, 'row) Columns.t -> row:'fn -> ('columns, 'row) table
val fields_of_columns : ('list, 'fn, 'result) Columns.t -> ('list, 'fn, 'result) Fields.t

type ('columns, 'row) appender
val with_appender_transaction : transaction -> ('columns, 'row) table ->
  f:(('columns, 'row) appender -> ('a, request_error) result) -> ('a, request_error) result
val append : ('columns, _) appender -> 'columns Args.t list -> (unit, request_error) result
val flush : (_, _) appender -> (unit, request_error) result

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

(* What a run returns: [Exec] discards rows, [Find]/[Find_opt] admit one/at most one, [Collect] and [Fold] all. *)
type ('row, 'out) shape =
  | Exec : (unit, unit) shape
  | Find : ('row, 'row) shape
  | Find_opt : ('row, 'row option) shape
  | Collect : ('row, 'row list) shape
  | Fold : { init : 'a; f : 'row -> 'a -> ('a Query.step, request_error) result } -> ('row, 'a) shape

(* The one execution entry point per shape, used by the adapters; prefer the named operations of [Connection], which
   carry the row-count guards ([run] accepts any multiplicity with [Find], [Find_opt], [Collect] and [Fold]). *)
val run : connection -> ('row, 'out) shape -> ('params, 'row, _) t -> 'params Args.t -> ('out, request_error) result

(* Runs a parameterless request on a connection, as [Connection.fold]. *)
val fold_on : connection -> (unit, 'row, _) t -> init:'a -> f:('row -> 'a -> ('a Query.step, request_error) result) ->
  ('a, request_error) result

module Connection : CONNECTION
  with type owner = connection and type error = request_error and type 'a future = 'a
module Transaction : QUERY
  with type owner = transaction and type error = request_error and type 'a future = 'a
