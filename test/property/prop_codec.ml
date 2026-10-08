(* Codec round trips: a value bound as a parameter, appended, or rendered as
   a literal reads back equal. *)
open! Base
open Prop_support

let select_param codec sql_type =
  R.one D.Fields.[codec] D.Fields.[codec] ~row:Fn.id ("SELECT CAST(? AS " ^ sql_type ^ ")")
let () =
  let q = select_param D.Fields.int64 "BIGINT" in
  property "int64 parameter" (fun tc ->
    let v = Hegel.draw ~label:"v" tc int64s in
    let back = ok (R.Session.find (Lazy.force connection) q D.Args.[v]) in
    if not (Int64.equal v back) then failwith (Printf.sprintf "%Ld read back as %Ld" v back))
