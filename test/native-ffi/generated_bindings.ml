open Ctypes

module Bindings (F : FOREIGN) = struct
  open F
  let query_into = foreign "stage1_query_into" (ptr char @-> ptr (ptr void) @-> returning void)
  let status = foreign "stage1_status" (ptr void @-> returning int)
  let count = foreign "stage1_count" (ptr void @-> returning int)
  let message = foreign "stage1_error" (ptr void @-> returning string)
  let value = foreign "stage1_value" (ptr void @-> int @-> returning int64_t)
  let slow = foreign "stage1_slow" (void @-> returning void)
end

module Cleanup (F : FOREIGN) = struct
  open F
  let destroy_slot = foreign "stage1_destroy_slot" (ptr (ptr void) @-> returning void)
end
