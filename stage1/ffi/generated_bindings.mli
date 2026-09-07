module Bindings (F : Ctypes.FOREIGN) : sig
  val query : (char Ctypes.ptr -> unit Ctypes.ptr F.return) F.result
  val destroy : (unit Ctypes.ptr -> unit F.return) F.result
  val status : (unit Ctypes.ptr -> int F.return) F.result
  val count : (unit Ctypes.ptr -> int F.return) F.result
  val message : (unit Ctypes.ptr -> string F.return) F.result
  val value : (unit Ctypes.ptr -> int -> int64 F.return) F.result
  val slow : (unit -> unit F.return) F.result
end
