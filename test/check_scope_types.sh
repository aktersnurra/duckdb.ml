#!/usr/bin/env bash
set -euo pipefail
compiler=$1
# The public interface names Base types (Base.Error.t); every compilation
# against the standalone duckdb.mli needs Base's interfaces.
export OCAMLPARAM="_,I=$(ocamlfind query base)"
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/../lib/duckdb/duckdb.mli" "$root"/scope_compile/* "$tmp/"
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
expect escape_return 'is "local" to the parent region'
expect escape_ref 'is "local" to the parent region'
expect escape_closure 'is "local" to the parent region'
expect prepared_escape 'is "local" to the parent region'
expect appender_escape 'is "local" to the parent region'
expect busy_fold 'is "local" to the parent region'
expect busy_transaction 'is "local" to the parent region'
expect busy_appender 'is "local" to the parent region'
expect effect_escape 'The value "tx" is "local" to the parent region'
expect busy_statement 'The value "p" is "local" to the parent region'
expect close_scoped 'This value is "local" to the parent region but is expected to be "global"'
expect bridge_twice 'already been used as unique'
echo 'scope types: positive forms and 12 intended rejections (escape, busy capture, effect continuation, scoped close, bridge request reuse)=ok'
