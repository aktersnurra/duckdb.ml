#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/compile/* "$tmp/"
cd "$tmp"
compile() { "$compiler" -extension-universe beta -alert -do_not_spawn_domains -w @a -c "$1"; }
compile duckdb.mli
# Standalone fixtures have no .mli by design.
"$compiler" -extension-universe beta -alert -do_not_spawn_domains -w @a-70 -c positive.ml
for name in domain transaction_as_connection; do
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -alert -do_not_spawn_domains -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"
    exit 1
  fi
  cat "$name.out"
  case "$name" in
  domain)
    grep -q 'connection' "$name.out"
    grep -q '"contended"' "$name.out"
    grep -q '"uncontended"' "$name.out"
    grep -q '"portable"' "$name.out"
    ;;
  transaction_as_connection)
    grep -q 'Duckdb.transaction' "$name.out"
    grep -q 'Duckdb.connection' "$name.out"
    ;;
  esac
done
echo 'duckdb interfaces: warnings-as-errors/positive controls/two intended rejections=ok'
