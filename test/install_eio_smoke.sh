#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .local/stage4e/installed
work=$(mktemp -d "$root/.local/stage4e/installed/eio.XXXXXX")
prefix="$work/prefix"
producer="$work/producer"
mkdir "$producer"
cp dune-project ./*.opam "$producer/"
cp -R lib "$producer/lib"
# The installed Eio package is independently produced: no Async source or
# package participates in any producer or consumer build.
rm -rf "$producer/lib/async"
rm -f "$producer/duckdb-async.opam"
test ! -d "$producer/lib/async"
test ! -f "$producer/duckdb-async.opam"
python3 - "$root" "$producer" <<'PY'
import hashlib, pathlib, sys
root, producer = map(pathlib.Path, sys.argv[1:])
for copied in sorted(producer.rglob('*')):
    if not copied.is_file(): continue
    relative = copied.relative_to(producer)
    assert copied.read_bytes() == (root / relative).read_bytes(), relative
    print(hashlib.sha256(copied.read_bytes()).hexdigest(), relative)
PY
local_dune() {
  tools/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    LIBRARY_PATH="$root/.deps/duckdb" LD_LIBRARY_PATH="$root/.deps/duckdb" \
    "$root/_opam/bin/dune" "$@"
}
producer_build() {
  tools/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    LIBRARY_PATH="$root/.deps/duckdb" LD_LIBRARY_PATH="$root/.deps/duckdb" \
    bash -c 'cd "$1"; shift; exec "$@"' bash "$producer" "$root/_opam/bin/dune" build "$@"
}
producer_build -p duckdb-ffi --build-dir _build-ffi
local_dune install --root "$producer" --build-dir _build-ffi --prefix "$prefix" duckdb-ffi
producer_build -p duckdb --build-dir _build-safe
local_dune install --root "$producer" --build-dir _build-safe --prefix "$prefix" duckdb
producer_build -p duckdb-eio --build-dir _build-eio
local_dune install --root "$producer" --build-dir _build-eio --prefix "$prefix" duckdb-eio
test "$(sed -n 's/^requires = "\(.*\)"/\1/p' "$prefix/lib/duckdb-eio/META")" = "base duckdb eio eio.unix threads"
mv "$producer" "$producer.hidden"
consumer="$work/consumer"
mkdir "$consumer"
printf '(lang dune 3.20)\n(name eio_installed_consumer)\n' >"$consumer/dune-project"
printf '(executable (name main) (libraries base eio_main duckdb duckdb-eio) (flags (:standard -extension-universe beta)))\n' >"$consumer/dune"
cp test/installed_eio/positive.mli.in "$consumer/main.mli"
cp test/installed_eio/positive.ml.in "$consumer/main.ml"
local_dune build --root "$consumer" --display verbose >"$work/positive-build.log" 2>&1
LD_LIBRARY_PATH="$root/.deps/duckdb" "$consumer/_build/default/main.exe"
python3 - "$root" "$work/positive-build.log" "$prefix" <<'PY'
import pathlib, shlex, sys
root, log, prefix = sys.argv[1:]
for line in pathlib.Path(log).read_text().splitlines():
    if 'ocamlc' not in line and 'ocamlopt' not in line: continue
    words = shlex.split(line)
    for i, word in enumerate(words[:-1]):
        if word == '-I':
            path = words[i + 1]
            assert '.private' not in path, path
            if path.startswith(root):
                assert path.startswith(prefix + '/lib/') or path.startswith(root + '/_opam/lib/'), path
print('installed compiler paths: prefix + pinned dependencies; no source/private CMI')
PY
for name in private_worker private_resource forge_pool borrowed_escape borrowed_domain; do
  cp "test/installed_eio/$name.ml.fail" "$consumer/main.ml"
  if local_dune build --root "$consumer" >"$work/$name.log" 2>&1; then
    echo "unexpected installed acceptance: $name"
    exit 1
  fi
  grep -Fq 'File "main.ml", line 1' "$work/$name.log"
done
grep -Fq 'Unbound module "Duckdb_eio__Worker_owner"' "$work/private_worker.log"
grep -Fq 'Unbound module "Duckdb__Resource"' "$work/private_resource.log"
grep -Fq 'type "unit"' "$work/forge_pool.log"
for name in borrowed_escape borrowed_domain; do
  grep -Fq 'chunk' "$work/$name.log"
  grep -Fq '"local"' "$work/$name.log"
done
grep -Fq '"global"' "$work/borrowed_escape.log"
grep -Fq '"global"' "$work/borrowed_domain.log"
for package in duckdb-ffi duckdb duckdb-eio; do
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
cp examples/eio.ml "$consumer/main.ml"
cp examples/eio.mli "$consumer/main.mli"
local_dune build --root "$consumer"
LD_LIBRARY_PATH="$root/.deps/duckdb" "$consumer/_build/default/main.exe"
echo "installed Eio: FFI/core/Eio independent installs, Async absent, producer hidden, public/private controls, META/native paths, no import startup and standalone example passed"
