#!/usr/bin/env bash
set -euo pipefail
compiler=$1
directory=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$directory/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

compile_positive() {
  local target_directory=$1
  cp "$repository/lib/ffi/duckdb_ffi.mli" \
    "$directory/interface_positive.mli" \
    "$directory/interface_positive.ml" \
    "$target_directory/"
  (
    cd "$target_directory"
    "$compiler" -extension-universe beta -w @a -c duckdb_ffi.mli
    "$compiler" -extension-universe beta -w @a -c interface_positive.mli
    "$compiler" -extension-universe beta -w @a -c interface_positive.ml
  )
}

mkdir "$tmp/green" "$tmp/red"
compile_positive "$tmp/green"
cp "$repository/lib/ffi/duckdb_ffi.mli" \
  "$directory/interface_positive.mli" \
  "$directory/interface_positive.ml" \
  "$tmp/red/"
# Dune inputs are read-only; mutate only our disposable copy.
chmod u+w "$tmp/red/duckdb_ffi.mli"
python3 - "$tmp/red/duckdb_ffi.mli" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
start = text.index("module Native_request : sig\n")
end = text.index("\nend\n", start) + len("\nend\n")
path.write_text(text[:start] + text[end:])
PY
(
  cd "$tmp/red"
  "$compiler" -extension-universe beta -w @a -c duckdb_ffi.mli
  "$compiler" -extension-universe beta -w @a -c interface_positive.mli
  if "$compiler" -extension-universe beta -w @a -c interface_positive.ml >red.out 2>&1; then
    echo 'unexpected acceptance without Native_request interface'
    exit 1
  fi
  cat red.out
  grep -Fq 'line 2, characters 16-48:' red.out
  grep -Fq 'Duckdb_ffi.Native_request.create' red.out
  grep -Fq 'Unbound module "Duckdb_ffi.Native_request"' red.out
)
for source in connection_delivery forge_request; do
  cp "$directory/$source.ml.fail" "$tmp/green/$source.ml"
  (
    cd "$tmp/green"
    if "$compiler" -extension-universe beta -w -a -c "$source.ml" >"$source.out" 2>&1; then
      echo "unexpected acceptance: $source"
      exit 1
    fi
    cat "$source.out"
    grep -Fq 'Duckdb_ffi.Native_request.t' "$source.out"
    grep -Fq 'but an expression was expected of type' "$source.out"
    if [[ $source == connection_delivery ]]; then
      grep -Fq 'line 2, characters 42-52:' "$source.out"
      grep -Fq 'try_interrupt connection' "$source.out"
      grep -Fq 'This expression has type "Duckdb_ffi.connection"' "$source.out"
    else
      grep -Fq 'line 1, characters 44-46:' "$source.out"
      grep -Fq 'Native_request.t = ()' "$source.out"
      grep -Fq 'This expression has type "unit"' "$source.out"
    fi
  )
done
printf 'native request interface: all operations + missing-interface/connection-delivery/forgery rejections passed\n'
