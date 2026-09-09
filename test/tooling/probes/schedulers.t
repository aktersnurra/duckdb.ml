Separate scheduler stacks on the pinned compiler; timeout prevents hung probes.

  $ timeout 30 ./async_probe.exe
  async: worker=42 heartbeat=ok
  $ timeout 30 ./eio_probe.exe
  eio: worker=42 heartbeat=ok

Worker startup is held behind a scheduler-controlled gate: this is not a sleep
chosen to race the timer. The scheduler must let it start before checking it.

  $ STAGE1_DEFER_WORKER_START=1 timeout 30 ./async_probe.exe
  async: worker=42 heartbeat=ok
  $ STAGE1_DEFER_WORKER_START=1 timeout 30 ./eio_probe.exe
  eio: worker=42 heartbeat=ok

A heartbeat failure must release/join the worker, not hang during shutdown.

  $ STAGE1_FAIL_HEARTBEAT=1 timeout 30 ./async_probe.exe > async-error 2>&1; echo $?
  1
  $ grep -q 'injected heartbeat failure' async-error && echo cleanup=ok
  cleanup=ok
  $ STAGE1_FAIL_HEARTBEAT=1 timeout 30 ./eio_probe.exe > eio-error 2>&1; echo $?
  2
  $ grep -q 'injected heartbeat failure' eio-error && echo cleanup=ok
  cleanup=ok
