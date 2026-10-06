(* Every accepted typed-request form compiles. *)
module D = Duckdb
module R = D.Request

let user_id = D.Codec.Values.custom ~encode:(fun (`User n) -> Base.Or_error.return n)
  ~decode:(fun n -> Base.Or_error.return (`User n)) D.Codec.Values.int64
let insert = R.exec D.Fields.[int64; nullable string; user_id; nullable user_id] "insert into t values (?, ?, ?, ?)"
let one = R.one D.Fields.[int64] D.Fields.[int64; string] ~row:(fun a b -> (a, b)) "select a, b from t where a = ?"
let opt = R.zero_or_one D.Fields.[] D.Fields.[nullable float64] ~row:(fun x -> x) "select max(x) from t"
let many = R.many D.Fields.[] D.Fields.[user_id] ~row:(fun (`User n) -> n) "select id from t"
type record = { value : int64; note : string option }
let records = R.many D.Fields.[int64] D.Fields.[int64; nullable string]
  ~row:(fun value note -> { value; note }) "select value, note from t where value > ?"

let connection (c : D.connection) : (unit, D.Error.t) result =
  let ( let* ) x f = Result.bind x f in
  let* () = R.Session.exec c insert D.Args.[1L; None; `User 2L; Some (`User 3L)] in
  let* ((_ : int64), (_ : string)) = R.Session.find c one D.Args.[1L] in
  let* (_ : (int64 * string) option) = R.Session.find_opt c one D.Args.[1L] in
  let* (_ : (int64 * string) list) = R.Session.collect c one D.Args.[1L] in
  let* (_ : float option option) = R.Session.find_opt c opt D.Args.[] in
  let* (_ : int64 list) = R.Session.collect c many D.Args.[] in
  let* (_ : record list) = R.Session.collect c records D.Args.[0L] in
  let* (_ : int) = R.Session.fold c many D.Args.[] ~init:0 ~f:(fun _ n -> Ok (D.Continue (n + 1))) in
  let* (_ : unit list) = R.Session.collect c insert D.Args.[1L; Some "x"; `User 2L; None] in
  R.Session.with_transaction c ~f:(fun tx ->
    match R.Session.exec tx insert D.Args.[1L; None; `User 2L; None] with Error e -> Error e | Ok () ->
    match R.Session.find tx one D.Args.[1L] with Error e -> Error e | Ok (_ : int64 * string) ->
    match R.Session.collect tx many D.Args.[] with Error e -> Error e | Ok (_ : int64 list) ->
    R.Session.fold tx many D.Args.[] ~init:() ~f:(fun _ () -> Ok (D.Stop ())))

let example = D.Table.(declare "example" Columns.[ "value", int64; "note", nullable string ]
  ~row:(fun value note -> { value; note }))
let tables (c : D.connection) : (unit, D.Error.t) result =
  let ( let* ) x f = Result.bind x f in
  let* (_ : record list) = R.Session.collect c (D.Table.select example) D.Args.[] in
  let* () = R.Session.exec c (D.Table.insert example) D.Args.[1L; Some "x"] in
  let* () = R.Session.ingest c example [[D.Args.[1L; None]]; [D.Args.[2L; Some "y"]]] ~flush:true in
  D.Table.with_appender c example ~f:(fun a ->
    match D.Table.append a [D.Args.[1L; None]; D.Args.[2L; Some "y"]] with Error e -> Error e | Ok () ->
    D.Table.flush a)
let transactional_table (tx : D.transaction) =
  D.Table.with_appender tx example ~f:(fun a -> D.Table.append a [D.Args.[3L; None]])
let parquet (c : D.connection) path =

  let (_ : (int, D.Error.t) result) =
    D.Parquet.fold c [path] D.Fields.[int64] ~row:(fun x -> x) ~init:0 ~f:(fun _ n -> Ok (D.Continue (n + 1))) in
  D.Parquet.fold_table c [path] example ~init:[] ~f:(fun r rs -> Ok (D.Continue (r :: rs)))
let context (e : D.Error.t) = D.Error.(match e.context with
  | Query sql | Parquet sql -> sql | Table { name; _ } -> name | Database | Connection | Transaction -> "") ^ R.query one

(* Backend-generic code over the CONNECTION signature. *)
module Count (B : R.CONNECTION) = struct
  let all owner = B.collect owner many D.Args.[]
end
module Sync_count = Count (R.Session)
let (_ : D.connection -> (int64 list, D.Error.t) result) = Sync_count.all
(* The nullability phantoms are distinct, so single-case matches on Bulk
   indices are exhaustive. *)
let _all_valid (t : (int64, Bigarray.int64_elt, D.Codec.non_null) D.Bulk.t) = match t.D.Bulk.validity with D.Bulk.All_valid -> ()
let _mask (t : (float, Bigarray.float64_elt, D.Codec.nullable) D.Bulk.t) = match t.D.Bulk.validity with D.Bulk.Mask m -> m
let _strings_opt : D.Codec.nullable D.Bulk.strings -> string option array = function D.Bulk.Strings_opt v -> v
let _columns (a : (int64 * (string * (int32 option * unit)), _) D.Table.appender @ local) =
  let module A1 = Bigarray.Array1 in
  D.Table.append_columns a D.Bulk.Columns.[
    Int64 (D.Scalar.Int64, A1.create Bigarray.int64 Bigarray.c_layout 0);
    Strings (D.Scalar.String, [||]);
    Nullable (Int32 (D.Scalar.Int32, A1.create Bigarray.int32 Bigarray.c_layout 0),
              A1.create Bigarray.int8_unsigned Bigarray.c_layout 0) ]
