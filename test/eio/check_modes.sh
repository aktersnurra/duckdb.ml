#!/usr/bin/env bash
set -euo pipefail
root=${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
temporary_root="$root/.local/test-eio"
mkdir -p "$temporary_root"
out=$(mktemp -d "$temporary_root/compiler-modes.XXXXXX")
trap 'rm -rf "$out"' EXIT
export OCAMLPATH="$root/_build/install/default/lib:$root/_opam/lib"
compile() {
  "$root/_opam/bin/ocamlfind" ocamlc -thread -extension-universe beta \
    -package eio,duckdb,duckdb-eio -I "$out" -c "$@"
}
compile -o "$out/owned.cmi" "$root/test/eio/compile/owned.mli"
compile -o "$out/owned.cmo" "$root/test/eio/compile/owned.ml"
for name in borrowed_escape borrowed_domain forge_pool private_worker private_resource; do
  cp "$root/test/eio/compile/$name.ml.fail" "$out/$name.ml"
  if compile -o "$out/$name.cmo" "$out/$name.ml" >"$out/$name.log" 2>&1; then
    echo "unexpected Eio mode acceptance: $name" >&2
    exit 1
  fi
  cat "$out/$name.log"
  grep -Fq "$name.ml" "$out/$name.log"
  case "$name" in
  borrowed_escape)
    grep -Fq 'chunk' "$out/$name.log"
    grep -Fq '"local"' "$out/$name.log"
    grep -Fq '"global"' "$out/$name.log"
    ;;
  borrowed_domain)
    grep -Fq 'chunk' "$out/$name.log"
    grep -Fq '"local"' "$out/$name.log"
    grep -Fq '"global"' "$out/$name.log"
    ;;
  forge_pool) grep -Fq 'type "unit"' "$out/$name.log" ;;
  private_worker) grep -Fq 'Unbound module "Duckdb_eio__Worker_owner"' "$out/$name.log" ;;
  private_resource) grep -Fq 'Unbound module "Duckdb__Resource"' "$out/$name.log" ;;
  esac
done
echo "Eio modes: owned transaction result compiles; borrowed callback escape/domain handoff and private/opaque forgeries reject"
