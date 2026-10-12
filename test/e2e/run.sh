#!/bin/sh
# Self-driving end-to-end test: opens a window, runs frontend/test.js through
# `semut dev`, touches the backend mid-run to exercise rebuild + restart, and
# prints the results the page logs to the terminal.
set -eu
cd "$(dirname "$0")"
log=$(mktemp)
../../semut dev >"$log" 2>&1 &
pid=$!
touched=0
i=0
while kill -0 $pid 2>/dev/null && [ $i -lt 900 ]; do
  sleep 0.1; i=$((i+1))
  if [ $touched = 0 ] && grep -q E2E_RESTART_NOW "$log"; then
    touch backend/main.tov; touched=1
  fi
done
kill $pid 2>/dev/null || true
report=$(grep -o 'E2E_REPORT .*' "$log" | head -n 1 | cut -c12-)
[ -n "$report" ] || { echo "e2e: no report. log:"; cat "$log"; exit 1; }
printf '%s' "$report" | python3 -I -c '
import json,sys
r=json.load(sys.stdin); bad=[x for x in r if not x["ok"]]
for x in r: print(("PASS " if x["ok"] else "FAIL ")+x["name"]+(("  ("+x["detail"]+")") if x["detail"] else ""))
print(f"{len(r)-len(bad)}/{len(r)} passed"); sys.exit(1 if bad else 0)'
