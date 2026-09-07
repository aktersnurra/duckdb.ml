#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/borrowed.mli" "$root/borrowed_ffi.mli" "$root"/experiments/* "$tmp/"
cd "$tmp"
compile() { "$compiler" -extension-universe beta -alert -do_not_spawn_domains -c "$1"; }
compile borrowed.mli
compile borrowed_ffi.mli
compile unique.mli
for f in positive unique_positive local_only effect_counterexample; do compile "$f.ml"; done
for f in return store capture domain owner_transition owner_reuse unique_destroy unique_reuse unique_closure inner_effect_escape; do
  cp "$f.ml.fail" "$f.ml"
  if compile "$f.ml" > "$f.out" 2>&1; then echo "UNEXPECTED ACCEPTANCE: $f"; exit 1; fi
  case "$f" in
    return|store|capture|inner_effect_escape|domain) grep -q 'local' "$f.out"; grep -q 'global\|escapes' "$f.out";;
    owner_*) grep -q 'Borrowed.view' "$f.out"; grep -q 'Borrowed_ffi.owner' "$f.out";;
    unique_destroy) grep -q 'being borrowed' "$f.out";;
    unique_reuse|unique_closure) grep -Eq 'used|unique' "$f.out";;
  esac
  echo "=== expected rejection: $f ==="; cat "$f.out"
done
echo 'modes: positive controls and 10 intended rejections passed'
