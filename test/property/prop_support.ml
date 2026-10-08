(* Shared runner, generators and session helpers for the property tests. *)
open! Base
module D = Duckdb
module R = D.Request

(* 100 cases unless PROPERTY_CASES says otherwise; no example database, so a
   run writes no files. *)
let settings () =
  let cases = Option.value_map (Sys.getenv "PROPERTY_CASES") ~default:100 ~f:Int.of_string in
  Hegel.settings ~test_cases:cases () |> Hegel.with_database Disabled

let property name f =
  Hegel.run_hegel_test ~settings:(settings ()) ~database_key:name f;
  Stdlib.print_endline ("property: " ^ name ^ "=ok")

let describe (e : D.Error.t) =
  match e.cause with
  | Native s -> "Native: " ^ s
  | Type_mismatch { expected; actual; _ } -> "Type_mismatch " ^ expected ^ "/" ^ actual
  | Null { column; row } -> Printf.sprintf "Null column %d row %d" column row
  | Embedded_nul -> "Embedded_nul"
  | _ -> "other cause"
let ok = function Ok x -> x | Error e -> failwith ("unexpected error: " ^ describe e)

(* One in-memory database and connection for the whole executable: owned
   handles are global, so property bodies may capture them. *)
let connection =
  lazy
    (let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
     ok (D.Owned.connect db))
let exec sql = ok (R.Session.exec (Lazy.force connection) (R.exec D.Fields.[] sql) D.Args.[])

(* Printable generators of any value: [map] loses the printer, [with_printer]
   restores one. *)
let printable sexp gen = Hegel.with_printer sexp gen
let int64s =
  (* Hegel's integers are OCaml ints (63 bits): the extremes and odd values
     beyond them are mixed in. Plain values come first, so failures shrink
     toward small numbers. *)
  printable Int64.sexp_of_t
    (Hegel.map (fun (pick, n) ->
       match pick with
       | 7 -> Int64.min_value
       | 8 -> Int64.max_value
       | 9 -> Int64.(of_int n * 2L + 1L)
       | _ -> Int64.of_int n)
      (Hegel.tuples2 (Hegel.integers ~min_value:0 ~max_value:9 ()) (Hegel.integers ())))
