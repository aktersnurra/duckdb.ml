#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/named_compile/* "$tmp/"
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
expect other_shape 'Duckdb.Sql.field'
expect outer_index 'Duckdb.Sql.Outer.t' 'Duckdb.Sql.Binders.t'
expect outer_unlifted 'Duckdb.Sql.outer' 'Duckdb.Sql.expr'
expect wrong_length 'Duckdb.Codec.slot'
