#!/usr/bin/env bash
# Standalone NON-PRODUCTION two-package fixture; never install into an opam switch.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
mode=${1:-green}
case "$mode" in green | interface-red | latch-red) ;; *) exit 2 ;; esac
base="$root/.local/package-fixtures"
mkdir -p "$base/logs"
work=$(mktemp -d "$base/$mode.XXXXXX")
printf '%s\n' "$work" >"$base/logs/$mode-work.txt"
prefix="$work/prefix"
mkdir -p "$work/core" "$work/consumer"
for project in core consumer; do
  for source in "test/adapter/package/$project/"*.in; do
    cp "$source" "$work/$project/$(basename "${source%.in}")"
  done
done
cat >"$work/core/dune-project" <<'DUNE'
(lang dune 3.20)
(name packaging-core)
(package (name packaging-core))
DUNE
cat >"$work/core/dune" <<'DUNE'
(library (name packaging_core) (public_name packaging-core)
 (private_modules resource) (libraries base))
DUNE
cat >"$work/consumer/dune-project" <<'DUNE'
(lang dune 3.20)
(name packaging-consumer)
(package (name packaging-consumer))
DUNE
cat >"$work/consumer/dune" <<'DUNE'
(executable (name main) (public_name packaging-consumer)
 (package packaging-consumer) (libraries base threads packaging-core))
DUNE
local_dune() {
  tools/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    "$root/_opam/bin/dune" "$@"
}
if [[ "$mode" == interface-red ]]; then
  rm -f "$work/core/resource.ml" "$work/core/packaging_core.ml"
  local_dune build --root "$work/core" --build-dir _build @install
  exit 0 # Unexpected success: callers checking the required exit 1 must fail.
fi
if [[ "$mode" == latch-red ]]; then
  # Mutate only the generated implementation, not the tracked source.
  sed -i 's/| Ok _ when request.cancelled -> Error Cancelled/| Ok _ when false -> Error Cancelled/' "$work/core/resource.ml"
fi
local_dune build --root "$work/core" --build-dir _build @install
local_dune install --root "$work/core" --build-dir _build --prefix "$prefix" packaging-core
# Hide BOTH producer source and build tree before compiling the external package.
mv "$work/core" "$work/core.hidden"
local_dune build --root "$work/consumer" --build-dir _build @install
local_dune install --root "$work/consumer" --build-dir _build --prefix "$prefix" packaging-consumer
timeout 30 "$prefix/bin/packaging-consumer"
# All negatives compile in the consumer project, with normal installed search paths.
cp "$work/consumer/main.ml" "$work/consumer/main.ml.saved"
for source in test/adapter/package/negative/*.ml.fail; do
  name=$(basename "$source" .ml.fail)
  cp "$source" "$work/consumer/main.ml"
  if local_dune build --root "$work/consumer" --build-dir _build @install >"$work/$name.out" 2>&1; then
    echo "unexpected compile success: $source"
    exit 1
  fi
  cat "$work/$name.out"
  grep -F 'File "main.ml", line 1' "$work/$name.out"
  grep -F "$(cat "$source")" "$work/$name.out"
  case "$name" in
  private_resource) grep -E 'Unbound module "?Packaging_core__Resource"?' "$work/$name.out" ;;
  public_resource) grep -E 'Unbound module "?Packaging_core\.Resource"?' "$work/$name.out" ;;
  forge_request)
    grep -F 'Packaging_core.Bridge.request' "$work/$name.out"
    grep -F 'unit' "$work/$name.out"
    ;;
  forge_pointer | extract_pointer)
    grep -F 'Packaging_core.connection' "$work/$name.out"
    grep -F 'nativeint' "$work/$name.out"
    ;;
  esac
done
mv "$work/consumer/main.ml.saved" "$work/consumer/main.ml"
local_dune build --root "$work/consumer" --build-dir _build @install
timeout 30 "$work/consumer/_build/default/main.exe"
test -f "$prefix/lib/packaging-core/.private/packaging_core__Resource.cmi"
test ! -f "$prefix/lib/packaging-core/packaging_core__Resource.cmi"
for file in META dune-package; do
  if grep -F -e "$work/core" -e "$root/test/adapter/package" -e "$root/_build" "$prefix/lib/packaging-core/$file"; then
    echo 'producer path leaked into installed metadata'
    exit 1
  fi
done
cat "$prefix/lib/packaging-core/META"
echo "packaging fixture: installed consumers + five source-specific negatives=ok; artifacts=$work"
