type owner
external create : unit -> owner = "stage2_ffi_create"
external prepare : owner -> string -> unit = "stage2_ffi_prepare"
external next : owner -> int = "stage2_ffi_next"
external status : owner -> int = "stage2_ffi_status" [@@noalloc]
external message : owner -> string = "stage2_ffi_message"
external close : owner -> unit = "stage2_ffi_close" [@@noalloc]
external length : owner @ local -> int = "stage2_ffi_length" [@@noalloc]
external valid : owner @ local -> int -> bool = "stage2_ffi_valid" [@@noalloc]
external value : owner @ local -> int -> int64#
  = "stage2_ffi_value" "stage2_ffi_value_unboxed" [@@noalloc]
external box : int64# -> int64 = "%box_int64"
external live_resources : unit -> int = "stage2_ffi_live" [@@noalloc]
external fallback_reclaims : unit -> int = "stage2_ffi_fallback_reclaims" [@@noalloc]
