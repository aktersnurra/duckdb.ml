#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prefix="$tmp/prefix"
python3 tools/setup_duckdb.py --prefix "$tmp/native" --archive .local/upstream/libduckdb-linux-amd64.zip
# Install FFI first; the safe package must not be present as an accidental source dependency.
stage1/run build -p duckdb-ffi --build-dir "$tmp/ffi-build"
stage1/run install --build-dir "$tmp/ffi-build" --prefix "$prefix" duckdb-ffi
test ! -d "$prefix/lib/duckdb"
test "$(sed -n 's/^requires = "\(.*\)"/\1/p' "$prefix/lib/duckdb-ffi/META")" = ""
local_dune() {
  # Deliberately set consumer variables AFTER the isolated runner's opam exec.
  stage1/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$prefix/lib:$root/_opam/lib" \
    LIBRARY_PATH="$tmp/native" LD_LIBRARY_PATH="$tmp/native" \
    "$root/_opam/bin/dune" "$@"
}
mkdir "$tmp/ffi-consumer"
printf '(lang dune 3.20)\n(name ffi_consumer)\n' > "$tmp/ffi-consumer/dune-project"
printf '(executable (name main) (libraries duckdb-ffi))\n' > "$tmp/ffi-consumer/dune"
cat > "$tmp/ffi-consumer/main.ml" <<'ML'
let () =
  let db = Duckdb_ffi.database_owner () in
  Fun.protect ~finally:(fun () -> Duckdb_ffi.finish_database_close db) (fun () ->
    Sys.with_async_exns (fun () ->
      Duckdb_ffi.open_database db "" 1 0 false;
      assert (Duckdb_ffi.database_status db = 0);
      Duckdb_ffi.close_database db));
  print_endline "installed duckdb-ffi alone: ok"
ML
local_dune build --root "$tmp/ffi-consumer"
LD_LIBRARY_PATH="$tmp/native" "$tmp/ffi-consumer/_build/default/main.exe"
# Build safe package with the FFI source package excluded, using the installation.
local_dune build -p duckdb --build-dir "$tmp/safe-build"
local_dune install --root "$root" --build-dir "$tmp/safe-build" --prefix "$prefix" duckdb
test "$(sed -n 's/^requires = "\(.*\)"/\1/p' "$prefix/lib/duckdb/META")" = "base duckdb-ffi threads"
mkdir "$tmp/safe-consumer"
printf '(lang dune 3.20)\n(name safe_consumer)\n' > "$tmp/safe-consumer/dune-project"
printf '(executable (name main) (libraries base duckdb))\n' > "$tmp/safe-consumer/dune"
cp examples/synchronous.ml "$tmp/safe-consumer/main.ml"
local_dune build --root "$tmp/safe-consumer"
LD_LIBRARY_PATH="$tmp/native" "$tmp/safe-consumer/_build/default/main.exe"
LD_LIBRARY_PATH="$tmp/native" ldd "$tmp/safe-consumer/_build/default/main.exe" | tee "$tmp/ldd.txt"
grep -F "$tmp/native/libduckdb.so" "$tmp/ldd.txt"
for package in duckdb duckdb-ffi; do
  if grep -F "$root" "$prefix/lib/$package/META" "$prefix/lib/$package/dune-package"; then
    echo 'source root leaked into installed package metadata'; exit 1
  fi
done
if readelf -d "$prefix/lib/stublibs/dllduckdb_ffi_stubs.so" | grep -E 'RPATH|RUNPATH'; then
  echo 'installed native stubs must not contain build-host rpaths'; exit 1
fi
echo 'install smoke: isolated FFI/safe package builds + external consumers + relocated native loader + scheduler-free dependency boundary=ok'
