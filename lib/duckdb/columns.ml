include Codec.Values
type ('a, 'n) named = string * ('a, 'n) Codec.t
include Spine.Make (struct type ('a, 'n) t = ('a, 'n) named end)
