#!/usr/bin/env bash
set -euo pipefail
executable=$1
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for mode in fail-heartbeat held-lock-negative; do
  set +e
  timeout 120 "$executable" heartbeat_result "--$mode" >"$log" 2>&1
  status=$?
  set -e
  cat "$log"
  test "$status" -eq 1
  grep -Fq 'negative cleanup joined: live=0 fallback=0 joins=1' "$log"
  case "$mode" in
  fail-heartbeat) grep -Fq 'injected heartbeat failure after true native entry' "$log" ;;
  held-lock-negative) grep -Fq 'ordinary cleanup no locked engine calls' "$log" ;;
  esac
  echo "PASS negative $mode: named assertion exit=1, released and joined; not timeout"
done
