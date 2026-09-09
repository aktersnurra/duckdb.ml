open! Base

type response
external query : string -> response = "stage1_hand_query"
external destroy : response -> unit = "stage1_hand_destroy"
external status : response -> int = "stage1_hand_status" [@@noalloc]
external count : response -> int = "stage1_hand_count" [@@noalloc]
external message : response -> string = "stage1_hand_error"
external value : response -> int -> int64 = "stage1_hand_value"
(* This bits64 ABI compiles with the pinned OxCaml compiler, not upstream OCaml. *)
external value_unboxed : response -> int -> int64#
  = "stage1_hand_value" "stage1_hand_value_unboxed" [@@noalloc]
external box_int64 : int64# -> int64 = "%box_int64"
external slow : unit -> unit = "stage1_hand_slow"
external slow_locked : unit -> unit = "stage1_hand_slow_locked"
external active : unit -> int = "stage1_hand_active" [@@noalloc]
external live_results : unit -> int = "stage1_hand_live" [@@noalloc]

let decode sql ~get =
  if String.contains sql '\000' then Error Probe_error.Embedded_nul
  else
    let response = query sql in
    Exn.protect
      ~f:(fun () ->
        match status response with
        | 0 -> Ok (Array.init (count response) ~f:(get response))
        | 1 -> Error (Probe_error.Open_failed (message response))
        | 2 -> Error Probe_error.Connect_failed
        | 3 -> Error (Probe_error.Query_failed (message response))
        | 4 -> Error Probe_error.Unsupported_schema
        | 5 -> Error Probe_error.Allocation_failed
        | _ -> failwith "unexpected native status")
      ~finally:(fun () -> destroy response)

let query_int64 sql = decode sql ~get:value
let query_int64_unboxed sql =
  decode sql ~get:(fun response index -> box_int64 (value_unboxed response index))
