#!/usr/bin/env bash
# Sweep every converted SWE-bench Verified image through AgentENV in parallel and summarize.
# Usage: tests/sweep.sh            (env: PAR=8 GW=http://127.0.0.1:18120 LIST=build/convert/verified-instances.txt
#        OUT=tests/sweep-results.csv CPU=2 MEM=4096 RUN_TIMEOUT=900 SKIP_TAG_CHECK=0 RESUME=1)
# Only instances whose converted tag exists are run (unless SKIP_TAG_CHECK=1). With RESUME=1
# (default) instances already in $OUT are skipped, so the sweep can be re-run to fill gaps.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KCTX=${KCTX:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}; NS=${NS:-agentenv-system}
GW=${GW:-http://127.0.0.1:18120}; PY=${PY:-/tmp/aenv-test-venv/bin/python}; PAR=${PAR:-8}
LIST=${LIST:-$HERE/build/convert/verified-instances.txt}; OUT=${OUT:-$HERE/tests/sweep-results.csv}
SUMMARY=${SUMMARY:-$HERE/tests/sweep-summary.md}
IMG_REPO=${IMG_REPO:-us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified}
CPU=${CPU:-2}; MEM=${MEM:-4096}; RUN_TIMEOUT=${RUN_TIMEOUT:-900}; TESTS_DIR="$HERE/tests"
KEY=${KEY:-$("$HERE/scripts/get-api-key.sh")}
export GW KEY PY IMG_REPO OUT CPU MEM RUN_TIMEOUT TESTS_DIR
K() { kubectl --context "$KCTX" -n "$NS" "$@"; }
api() { curl -s -H "X-API-Key: $KEY" "$@"; }
PF_PID=""
cleanup() {
  # kill anything still alive (only sweep sandboxes exist during a sweep), then the port-forward
  for st in running paused; do
    api "$GW/v2/sandboxes?state=$st" | python3 -c 'import json,sys
try: [print(s["sandboxID"]) for s in json.load(sys.stdin)]
except Exception: pass' | while read -r id; do api -o /dev/null -X DELETE "$GW/sandboxes/$id"; done
  done
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
}
trap cleanup EXIT
if ! curl -s -o /dev/null --max-time 3 "$GW/health"; then
  K port-forward svc/agentenv-gateway "${GW##*:}:8080" >/tmp/sweep_pf.log 2>&1 & PF_PID=$!; sleep 3
fi
TODO=$(mktemp)
if [ "${SKIP_TAG_CHECK:-0}" = 1 ]; then sort -u "$LIST" > "$TODO"; else
  gcloud artifacts docker tags list "$IMG_REPO" --format='value(tag)' 2>/dev/null | grep -v -- '-src$' | sort -u > /tmp/sweep_tags.txt
  comm -12 <(sort -u "$LIST") /tmp/sweep_tags.txt > "$TODO"
fi
[ -s "$OUT" ] || echo "instance,status,http,create_s,cmd_s,total_s,note" > "$OUT"
if [ "${RESUME:-1}" = 1 ]; then
  cut -d, -f1 "$OUT" | tail -n +2 | sort -u > /tmp/sweep_done.txt
  comm -23 "$TODO" /tmp/sweep_done.txt > "$TODO.new" && mv "$TODO.new" "$TODO"
fi
N=$(grep -c . "$TODO"); echo "== sweep $(date -u +%FT%TZ): $N instance(s), parallel=$PAR, $CPU cpu / $MEM MB, gateway $GW"
xargs -P "$PAR" -n 1 "$HERE/tests/sweep-one.sh" < "$TODO"
python3 - "$OUT" "$SUMMARY" "$IMG_REPO" <<'PY'
import csv,sys,statistics
out,summary,repo=sys.argv[1:4]
rows=list(csv.DictReader(open(out)))
by={}; [by.setdefault(r["status"],[]).append(r) for r in rows]
def pct(vals,p):
    vals=sorted(vals); return vals[min(len(vals)-1,int(round(p/100*(len(vals)-1))))] if vals else float("nan")
ok=[r for r in rows if r["status"]=="pass"]
cr=[float(r["create_s"]) for r in ok]; cm=[float(r["cmd_s"]) for r in ok]
lines=[f"# Sweep summary ({len(rows)} instances)","",f"Image repo: `{repo}`, 2 CPU / 4096 MB per sandbox.","","| Status | Count |","|---|---|"]
lines+=[f"| {k} | {len(v)} |" for k,v in sorted(by.items())]
if ok:
    lines+=["","| Timing (pass only) | p50 | p90 | max |","|---|---|---|---|",
            f"| create to running | {pct(cr,50):.1f} s | {pct(cr,90):.1f} s | {max(cr):.1f} s |",
            f"| first command | {pct(cm,50):.1f} s | {pct(cm,90):.1f} s | {max(cm):.1f} s |"]
bad=[r for r in rows if r["status"]!="pass"]
if bad:
    lines+=["","## Failures","","| Instance | Status | HTTP | Note |","|---|---|---|---|"]
    lines+=[f"| {r['instance']} | {r['status']} | {r['http']} | {r['note'][:100]} |" for r in bad]
open(summary,"w").write("\n".join(lines)+"\n"); print("\n".join(lines[:12]))
PY
