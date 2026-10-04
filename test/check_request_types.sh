#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/request_compile/* "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c duckdb.mli
# Warning 45: [Fields.[...]] / [Args.[...]] literals intentionally shadow the
# list constructors through a local open (off in Dune's default set).
"$compiler" -extension-universe beta -w @a-45-70 -c positive.ml
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
expect find_zero '[ `Zero ]' '[< `One ]'
expect find_many '[ `Many | `One | `Zero ]' '[< `One ]'
expect find_opt_many '[ `Many | `One | `Zero ]' '[< `One | `Zero ]'
expect exec_one '[< `Zero ]' 'Type "int64" is not compatible with type "unit"'
expect param_type 'type "int"' 'type "string"'
expect param_missing '"unit D.Args.t"' '"(string * unit) D.Args.t"'
expect param_extra '"unit D.Args.t"' "\"('a * 'b) D.Args.t\""
expect param_tuple "\"'a * 'b\"" 'type "int64"'
expect null_required "\"'a option\"" 'type "int64"'
expect nested_nullable 'Duckdb.Codec.nullable' 'Duckdb.Codec.non_null'
expect custom_nullable_base 'Duckdb.Codec.nullable' 'Duckdb.Codec.non_null'
expect row_type 'values of type "string"' 'values of type "int64"'
expect row_arity_short 'type "int64"' "\"string -> 'a\""
expect forge_request 'Unbound record field "R.sql"'
expect forge_codec 'Unbound constructor "D.Codec.Non_null"'
expect append_type 'type "string"' 'type "int64"'
expect append_arity '"unit D.Args.t"' '"(string * unit) D.Args.t"'
expect append_other_table 'type "bool"' 'type "int64"'
expect append_cells '"D.cell"' 'type "int64"'
expect tx_instance_on_connection '"D.connection"' '"Duckdb.transaction"'
echo 'request types: positive forms and 20 intended rejections (multiplicity, arity, types, NULL, codecs, rows, forgery, tables, owners)=ok'
