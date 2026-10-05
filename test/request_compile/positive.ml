(* Every accepted typed-request form compiles. *)
module D = Duckdb
module R = D.Request
module C = R.Connection
module T = R.Transaction

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
  let* () = C.exec c insert D.Args.[1L; None; `User 2L; Some (`User 3L)] in
  let* ((_ : int64), (_ : string)) = C.find c one D.Args.[1L] in
  let* (_ : (int64 * string) option) = C.find_opt c one D.Args.[1L] in
  let* (_ : (int64 * string) list) = C.collect c one D.Args.[1L] in
  let* (_ : float option option) = C.find_opt c opt D.Args.[] in
  let* (_ : int64 list) = C.collect c many D.Args.[] in
  let* (_ : record list) = C.collect c records D.Args.[0L] in
  let* (_ : int) = C.fold c many D.Args.[] ~init:0 ~f:(fun _ n -> Ok (D.Continue (n + 1))) in
  let* (_ : unit list) = C.collect c insert D.Args.[1L; Some "x"; `User 2L; None] in
  C.with_transaction c ~f:(fun tx ->
    let* () = T.exec tx insert D.Args.[1L; None; `User 2L; None] in
    let* (_ : int64 * string) = T.find tx one D.Args.[1L] in
    let* (_ : int64 list) = T.collect tx many D.Args.[] in
    T.fold tx many D.Args.[] ~init:() ~f:(fun _ () -> Ok (D.Stop ())))

let example = D.Table.(declare "example" Columns.[ "value", int64; "note", nullable string ]
  ~row:(fun value note -> { value; note }))
let tables (c : D.connection) : (unit, D.Error.t) result =
  let ( let* ) x f = Result.bind x f in
  let* (_ : record list) = C.collect c (D.Table.select example) D.Args.[] in
  let* () = C.exec c (D.Table.insert example) D.Args.[1L; Some "x"] in
  let* () = C.ingest c example [[D.Args.[1L; None]]; [D.Args.[2L; Some "y"]]] ~flush:true in
  D.Table.with_appender c example ~f:(fun a ->
    let* () = D.Table.append a [D.Args.[1L; None]; D.Args.[2L; Some "y"]] in
    D.Table.flush a)
let transactional_table (tx : D.transaction) =
  D.Table.with_appender_transaction tx example ~f:(fun a -> D.Table.append a [D.Args.[3L; None]])
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
module Sync_count = Count (R.Connection)
let (_ : D.connection -> (int64 list, D.Error.t) result) = Sync_count.all
