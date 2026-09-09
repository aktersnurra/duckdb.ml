#!/usr/bin/env bash
set -euo pipefail
compiler=$1
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/lib/duckdb/"{scalar,resource}.mli "$root/lib/ffi/duckdb_ffi.mli" "$tmp/"
cd "$tmp"
"$compiler" -extension-universe beta -w @a -c scalar.mli
"$compiler" -extension-universe beta -w @a -c duckdb_ffi.mli
"$compiler" -extension-universe beta -w @a -c resource.mli
printf 'val cleanup : Resource.connection -> unit\n' >query_cleanup.mli
printf 'let cleanup connection = Resource.admit_cleanup connection\n' >query_cleanup.ml
"$compiler" -extension-universe beta -w @a -c query_cleanup.mli
"$compiler" -extension-universe beta -w @a -c query_cleanup.ml
chmod u+w resource.mli
sed -i '/^val admit_cleanup :/d' resource.mli
"$compiler" -extension-universe beta -w @a -c resource.mli
"$compiler" -extension-universe beta -w @a -c query_cleanup.mli
if "$compiler" -extension-universe beta -w @a -c query_cleanup.ml >red.out 2>&1; then
 echo 'missing admit_cleanup unexpectedly accepted'
 exit 1
fi
cat red.out
grep -F 'line 1, characters 25-47' red.out
grep -F 'Unbound value "Resource.admit_cleanup"' red.out
echo 'Query private cleanup interface: positive and source-specific missing declaration pass (body pre-exists)'
