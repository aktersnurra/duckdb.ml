#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d ./unboxed.XXXXXX)
trap 'rm -rf "$work"' EXIT
compiler=$1
include=$(dirname "$2")
cp "$3" "$work/rejected.mli"
# The boxed positive control must compile with the same includes and compiler.
sed 's/int64#/int64/g' "$3" > "$work/accepted.mli"
"$compiler" -extension-universe beta -I "$include" -c "$work/accepted.mli"
if "$compiler" -extension-universe beta -I "$include" -c "$work/rejected.mli" > "$work/diagnostic" 2>&1; then
  echo 'ERROR: unexpectedly accepted a bits64 Ctypes.typ witness' >&2
  exit 1
fi
cat "$work/diagnostic"
grep -q 'bits64' "$work/diagnostic"
grep -q 'value' "$work/diagnostic"
echo 'ctypes: boxed witness accepted; native int64# witness rejected as expected'
