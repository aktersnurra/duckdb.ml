#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/appender_compile/* "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
"$compiler" -extension-universe beta -w @a-70 -c positive.ml
for name in connection owner chunk; do
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"
    exit 1
  fi
  cat "$name.out"
  case "$name" in
  connection)
    grep -q 'Duckdb.connection' "$name.out"
    grep -q 'Duckdb.transaction' "$name.out"
    ;;
  owner)
    grep -q 'Duckdb.appender' "$name.out"
    grep -q 'Duckdb.connection' "$name.out"
    ;;
  chunk)
    grep -q 'Duckdb.chunk' "$name.out"
    grep -q 'Duckdb.appender' "$name.out"
    ;;
  esac
done
echo 'appender interfaces: positive controls and three abstract-owner rejections passed'
