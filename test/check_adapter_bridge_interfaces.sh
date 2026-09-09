#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/adapter_bridge_compile/* "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
"$compiler" -extension-universe beta -w @a -c positive.mli
"$compiler" -extension-universe beta -w @a -c positive.ml
for name in private_resource forge_request forge_pointer domain; do
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"
    exit 1
  fi
  cat "$name.out"
  grep -Fq "File \"$name.ml\", line 1" "$name.out"
  case "$name" in
  private_resource)
    grep -Fq 'Duckdb__Resource.Bridge.create' "$name.out"
    grep -Fq 'Unbound module "Duckdb__Resource"' "$name.out"
    ;;
  forge_request)
    grep -Fq 'Duckdb.Bridge.cancel ()' "$name.out"
    grep -Fq 'type "unit"' "$name.out"
    grep -Fq '"Duckdb.Bridge.request"' "$name.out"
    ;;
  forge_pointer)
    grep -Fq 'Nativeint.zero' "$name.out"
    grep -Fq 'type "nativeint"' "$name.out"
    grep -Fq '"Duckdb.connection"' "$name.out"
    ;;
  domain)
    grep -Fq 'line 1, characters 77-87:' "$name.out"
    grep -Fq 'This value is "contended"' "$name.out"
    grep -Fq 'expected to be "uncontended"' "$name.out"
    grep -Fq 'expected to be "portable"' "$name.out"
    ;;
  esac
done
echo 'adapter bridge interfaces: positive + four source-specific rejections passed'
