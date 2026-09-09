#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .local/stage4b/installed
work=$(mktemp -d "$root/.local/stage4b/installed/bridge.XXXXXX")
prefix="$work/prefix"
producer="$work/producer"
mkdir "$producer"
cp dune-project ./*.opam "$producer/"
cp -R lib "$producer/lib"
# The pinned Dune private_dirs encoder requires a single-component relative
# build dir. Use the accepted packaging fixture's source-copy layout, not /tmp
# external builds or private include paths. Record exact source identity.
python3 - "$root" "$producer" <<'PY'
import hashlib, pathlib, sys
root, producer = map(pathlib.Path, sys.argv[1:])
for copied in sorted(producer.rglob('*')):
    if not copied.is_file(): continue
    relative = copied.relative_to(producer)
    assert copied.read_bytes() == (root / relative).read_bytes(), relative
    print(hashlib.sha256(copied.read_bytes()).hexdigest(), relative)
PY
echo "bridge installed evidence: $work"
# Keep disposable build/log trees for review; never overwrite the switch.
local_dune() {
  stage1/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    LIBRARY_PATH="$root/.deps/duckdb" LD_LIBRARY_PATH="$root/.deps/duckdb" \
    "$root/_opam/bin/dune" "$@"
}
producer_build() {
  stage1/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    LIBRARY_PATH="$root/.deps/duckdb" LD_LIBRARY_PATH="$root/.deps/duckdb" \
    bash -c 'cd "$1"; shift; exec "$@"' bash "$producer" "$root/_opam/bin/dune" build "$@"
}
producer_build -p duckdb-ffi --build-dir _build-ffi
local_dune install --root "$producer" --build-dir _build-ffi --prefix "$prefix" duckdb-ffi
test ! -d "$prefix/lib/duckdb"
test "$(sed -n 's/^requires = "\(.*\)"/\1/p' "$prefix/lib/duckdb-ffi/META")" = ""
producer_build -p duckdb --build-dir _build-safe
local_dune install --root "$producer" --build-dir _build-safe --prefix "$prefix" duckdb
test "$(sed -n 's/^requires = "\(.*\)"/\1/p' "$prefix/lib/duckdb/META")" = "base duckdb-ffi threads"
# Entire producer source and both build trees are unavailable at their previous
# paths during the independent consumer build, as in the packaging prerequisite.
mv "$producer" "$producer.hidden"
consumer="$work/consumer"
mkdir "$consumer"
printf '(lang dune 3.20)\n(name bridge_installed_consumer)\n' >"$consumer/dune-project"
printf '(executable (name main) (libraries base duckdb) (flags (:standard -extension-universe beta)))\n' >"$consumer/dune"
cp test/installed_adapter_bridge/positive.mli.in "$consumer/main.mli"
cp test/installed_adapter_bridge/positive.ml.in "$consumer/main.ml"
local_dune build --root "$consumer" --display verbose >"$work/positive-build.log" 2>&1
LD_LIBRARY_PATH="$root/.deps/duckdb" "$consumer/_build/default/main.exe"
# Audit actual compiler -I paths, not a claim based only on OCAMLPATH.
python3 - "$root" "$work/positive-build.log" "$prefix" <<'PY'
import pathlib, shlex, sys
root, log, prefix = sys.argv[1:]
for line in pathlib.Path(log).read_text().splitlines():
    if 'ocamlc' not in line and 'ocamlopt' not in line: continue
    words = shlex.split(line)
    for i, word in enumerate(words[:-1]):
        if word != '-I': continue
        path = words[i+1]
        assert '.private' not in path, path
        if path.startswith(root):
            assert path.startswith(prefix + '/lib/') or path.startswith(root + '/_opam/lib/'), path
print('installed compiler paths: prefix + pinned dependencies; no source/private CMI')
PY
for name in private_resource forge_request forge_pointer domain borrowed; do
  cp "test/installed_adapter_bridge/$name.ml.fail" "$consumer/main.ml"
  if local_dune build --root "$consumer" >"$work/$name.log" 2>&1; then
    echo "unexpected installed acceptance: $name"
    exit 1
  fi
  cat "$work/$name.log"
  grep -Fq 'File "main.ml", line 1' "$work/$name.log"
  case "$name" in
  private_resource)
    grep -Fq 'Duckdb__Resource.Bridge.create' "$work/$name.log"
    grep -Fq 'Unbound module "Duckdb__Resource"' "$work/$name.log"
    ;;
  forge_request)
    grep -Fq 'Duckdb.Bridge.cancel ()' "$work/$name.log"
    grep -Fq 'type "unit"' "$work/$name.log"
    grep -Fq '"Duckdb.Bridge.request"' "$work/$name.log"
    ;;
  forge_pointer)
    grep -Fq 'Nativeint.zero' "$work/$name.log"
    grep -Fq 'type "nativeint"' "$work/$name.log"
    grep -Fq '"Duckdb.connection"' "$work/$name.log"
    ;;
  domain)
    grep -Fq 'connection)' "$work/$name.log"
    grep -Fq 'expected to be "portable"' "$work/$name.log"
    grep -Fq 'expected to be "uncontended"' "$work/$name.log"
    ;;
  borrowed)
    grep -Fq 'chunk)' "$work/$name.log"
    grep -Fq '"local"' "$work/$name.log"
    grep -Fq '"global"' "$work/$name.log"
    ;;
  esac
done
cp test/installed_adapter_bridge/positive.ml.in "$consumer/main.ml"
local_dune build --root "$consumer"
LD_LIBRARY_PATH="$root/.deps/duckdb" "$consumer/_build/default/main.exe"
for package in duckdb duckdb-ffi; do
  # An absolute installed prefix is expected and itself lies under .local.
  # Remove only that exact allowed prefix before looking for producer/root paths.
  python3 - "$root" "$prefix" "$package" <<'PY'
import pathlib, sys
root, prefix, package = sys.argv[1:]
for name in ['META', 'dune-package']:
    text = (pathlib.Path(prefix) / 'lib' / package / name).read_text()
    assert root not in text.replace(prefix + '/lib/', 'INSTALLED/'), text
PY
done
if readelf -d "$prefix/lib/stublibs/dllduckdb_ffi_stubs.so" | grep -E 'RPATH|RUNPATH'; then
  echo 'installed stubs contain host rpath'
  exit 1
fi
LD_LIBRARY_PATH="$root/.deps/duckdb" ldd "$consumer/_build/default/main.exe" | tee "$work/ldd.log"
grep -F "$root/.deps/duckdb/libduckdb.so" "$work/ldd.log"
echo 'installed Bridge: independent FFI/safe installs, public transaction+owned fold, five intended negatives, scheduler-free META/startup=ok'
