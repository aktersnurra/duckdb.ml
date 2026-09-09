let enabled = false
let cancellation_count = Stdlib.Atomic.make 0
let cancellation_latched () = ignore (Stdlib.Atomic.fetch_and_add cancellation_count 1)
let cancellations () = Stdlib.Atomic.get cancellation_count
let operation_count = Stdlib.Atomic.make 0
let callback_count = Stdlib.Atomic.make 0
let clear = Stdlib.Atomic.make true
let flush_count = Stdlib.Atomic.make 0
let operation_entry () = ignore (Stdlib.Atomic.fetch_and_add operation_count 1)
let operations () = Stdlib.Atomic.get operation_count
let callback_cleanup active =
  ignore (Stdlib.Atomic.fetch_and_add callback_count 1);
  if active then Stdlib.Atomic.set clear false
let callbacks () = Stdlib.Atomic.get callback_count
let tls_clear () = Stdlib.Atomic.get clear
let explicit_flush () = ignore (Stdlib.Atomic.fetch_and_add flush_count 1)
let flushes () = Stdlib.Atomic.get flush_count
