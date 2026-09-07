Separate scheduler stacks on the pinned compiler; timeout prevents hung probes.

  $ timeout 30 ./async_probe.exe
  async: worker=42 heartbeat=ok
  $ timeout 30 ./eio_probe.exe
  eio: worker=42 heartbeat=ok
