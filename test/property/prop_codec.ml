(* Codec round trips: a value bound as a parameter, appended to a table, or
   rendered as a [Sql.value] literal reads back equal. *)
open! Base
open Prop_support
module V = D.Codec.Values
module T = D.Table
module S = D.Sql
module I8 = Stdlib_stable.Int8
module I16 = Stdlib_stable.Int16
module F32 = Stdlib_stable.Float32

let ints ~min ~max = Hegel.integers ~min_value:min ~max_value:max ()
let mapped sexp f gen = printable sexp (Hegel.map f gen)
(* Bit equality, but any NaN equals any NaN: payloads are not preserved. *)
let same_float a b = (Float.is_nan a && Float.is_nan b) || Int64.equal (Int64.bits_of_float a) (Int64.bits_of_float b)
let floats = Hegel.floats ~allow_nan:true ~allow_infinity:true ()
let cents = V.custom ~encode:(fun n -> Or_error.return (Int64.( * ) n 100L))
    ~decode:(fun n -> Or_error.return (Int64.( / ) n 100L)) V.int64

type case =
  | Case : { name : string; codec : ('a, D.Codec.non_null) D.Codec.t; sql_type : string;
             gen : ('a, Hegel.printable) Hegel.generator; equal : 'a -> 'a -> bool } -> case
let cases = [
  Case { name = "bool"; codec = V.bool; sql_type = "BOOLEAN"; gen = Hegel.booleans (); equal = Bool.equal };
  Case { name = "int8"; codec = V.int8; sql_type = "TINYINT";
         gen = mapped (fun v -> Int.sexp_of_t (I8.to_int v)) I8.of_int (ints ~min:(-128) ~max:127);
         equal = (fun a b -> Int.equal (I8.to_int a) (I8.to_int b)) };
  Case { name = "int16"; codec = V.int16; sql_type = "SMALLINT";
         gen = mapped (fun v -> Int.sexp_of_t (I16.to_int v)) I16.of_int (ints ~min:(-32768) ~max:32767);
         equal = (fun a b -> Int.equal (I16.to_int a) (I16.to_int b)) };
  Case { name = "int32"; codec = V.int32; sql_type = "INTEGER";
         gen = mapped Int32.sexp_of_t Int32.of_int_trunc (ints ~min:(-2147483648) ~max:2147483647); equal = Int32.equal };
  Case { name = "int64"; codec = V.int64; sql_type = "BIGINT"; gen = int64s; equal = Int64.equal };
  Case { name = "float32"; codec = V.float32; sql_type = "FLOAT";
         gen = mapped (fun f -> Float.sexp_of_t (F32.to_float f)) F32.of_float floats;
         equal = (fun a b -> same_float (F32.to_float a) (F32.to_float b)) };
  Case { name = "float64"; codec = V.float64; sql_type = "DOUBLE"; gen = floats; equal = same_float };
  Case { name = "string"; codec = V.string; sql_type = "VARCHAR";
         gen = Hegel.text ~exclude_characters:"\000" (); equal = String.equal };
  Case { name = "blob"; codec = V.blob; sql_type = "BLOB"; gen = Hegel.binary (); equal = String.equal };
  (* DuckDB's finite dates and timestamps; Hegel's integers are 63 bits. *)
  Case { name = "date"; codec = V.date; sql_type = "DATE";
         gen = mapped Int32.sexp_of_t Int32.of_int_trunc (ints ~min:(-2147483646) ~max:2147483646); equal = Int32.equal };
  Case { name = "timestamp"; codec = V.timestamp_us; sql_type = "TIMESTAMP";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:Int.min_value ~max:Int.max_value); equal = Int64.equal };
  Case { name = "timestamp_ms"; codec = V.timestamp_ms; sql_type = "TIMESTAMP_MS";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:(-4_000_000_000_000_000) ~max:4_000_000_000_000_000);
         equal = Int64.equal };
  Case { name = "timestamp_s"; codec = V.timestamp_s; sql_type = "TIMESTAMP_S";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:(-4_000_000_000_000) ~max:4_000_000_000_000);
         equal = Int64.equal };
  Case { name = "timestamp_ns"; codec = V.timestamp_ns; sql_type = "TIMESTAMP_NS";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:Int.min_value ~max:Int.max_value); equal = Int64.equal };
  Case { name = "timestamp_tz"; codec = V.timestamp_tz; sql_type = "TIMESTAMPTZ";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:Int.min_value ~max:Int.max_value); equal = Int64.equal };
  Case { name = "custom"; codec = cents; sql_type = "BIGINT";
         gen = mapped Int64.sexp_of_t Int64.of_int (ints ~min:(-92233720368547758) ~max:92233720368547758);
         equal = Int64.equal } ]

let one = T.(declare "one" Columns.["id", int64] ~row:Fn.id)
let () = exec "CREATE TABLE one(id BIGINT NOT NULL)"; exec "INSERT INTO one VALUES (1)"

(* Hegel prints the drawn [v] on failure. *)
let check name equal v back = if not (equal v back) then failwith (name ^ ": read back differently")
let run (Case c) =
  let c' = Lazy.force connection in
  let param = R.one D.Fields.[c.codec] D.Fields.[c.codec] ~row:Fn.id ("SELECT CAST(? AS " ^ c.sql_type ^ ")") in
  property (c.name ^ " parameter") (fun tc ->
    let v = Hegel.draw ~label:"v" tc c.gen in
    check c.name c.equal v (ok (R.Session.find c' param D.Args.[v])));
  let optional_codec = V.nullable c.codec in
  let optional = R.one D.Fields.[optional_codec] D.Fields.[optional_codec] ~row:Fn.id ("SELECT CAST(? AS " ^ c.sql_type ^ ")") in
  property (c.name ^ " nullable parameter") (fun tc ->
    let v = Hegel.draw ~label:"v" tc (Hegel.optional c.gen) in
    check c.name (Option.equal c.equal) v (ok (R.Session.find c' optional D.Args.[v])));
  let table = T.(declare ("t_" ^ c.name) Columns.["x", c.codec] ~row:Fn.id) in
  exec ("CREATE TABLE \"t_" ^ c.name ^ "\" (x " ^ c.sql_type ^ " NOT NULL)");
  property (c.name ^ " appender") (fun tc ->
    let v = Hegel.draw ~label:"v" tc c.gen in
    exec ("DELETE FROM \"t_" ^ c.name ^ "\"");
    ok (T.with_appender c' table ~f:(fun a -> T.append a [ D.Args.[v] ]));
    match ok (R.Session.collect c' (T.select table) D.Args.[]) with
    | [ back ] -> check c.name c.equal v back
    | rows -> failwith (Printf.sprintf "%s: %d rows" c.name (List.length rows)));
  property (c.name ^ " value literal") (fun tc ->
    let v = Hegel.draw ~label:"v" tc c.gen in
    let q = S.(query Params.[] (fun [] -> from one (fun [_] -> select Exprs.[value c.codec v] ~row:Fn.id))) in
    match ok (R.Session.collect c' q D.Args.[]) with
    | [ back ] -> check c.name c.equal v back
    | rows -> failwith (Printf.sprintf "%s: %d rows" c.name (List.length rows)))
let () = List.iter cases ~f:run
