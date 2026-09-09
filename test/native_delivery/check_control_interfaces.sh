#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/lib/ffi/duckdb_ffi.mli" "$tmp/"
cd "$tmp"
cat >control_publication.mli <<'EOF'
val commit : Duckdb_ffi.connection -> unit
val reserve : Duckdb_ffi.connection -> Duckdb_ffi.file_admission
val publish : Duckdb_ffi.connection -> Duckdb_ffi.local_file_work -> string -> string -> int
EOF
cat >control_publication.ml <<'EOF'
let commit c = Duckdb_ffi.execute_control c Duckdb_ffi.Commit
let reserve c = Duckdb_ffi.admit_local_file c
let publish c w s d = Duckdb_ffi.publish_local_file_admitted c w s d
EOF
"$compiler" -extension-universe beta -w @a -c duckdb_ffi.mli
"$compiler" -extension-universe beta -w @a -c control_publication.mli
"$compiler" -extension-universe beta -w @a -c control_publication.ml
for declaration in execute_control admit_local_file publish_local_file_admitted; do
 chmod u+w duckdb_ffi.mli
 cp "$root/lib/ffi/duckdb_ffi.mli" duckdb_ffi.mli
 sed -i "/^val $declaration :/d" duckdb_ffi.mli
 "$compiler" -extension-universe beta -w -a -c duckdb_ffi.mli
 "$compiler" -extension-universe beta -w @a -c control_publication.mli
 if "$compiler" -extension-universe beta -w @a -c control_publication.ml >red.out 2>&1; then
  echo "missing $declaration accepted"
  exit 1
 fi
 cat red.out
 grep -F 'File "control_publication.ml", line' red.out
 grep -F "Unbound value \"Duckdb_ffi.$declaration\"" red.out
done
echo 'control-publication: private interface positive and three source-specific missing declarations pass'
