#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/schema_compile/* "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
# Warnings 40/41/42: binder patterns ([fun [id; name]]) select their
# constructors by type. Warning 45: [Exprs.[...]] literals shadow the list
# constructors through a local open.
"$compiler" -extension-universe beta -w @a-40-41-42-44-45-70 -c positive.ml
# Each fixture: name, then substrings its compiler error must contain.
expect() {
  local name=$1; shift
  cp "$name.ml.fail" "$name.ml"
  if "$compiler" -extension-universe beta -c "$name.ml" >"$name.out" 2>&1; then
    echo "unexpected acceptance: $name"; exit 1
  fi
  cat "$name.out"
  # Messages wrap by length; match against whitespace-normalized text.
  local text; text=$(tr -s ' \n' '  ' <"$name.out")
  for needle in "$@"; do
    if [[ $text != *"$needle"* ]]; then echo "$name: missing \"$needle\""; exit 1; fi
  done
}
expect key_nullable 'Type "Duckdb.Codec.nullable" is not compatible with type "Duckdb.Codec.non_null"'
expect foreign_key_type 'Type "int32" is not compatible with type "int64"'
expect default_type 'Type "int64" is not compatible with type "int32"'
expect default_nullability 'Type "int64 option" is not compatible with type "int64"'
expect check_nullable 'Type "bool option" is not compatible with type "bool"'
expect find_lookup '"Duckdb.Request.zero_or_one"' '[< `One ]'
expect binder_arity 'is not compatible with type "unit"' 'Duckdb.Codec.slot'
