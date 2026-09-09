#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "$root/.local/stage4c/interfaces.XXXXXX")
export OCAMLPATH="$root/_build/install/default/lib:$root/_opam/lib"
compile() {
  "$root/_opam/bin/ocamlfind" ocamlc -thread -extension-universe beta -package async,duckdb -I "$out" -c "$@"
}
compile -o "$out/duckdb_async.cmi" "$root/lib/async/duckdb_async.mli"
for name in public_consumer owned; do
  compile -o "$out/$name.cmi" "$root/test/async/compile/$name.mli"
  compile -o "$out/$name.cmo" "$root/test/async/compile/$name.ml"
done
for name in borrowed deferred_callback domain forge_request private_worker private_resource; do
  cp "$root/test/async/compile/$name.ml.fail" "$out/$name.ml"
  if compile -o "$out/$name.cmo" "$out/$name.ml" >"$out/$name.log" 2>&1; then
    echo "unexpected acceptance: $name" >&2
    exit 1
  fi
  cat "$out/$name.log"
  grep -Fq "$name.ml" "$out/$name.log"
  case "$name" in
  borrowed)
    grep -Fq 'chunk' "$out/$name.log"
    grep -Fq '"local"' "$out/$name.log"
    grep -Fq '"global"' "$out/$name.log"
    ;;
  deferred_callback)
    grep -Fq 'Deferred.t' "$out/$name.log"
    grep -Fq 'result' "$out/$name.log"
    ;;
  domain)
    grep -Fq 'pool' "$out/$name.log"
    grep -Fq '"contended"' "$out/$name.log"
    grep -Fq '"uncontended"' "$out/$name.log"
    ;;
  forge_request)
    grep -Fq '"unit"' "$out/$name.log"
    grep -Fq 'Duckdb_async.request' "$out/$name.log"
    ;;
  private_worker) grep -Fq 'Unbound module "Duckdb_async__Worker_owner"' "$out/$name.log" ;;
  private_resource) grep -Fq 'Unbound module "Duckdb__Resource"' "$out/$name.log" ;;
  esac
done
echo "async interfaces: six source-specific negatives; paired public consumers and Ok(existing Deferred) limitation compile; $out"
