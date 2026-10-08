#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/sql_compile/* "$tmp/"
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
row_vs_grouped=('Type "S.row" = "Duckdb.Sql.row" is not compatible with type "S.grouped" = "Duckdb.Sql.grouped"')
grouped_vs_row=('Type "S.grouped" = "Duckdb.Sql.grouped" is not compatible with type "S.row" = "Duckdb.Sql.row"')
expect nonnull_op_nullable 'Type "Duckdb.Codec.nullable" is not compatible with type "Duckdb.Codec.non_null"'
expect null_op_nonnull 'Type "int64" is not compatible with type "'"'"'a option"'
expect where_nullable 'Type "bool option" is not compatible with type "bool"'
expect grouped_select_row "${row_vs_grouped[@]}"
expect having_row "${row_vs_grouped[@]}"
expect aggregate_in_where "${grouped_vs_row[@]}"
expect mixed_kinds "${grouped_vs_row[@]}"
expect grouped_from "${grouped_vs_row[@]}" 'Duckdb.Sql.body'
expect compare_types 'Type "string" is not compatible with type "int64"'
expect add_string 'Type "string" is not compatible with type "int64"'
expect add_float 'Type "float" is not compatible with type "int64"'
expect param_type 'Type "int32" is not compatible with type "int64"'
expect find_select '"Duckdb.Request.many"' '[< `One ]'
expect args_type 'type "string"' 'type "int64"'
expect args_arity '"unit D.Args.t"' "\"('a * 'b) D.Args.t\""
expect binder_arity 'Type "unit" is not compatible with type' 'Duckdb.Sql.Binders.t'
expect empty_select 'Type "unit" is not compatible with type' 'Duckdb.Sql.Exprs.t'
