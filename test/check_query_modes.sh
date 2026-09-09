#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/query_compile/* "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
"$compiler" -extension-universe beta -alert -do_not_spawn_domains -w @a-70 -c positive.ml
for name in return store capture domain inner_effect owner_close owner_reset; do
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -alert -do_not_spawn_domains -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"
    exit 1
  fi
  cat "$name.out"
  case "$name" in
  owner_close)
    grep -q 'Duckdb.chunk' "$name.out"
    grep -q 'Duckdb.query_result' "$name.out"
    ;;
  owner_reset)
    grep -q 'Duckdb.chunk' "$name.out"
    grep -q 'Duckdb.prepared' "$name.out"
    ;;
  *)
    grep -q '"local"' "$name.out"
    grep -q '"global"' "$name.out"
    ;;
  esac
done
echo 'query modes: owned/alias/domain controls and seven intended escape/owner rejections=ok'
