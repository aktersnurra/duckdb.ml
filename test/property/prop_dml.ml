(* Write statements and window functions against models. *)
open! Base
open Prop_support
module T = D.Table
module S = D.Sql

(* DML: a random sequence of statements on a keyed table, mirrored on a map
   from id to (name, hits). Each statement's count or RETURNING rows, and the
   table afterwards, match the model. *)
let kv = T.(declare "kv" Columns.["id", int64; "name", string; "hits", int64]
  ~row:(fun id name hits -> (id, name, hits))
  ~constraints:(fun [id; _; hits] -> Constraint.[ primary_key Key.[id]; default hits (S.int64 0L) ]))
let () = ok (T.create (Lazy.force connection) kv)

let insert = S.(command Params.[int64; string] (fun [id; name] ->
  insert kv (fun [kid; kname; _] -> values [kid := param id; kname := param name] ~on_conflict:(nothing_on Keys.[kid]))))
let upsert = S.(command Params.[int64; string] (fun [id; name] ->
  insert kv (fun [kid; kname; khits] ->
    values [kid := param id; kname := param name]
      ~on_conflict:(update_on Keys.[kid] (fun [_; proposed; _] -> [kname := proposed; khits := I64.(khits + int64 1L)])))))
let rename = S.(command Params.[int64; string] (fun [id; name] ->
  update kv (fun [kid; kname; _] -> set [kname := param name] ~where:(kid = param id))))
let bump_all = S.(command Params.[] (fun [] -> update kv (fun [_; _; khits] -> set [khits := I64.(khits + int64 1L)])))
let remove = S.(command Params.[int64] (fun [id] ->
  delete kv (fun [kid; kname; _] -> filter (kid = param id) |> returning Exprs.[kname] ~row:Fn.id)))
let clear = S.(command Params.[] (fun [] -> delete kv (fun [_; _; _] -> all)))

type op = Insert of int64 * string | Upsert of int64 * string | Rename of int64 * string | Bump_all | Remove of int64 | Clear
let show = function
  | Insert (id, n) -> Printf.sprintf "insert %Ld %s" id n | Upsert (id, n) -> Printf.sprintf "upsert %Ld %s" id n
  | Rename (id, n) -> Printf.sprintf "rename %Ld %s" id n | Bump_all -> "bump all"
  | Remove id -> Printf.sprintf "remove %Ld" id | Clear -> "clear"
let draw_op tc =
  let id () = Int64.of_int (Hegel.draw ~label:"id" tc (Hegel.integers ~min_value:0 ~max_value:4 ())) in
  let name () = Hegel.draw ~label:"name" tc (Hegel.text ~alphabet:"abc" ~min_size:1 ~max_size:2 ()) in
  match Hegel.draw ~label:"op" tc (Hegel.integers ~min_value:0 ~max_value:5 ()) with
  | 0 -> let id = id () in Insert (id, name ())
  | 1 -> let id = id () in Upsert (id, name ())
  | 2 -> let id = id () in Rename (id, name ())
  | 3 -> Bump_all
  | 4 -> Remove (id ())
  | _ -> Clear

let () =
  let c = Lazy.force connection in
  let model_rows model = Map.to_alist model |> List.map ~f:(fun (id, (name, hits)) -> (id, name, hits)) in
  let rows () = List.sort ~compare:Poly.compare (ok (R.Session.collect c (T.select kv) D.Args.[])) in
  property "statement sequences match a map model" (fun tc ->
    exec "DELETE FROM kv";
    let ops = List.init (Hegel.draw ~label:"steps" tc (Hegel.integers ~min_value:0 ~max_value:10 ())) ~f:(fun _ -> draw_op tc) in
    Hegel.note tc (String.concat ~sep:"; " (List.map ops ~f:show));
    let step model op =
      let count expected request args =
        let actual = ok (R.Session.find c request args) in
        if not (Int64.equal actual (Int64.of_int expected)) then
          failwith (Printf.sprintf "%s: count %Ld, model %d" (show op) actual expected) in
      match op with
      | Insert (id, name) ->
        count (if Map.mem model id then 0 else 1) insert D.Args.[id; name];
        if Map.mem model id then model else Map.set model ~key:id ~data:(name, 0L)
      | Upsert (id, name) ->
        count 1 upsert D.Args.[id; name];
        Map.update model id ~f:(function None -> (name, 0L) | Some (_, hits) -> (name, Int64.succ hits))
      | Rename (id, name) ->
        count (if Map.mem model id then 1 else 0) rename D.Args.[id; name];
        Map.change model id ~f:(Option.map ~f:(fun (_, hits) -> (name, hits)))
      | Bump_all ->
        count (Map.length model) bump_all D.Args.[];
        Map.map model ~f:(fun (name, hits) -> (name, Int64.succ hits))
      | Remove id ->
        let returned = ok (R.Session.collect c remove D.Args.[id]) in
        if not (List.equal String.equal returned (Option.to_list (Option.map (Map.find model id) ~f:fst))) then
          failwith (show op ^ ": returning differs");
        Map.remove model id
      | Clear ->
        count (Map.length model) clear D.Args.[];
        Map.empty (module Int64) in
    let model = List.fold ops ~init:(Map.empty (module Int64)) ~f:step in
    if not (List.equal Poly.equal (rows ()) (model_rows model)) then failwith "the table differs from the model")

(* Windows: ranking, offsets and a running sum per partition, against a
   reference computed from the sorted partition. The query is built once and
   its cached statement reused across cases and data: this is what found
   DuckDB's stale-statistics bug (see test_request.ml). *)
type cell = { id : int64; k : int64; v : int64 }
let cells = T.(declare "wcells" Columns.["id", int64; "k", int64; "v", int64] ~row:(fun id k v -> { id; k; v }))
let () = exec "CREATE TABLE wcells(id BIGINT NOT NULL, k BIGINT NOT NULL, v BIGINT NOT NULL)"
let windowed = S.(query Params.[] (fun [] -> from cells (fun [id; k; v] ->
  let by_v = window ~partition_by:[part k] ~order_by:[asc v] () in
  let by_row = window ~partition_by:[part k] ~order_by:[asc v; asc id] () in
  let running = window ~partition_by:[part k] ~order_by:[asc v; asc id]
      ~frame:(rows ~start:Unbounded_preceding ~end_:Current_row) () in
  select_over Exprs.[lift id; row_number by_row; rank by_v; dense_rank by_v; lag v by_row; lead v by_row;
                     Over.sum v running]
    ~row:(fun id rn r dr lg ld s -> (id, rn, r, dr, lg, ld, s)) ~order_by:[asc (lift id)])))
let () =
  let c = Lazy.force connection in
  property "window functions match a reference" (fun tc ->
    let rows = List.init (Hegel.draw ~label:"rows" tc (Hegel.integers ~min_value:0 ~max_value:10 ())) ~f:(fun i ->
      { id = Int64.of_int i;
        k = Int64.of_int (Hegel.draw ~label:"k" tc (Hegel.integers ~min_value:0 ~max_value:2 ()));
        v = Int64.of_int (Hegel.draw ~label:"v" tc (Hegel.integers ~min_value:(-3) ~max_value:3 ())) }) in
    exec "DELETE FROM wcells";
    ok (T.with_appender c cells ~f:(fun a -> T.append a (List.map rows ~f:(fun r -> D.Args.[r.id; r.k; r.v]))));
    let expected = List.map rows ~f:(fun r ->
      let partition = List.filter rows ~f:(fun o -> Int64.equal o.k r.k)
        |> List.sort ~compare:(fun a b -> match Int64.compare a.v b.v with 0 -> Int64.compare a.id b.id | c -> c) in
      let position, _ = List.findi_exn partition ~f:(fun _ o -> Int64.equal o.id r.id) in
      let below = List.filter partition ~f:(fun o -> Int64.(o.v < r.v)) in
      let distinct_below = List.dedup_and_sort (List.map below ~f:(fun o -> o.v)) ~compare:Int64.compare in
      let at i = Option.map (List.nth partition i) ~f:(fun o -> o.v) in
      (r.id, Int64.of_int (position + 1), Int64.of_int (List.length below + 1), Int64.of_int (List.length distinct_below + 1),
       (if position = 0 then None else at (position - 1)), at (position + 1),
       Some (List.fold (List.take partition (position + 1)) ~init:0L ~f:(fun s o -> Int64.(s + o.v))))) in
    let actual = ok (R.Session.collect c windowed D.Args.[]) in
    if not (List.equal Poly.equal actual expected) then begin
      let show (id, rn, r, dr, lg, ld, s) =
        let o = Option.value_map ~default:"NULL" ~f:Int64.to_string in
        Printf.sprintf "(%Ld rn=%Ld rank=%Ld dense=%Ld lag=%s lead=%s sum=%s)" id rn r dr (o lg) (o ld) (o s) in
      failwith ("DuckDB " ^ String.concat (List.map actual ~f:show) ^ " reference " ^ String.concat (List.map expected ~f:show))
    end)
