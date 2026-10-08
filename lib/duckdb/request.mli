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
type ('columns, 'shape, 'row) table =
  Table_def : { schema : string; name : string; columns : ('columns, 'fn, 'row, 'shape) Columns.t; row : 'fn;
                constraints : Table_constraint.t list;
                select : (unit, 'row, many) t; insert : ('columns, unit, zero) t }
    -> ('columns, 'shape, 'row) table

val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, one) t
val zero_or_one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, zero_or_one) t
val many : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
  string -> ('params, 'row, many) t
val query : (_, _, _) t -> string

(* A request built by [Sql]; its multiplicity comes from the query's structure. *)
val generated : ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn -> string -> ('params, 'row, 'm) t

val declare_table : ?schema:string -> ?constraints:Table_constraint.t list -> string ->
  ('columns, 'fn, 'row, 'shape) Columns.t -> row:'fn -> ('columns, 'shape, 'row) table
val fields_of_columns : ('list, 'fn, 'result, _) Columns.t -> ('list, 'fn, 'result) Fields.t

(* Matches declared names to catalog [(name, has_default)] rows: the catalog
   position of each declared name, or [Unknown_column]/[Missing_column]. *)
val check_declaration : ?equal:(string -> string -> bool) -> string list -> (string * bool) list -> (int list, Failure.cause) Result.t

(* A double-quoted SQL identifier. *)
val quote : string -> string

type ('columns, 'row) appender
val with_appender_transaction : transaction -> ('columns, _, 'row) table ->
  f:(('columns, 'row) appender -> ('a, Failure.t) result) -> ('a, Failure.t) result
val append : ('columns, _) appender -> 'columns Args.t list -> (unit, Failure.t) result
val append_columns : ('columns, _) appender -> 'columns Bulk.Columns.t -> (unit, Failure.t) result
val flush : (_, _) appender -> (unit, Failure.t) result

module type QUERY = sig
  type _ owner
  type error
  type 'a future
  val exec : _ owner @ local -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
  val find : _ owner @ local -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
  val find_opt : _ owner @ local -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
    ('row option, error) result future
  val collect : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    ('row list, error) result future
  val fold : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
    init:'a -> f:('row -> 'a -> ('a Query.step, Failure.t) result) -> ('a, error) result future
end

module type CONNECTION = sig
  include QUERY
  val with_transaction : [ `Connection ] owner @ local ->
    f:([ `Transaction ] Session.t @ local -> ('a, Failure.t) result) -> ('a, error) result future
  val ingest : [ `Connection ] owner @ local -> ('columns, _, _) table -> 'columns Args.t list list -> flush:bool ->
    (unit, error) result future
end

(* What a run returns: [Exec] discards rows, [Find]/[Find_opt] admit one/at most one, [Collect] and [Fold] all. *)
type ('row, 'out) shape =
  | Exec : (unit, unit) shape
  | Find : ('row, 'row) shape
  | Find_opt : ('row, 'row option) shape
  | Collect : ('row, 'row list) shape
  | Fold : { init : 'a; f : 'row -> 'a -> ('a Query.step, Failure.t) result } -> ('row, 'a) shape

(* Runs a parameterless request on a connection, as [Session.fold], with
   its errors in [context]. *)
val fold_on : context:Failure.context -> connection -> (unit, 'row, _) t -> init:'a -> f:('row -> 'a -> ('a Query.step, Failure.t) result) ->
  ('a, Failure.t) result

(* A transaction owned by the calling scope; errors pass through flat. *)
val with_owned_transaction : connection -> f:(transaction -> ('a, Failure.t) result) -> ('a, Failure.t) result

(* One operation set over both session kinds. [run] is the one execution entry
   point per shape, used by the adapters through [Duckdb.Owned]; the named
   operations carry the row-count guards ([run] accepts any multiplicity). *)
module Session : sig
  include CONNECTION
    with type 'k owner = 'k Session.t and type error = Failure.t and type 'a future = 'a
  val run : _ Session.t @ local -> ('row, 'out) shape -> ('params, 'row, _) t -> 'params Args.t ->
    ('out, Failure.t) result
end
