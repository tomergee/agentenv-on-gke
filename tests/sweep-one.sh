#!/usr/bin/env bash
# Run ONE converted SWE-bench Verified image through AgentENV: cold create from the
# overlaybd image, wait for running, run one command via the E2B SDK, kill. Appends one
# CSV line to $OUT: instance,status,http,create_s,cmd_s,total_s,note
# Env (set by sweep.sh): GW KEY PY IMG_REPO OUT CPU MEM RUN_TIMEOUT TESTS_DIR
set -uo pipefail
inst=$1
IMG="${IMG_REPO}:${inst}"
api() { curl -s -H "X-API-Key: $KEY" "$@"; }
now() { python3 -c 'import time; print(time.time())'; }
dt() { python3 -c "print(round($1 - $2, 2))"; }
jget() { python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')"; }
t0=$(now)
resp=$(api -m 300 -H 'Content-Type: application/json' \
  -d "{\"image\":\"$IMG\",\"cpuCount\":$CPU,\"memoryMB\":$MEM,\"timeout\":$RUN_TIMEOUT}" \
  -w '\n%{http_code}' "$GW/sandboxes-cold")
code=$(printf '%s' "$resp" | tail -1); body=$(printf '%s' "$resp" | sed '$d')
id=$(printf '%s' "$body" | jget sandboxID)
if [ -z "$id" ]; then
  echo "$inst,create_failed,$code,,,,$(printf '%s' "$body" | tr ',\n' '  ' | cut -c1-140)" >> "$OUT"; exit 0
fi
trap 'api -o /dev/null -X DELETE "$GW/sandboxes/$id"' EXIT
state=""
for _ in $(seq 1 180); do
  state=$(api "$GW/sandboxes/$id" | jget state); [ "$state" = "running" ] && break; sleep 1
done
t1=$(now)
if [ "$state" != "running" ]; then
  echo "$inst,not_running,$code,$(dt "$t1" "$t0"),,,state=$state" >> "$OUT"; exit 0
fi
errf=$(mktemp)
out=$(GW="$GW" KEY="$KEY" perl -e 'alarm 150; exec @ARGV' -- "$PY" "$TESTS_DIR/e2b_commands.py" run "$id" \
  'test -d /testbed && echo TESTBED_OK; python --version 2>&1 | head -1' 2>"$errf"); rc=$?
t2=$(now)
pyv=$(printf '%s' "$out" | grep -o -E 'Python [0-9.]+' | head -1)
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q TESTBED_OK; then
  echo "$inst,pass,$code,$(dt "$t1" "$t0"),$(dt "$t2" "$t1"),$(dt "$t2" "$t0"),$pyv" >> "$OUT"
else
  echo "$inst,cmd_failed,$code,$(dt "$t1" "$t0"),$(dt "$t2" "$t1"),$(dt "$t2" "$t0"),rc=$rc $(tail -c 120 "$errf" | tr ',\n' '  ')" >> "$OUT"
fi
rm -f "$errf"
