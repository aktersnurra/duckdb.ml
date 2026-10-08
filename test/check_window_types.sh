#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/window_compile/* "$tmp/"
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
expect window_where 'Duckdb.Sql.windowed' 'Duckdb.Sql.row'
expect window_having 'Duckdb.Sql.windowed' 'Duckdb.Sql.grouped'
expect window_in_aggregate 'Duckdb.Sql.windowed' 'Duckdb.Sql.row'
expect unlifted_column 'Duckdb.Sql.row' 'Duckdb.Sql.windowed'
expect lag_or_nullable 'Type "int64 option" is not compatible with type "int64"'
expect window_assignment 'Duckdb.Sql.windowed' 'Duckdb.Sql.row'
expect window_in_window 'windowed'
