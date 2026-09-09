#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
# Each script creates a separate producer, installs FFI -> core -> exactly one
# adapter, removes the sibling from that producer, then hides the producer before
# its external consumer is built.  This orchestrator adds no package solver step.
bash test/install_smoke.sh
bash test/install_async_smoke.sh
bash test/install_eio_smoke.sh
echo 'four-package installed smoke: FFI/core, Async-only, and Eio-only consumers passed'
