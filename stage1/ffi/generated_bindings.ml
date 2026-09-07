open Ctypes

module Bindings (F : FOREIGN) = struct
  open F
  let query = foreign "stage1_query" (ptr char @-> returning (ptr void))
  let destroy = foreign "stage1_destroy" (ptr void @-> returning void)
  let status = foreign "stage1_status" (ptr void @-> returning int)
  let count = foreign "stage1_count" (ptr void @-> returning int)
  let message = foreign "stage1_error" (ptr void @-> returning string)
  let value = foreign "stage1_value" (ptr void @-> int @-> returning int64_t)
  let slow = foreign "stage1_slow" (void @-> returning void)
end
