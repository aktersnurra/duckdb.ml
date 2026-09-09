#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../../../lib/duckdb/duckdb.mli" "$root"/../../ownership/adapter-static/* "$tmp/"
# Installed pinned scheduler interfaces, current real standalone Duckdb interface.
readarray -t includes < <(ocamlfind query -recursive -format '%d' async eio.unix)
args=()
for directory in "${includes[@]}"; do args+=(-I "$directory"); done
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
for name in positive owned_async owned_eio; do
  "$compiler" -extension-universe beta "${args[@]}" -w @a -c "$name.mli"
  "$compiler" -extension-universe beta -alert -do_not_spawn_domains "${args[@]}" -w @a -c "$name.ml"
done
for name in async_chunk eio_chunk domain; do
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -alert -do_not_spawn_domains "${args[@]}" -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"
    exit 1
  fi
  cat "$name.out"
  if [[ $name = domain ]]; then
    grep -q 'Domain.Safe.spawn (fun () -> connection)' "$name.out"
    grep -q 'characters 31-41' "$name.out"
    grep -q '"contended"' "$name.out"
    grep -q '"uncontended"' "$name.out"
  else
    grep -q 'value "chunk"' "$name.out"
    grep -q '"local"' "$name.out"
    grep -q '"global"' "$name.out"
  fi
done
echo 'adapter ownership modes: three paired controls and source-named rejections=ok (owned scheduler controls compile-only)'
