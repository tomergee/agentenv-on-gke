#!/usr/bin/env bash
# Smoke test for the AgentENV prototype on barkland-test: AC-1..AC-10 from
# plans/acceptance-criteria.md. Prints one "AC-n PASS|FAIL: detail" line per criterion and a
# timing table. Every sandbox it creates is killed on exit, even on failure.
#
# Prerequisites: kubectl access to the cluster, curl, python3, bc, and the e2b SDK venv
# (uv venv /tmp/aenv-test-venv --python 3.12 && uv pip install --python /tmp/aenv-test-venv/bin/python e2b).
# A port-forward to the gateway is started if $GW does not answer.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KCTX=${KCTX:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=${NS:-agentenv-system}
GW=${GW:-http://127.0.0.1:8080}
PY=${PY:-/tmp/aenv-test-venv/bin/python}
IMAGE=${IMAGE:-ubuntu:22.04}
SBX_TIMEOUT=${SBX_TIMEOUT:-900}
POOL=${POOL:-kvm-pool-c2}
K() { kubectl --context "$KCTX" -n "$NS" "$@"; }
KEY=${KEY:-$("$HERE/scripts/get-api-key.sh")}
export GW KEY

CREATED=()
PF_PID=""
# timings (plain variables: macOS ships bash 3.2, no associative arrays)
T_create= T_rtt= T_pause= T_resume= T_fork= T_fork_call= T_warm= T_warm_concurrent=
FAILS=0
pass() { echo "AC-$1 PASS: $2"; }
fail() { echo "AC-$1 FAIL: $2"; FAILS=$((FAILS+1)); }
now() { date +%s.%N; }
since() { echo "$(now) - $1" | bc; }
api() { curl -s -H "X-API-Key: $KEY" "$@"; }
envd() { local id=$1; shift; curl -s -H "X-API-Key: $KEY" -H "e2b-sandbox-id: $id" -H "e2b-sandbox-port: 49983" "$@"; }
state() { api "$GW/sandboxes/$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("state"))
except Exception: print("?")'; }
wait_running() {  # id timeout_s -> seconds to running, or "" on timeout
  local id=$1 limit=${2:-600} s; s=$(now)
  while :; do
    [[ "$(state "$id")" == "running" ]] && { since "$s"; return 0; }
    (( $(echo "$(since "$s") > $limit" | bc) )) && return 1
    sleep 1
  done
}
wait_file() {  # id path timeout_s -> seconds until GET /files returns 200
  local id=$1 path=$2 limit=${3:-120} s; s=$(now)
  while :; do
    [[ "$(envd "$id" -o /tmp/smoke_file -w '%{http_code}' "$GW/files?path=$path")" == "200" ]] && { since "$s"; return 0; }
    (( $(echo "$(since "$s") > $limit" | bc) )) && return 1
    sleep 0.2
  done
}
create() {  # -> prints "<sandbox id> <POST duration s>"
  local s; s=$(now)
  api -X POST -H 'Content-Type: application/json' \
    -d "{\"image\":\"$IMAGE\",\"timeout\":$SBX_TIMEOUT,\"autoPause\":false,\"cpuCount\":1,\"memoryMB\":1024}" \
    -D /tmp/smoke_create.h "$GW/sandboxes-cold" > /tmp/smoke_create.json
  echo "$(python3 -c 'import json;print(json.load(open("/tmp/smoke_create.json")).get("sandboxID","none"))') $(since "$s")"
}
kill_all() {
  for id in "${CREATED[@]:-}"; do [[ -n "$id" ]] && api -o /dev/null -X DELETE "$GW/sandboxes/$id"; done
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
}
trap kill_all EXIT

# Port-forward if needed
if ! curl -s -o /dev/null --max-time 3 "$GW/health"; then
  K port-forward svc/agentenv-gateway "${GW##*:}:8080" >/tmp/smoke_pf.log 2>&1 &
  PF_PID=$!; sleep 3
fi

echo "== AgentENV smoke test $(date -u +%Y-%m-%dT%H:%M:%SZ) gateway=$GW image=$IMAGE"

# AC-1 pods Ready
PODS=$(K get pods -o wide --no-headers 2>/dev/null)
READY=$(echo "$PODS" | awk '$2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')
NODEPOD=$(echo "$PODS" | awk '/agentenv-node-/{print $1}' | head -1)
NODE=$(echo "$PODS" | awk '/agentenv-node-/{print $7}' | head -1)
NODEPOOL=$(kubectl --context "$KCTX" get node "$NODE" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-nodepool}' 2>/dev/null)
if [[ "$READY" == 3 && "$NODEPOOL" == "$POOL" ]]; then pass 1 "3/3 pods Ready; node pod $NODEPOD on $NODE ($NODEPOOL)"; else fail 1 "ready=$READY pool=$NODEPOOL"; echo "$PODS"; fi

# AC-2 health + nodes. The gateway lists nodes from the scheduler's heartbeat records, which
# lag up to a few minutes after a scheduler or runtime restart (RESULTS.md O-8), while
# scheduling itself keeps working; wait a bounded time for the node to appear.
HC=$(curl -s -o /dev/null -w '%{http_code}' "$GW/health")
NODES_WAIT=${NODES_WAIT:-300}
S_nodes=$(now); NODEID=""
while :; do
  NODES_JSON=$(api "$GW/nodes")
  NODEID=$(echo "$NODES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if len(d)==1 else "")' 2>/dev/null)
  [[ -n "$NODEID" ]] && break
  (( $(echo "$(since "$S_nodes") > $NODES_WAIT" | bc) )) && break
  sleep 5
done
T_nodes=$(since "$S_nodes")
DETAIL=$(api "$GW/nodes/$NODEID" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("metrics",{}); print("status=%s cpu=%s memGB=%s sandboxes=%s" % (d.get("status"), m.get("cpuCount"), round(m.get("memoryTotalBytes",0)/2**30,1), d.get("sandboxCount")))' 2>/dev/null)
if [[ "$HC" =~ ^20[04]$ && "$NODEID" == "$NODEPOD" && "$DETAIL" == status=ready* ]]; then pass 2 "/health $HC; /nodes -> $NODEID after ${T_nodes}s; $DETAIL"; else fail 2 "health=$HC nodes=$NODEID (waited ${T_nodes}s of ${NODES_WAIT}s) detail=$DETAIL"; fi

# AC-3 cold create
read -r ID CREATE_T < <(create); CREATED+=("$ID")
HTTP=$(head -1 /tmp/smoke_create.h | awk '{print $2}')
HDR=$(grep -i '^x-agentenv-sandbox-id' /tmp/smoke_create.h | tr -d '\r' | awk '{print $2}')
T_create=$(wait_running "$ID" 600) && RUN_OK=1 || RUN_OK=0
T_create=$(echo "${T_create:-0} + $CREATE_T" | bc)
if [[ "$HTTP" == 201 && "$RUN_OK" == 1 && "$HDR" == "$ID" ]]; then pass 3 "201, id=$ID, running after ${T_create} s (POST ${CREATE_T} s)"; else fail 3 "http=$HTTP id=$ID hdr=$HDR running=$RUN_OK state=$(state "$ID")"; K logs ds/agentenv-node --tail=60; fi

# AC-4 command through the gateway (E2B SDK, directly constructed; see e2b_commands.py)
OUT=$("$PY" "$HERE/tests/e2b_commands.py" run "$ID" 'echo hello-from-agentenv && uname -r && head -1 /etc/os-release' 2>/tmp/smoke_sdk.err); RC=$?
T_rtt=$("$PY" "$HERE/tests/e2b_commands.py" rtt "$ID" 2>/dev/null)
GUEST_KERNEL=$(echo "$OUT" | sed -n 2p)
"$PY" "$HERE/tests/e2b_commands.py" write "$ID" /root/marker.txt "marker-$(date +%s)" 2>>/tmp/smoke_sdk.err
MARKER=$(envd "$ID" "$GW/files?path=/root/marker.txt")
if [[ $RC == 0 && "$OUT" == *hello-from-agentenv* && -n "$MARKER" ]]; then pass 4 "SDK exit 0; guest kernel $GUEST_KERNEL; $(echo "$OUT" | sed -n 3p); marker=$MARKER; echo rtt ${T_rtt} s"; else fail 4 "rc=$RC out=$OUT err=$(tail -3 /tmp/smoke_sdk.err)"; fi

# AC-5 pause
s=$(now); PC=$(api -o /dev/null -w '%{http_code}' -X POST "$GW/sandboxes/$ID/pause"); T_pause=$(since "$s")
PAUSED=$(api "$GW/v2/sandboxes?state=paused" | python3 -c 'import json,sys; print(",".join(x["sandboxID"] for x in json.load(sys.stdin)))')
RUNNING=$(api "$GW/v2/sandboxes?state=running" | python3 -c 'import json,sys; print(",".join(x["sandboxID"] for x in json.load(sys.stdin)))')
if [[ "$PC" == 204 && "$PAUSED" == *"$ID"* && "$RUNNING" != *"$ID"* ]]; then pass 5 "204 in ${T_pause} s; listed paused, not running"; else fail 5 "code=$PC paused=$PAUSED running=$RUNNING"; fi

# AC-6 resume with state
s=$(now); api -D /tmp/smoke_resume.h -X POST -H 'Content-Type: application/json' -d "{\"timeout\":$SBX_TIMEOUT}" "$GW/sandboxes/$ID/resume" > /tmp/smoke_resume.json
RC6=$(head -1 /tmp/smoke_resume.h | awk '{print $2}'); RID=$(python3 -c 'import json;print(json.load(open("/tmp/smoke_resume.json")).get("sandboxID",""))')
wait_file "$ID" /root/marker.txt 120 >/dev/null; T_resume=$(since "$s"); MARKER2=$(cat /tmp/smoke_file)
CMD6=$("$PY" "$HERE/tests/e2b_commands.py" run "$ID" 'echo alive-after-resume' 2>/dev/null)
if [[ "$RC6" == 201 && "$RID" == "$ID" && "$MARKER2" == "$MARKER" && "$CMD6" == *alive-after-resume* && "$(state "$ID")" == running ]]; then pass 6 "201 same id; marker intact ($MARKER2); first read ${T_resume} s after POST; command ok"; else fail 6 "code=$RC6 rid=$RID marker=$MARKER2 cmd=$CMD6 state=$(state "$ID")"; fi

# AC-7 fork
s=$(now); api -D /tmp/smoke_fork.h -X POST -H 'Content-Type: application/json' -d "{\"count\":2,\"timeout\":$SBX_TIMEOUT}" "$GW/sandboxes/$ID/fork" > /tmp/smoke_fork.json; T_fork_call=$(since "$s")
KIDS=(); while IFS= read -r line; do KIDS+=("$line"); done < <(python3 -c 'import json
for e in json.load(open("/tmp/smoke_fork.json")):
    print(e.get("sandbox",{}).get("sandboxID","ERR:"+str(e.get("error"))))')
CREATED+=("${KIDS[@]}")
FORK_OK=1; for k in "${KIDS[@]}"; do [[ "$k" == ERR:* || "$k" == "$ID" ]] && FORK_OK=0; done; [[ ${#KIDS[@]} == 2 && "${KIDS[0]}" != "${KIDS[1]}" ]] || FORK_OK=0
if [[ $FORK_OK == 1 ]]; then
  wait_file "${KIDS[0]}" /root/marker.txt 120 >/dev/null; MA=$(cat /tmp/smoke_file)
  wait_file "${KIDS[1]}" /root/marker.txt 120 >/dev/null; MB=$(cat /tmp/smoke_file)
  T_fork=$(since "$s")
  WA=$(envd "${KIDS[0]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/octet-stream' --data-binary 'from-child-a' "$GW/files?path=/root/child-a.txt")
  ISO_B=$(envd "${KIDS[1]}" -o /dev/null -w '%{http_code}' "$GW/files?path=/root/child-a.txt")
  ISO_P=$(envd "$ID" -o /dev/null -w '%{http_code}' "$GW/files?path=/root/child-a.txt")
  CMDB=$("$PY" "$HERE/tests/e2b_commands.py" run "${KIDS[1]}" 'hostname; echo child-b-ok' 2>/dev/null | tail -1)
  if [[ "$MA" == "$MARKER" && "$MB" == "$MARKER" && "$WA" == 200 && "$ISO_B" == 404 && "$ISO_P" == 404 && "$CMDB" == child-b-ok && "$(state "$ID")" == running ]]; then
    pass 7 "2 children (${KIDS[0]:0:8}, ${KIDS[1]:0:8}); call ${T_fork_call} s, both answering ${T_fork} s; marker inherited; child writes isolated; parent still running"
  else fail 7 "markers=$MA/$MB writeA=$WA isoB=$ISO_B isoP=$ISO_P cmdB=$CMDB parent=$(state "$ID")"; fi
else fail 7 "fork response: $(cat /tmp/smoke_fork.json | head -c 300)"; fi

# AC-8 kill
KILL_OK=1; for x in "$ID" "${KIDS[@]}"; do [[ "$x" == ERR:* ]] && continue; c=$(api -o /dev/null -w '%{http_code}' -X DELETE "$GW/sandboxes/$x"); [[ "$c" == 204 ]] || KILL_OK=0; done
LIST=$(api "$GW/v2/sandboxes" | python3 -c 'import json,sys; print(",".join(x["sandboxID"] for x in json.load(sys.stdin)))')
G404=$(api -o /dev/null -w '%{http_code}' "$GW/sandboxes/$ID")
for x in "$ID" "${KIDS[@]}"; do [[ "$LIST" == *"$x"* ]] && KILL_OK=0; done
if [[ $KILL_OK == 1 && "$G404" == 404 ]]; then pass 8 "3 deletes 204; none listed; GET parent 404"; else fail 8 "kill_ok=$KILL_OK list=$LIST get=$G404"; fi
CREATED=()

# AC-10 warm second create (+ a create while another is running)
read -r ID2 CREATE_T < <(create); CREATED+=("$ID2"); T_warm=$(wait_running "$ID2" 300); T_warm=$(echo "${T_warm:-0} + $CREATE_T" | bc)
read -r ID3 CREATE_T < <(create); CREATED+=("$ID3"); T_warm_concurrent=$(wait_running "$ID3" 300); T_warm_concurrent=$(echo "${T_warm_concurrent:-0} + $CREATE_T" | bc)
if [[ "$(state "$ID2")" == running && "$(state "$ID3")" == running ]]; then pass 10 "second create running after ${T_warm} s; a third created while the second was running after ${T_warm_concurrent} s"; else fail 10 "states $(state "$ID2") $(state "$ID3")"; fi
for x in "$ID2" "$ID3"; do api -o /dev/null -X DELETE "$GW/sandboxes/$x"; done; CREATED=()

# AC-9 timing table
echo
echo "| Step | Seconds | Method |"
echo "|---|---|---|"
echo "| Cold create to running (AC-3) | ${T_create} | POST duration + 1 s polling to first state=running |"
echo "| Command round-trip (AC-4) | ${T_rtt} | one echo via the E2B SDK (envd process API through the gateway) |"
echo "| Pause (AC-5) | ${T_pause} | POST duration |"
echo "| Resume to first read (AC-6) | ${T_resume} | POST to first successful GET /files of the marker (0.2 s polling) |"
echo "| Fork of 2 to both answering (AC-7) | ${T_fork} | POST (call itself ${T_fork_call} s) to both children serving the marker |"
echo "| Warm second create (AC-10) | ${T_warm} | same as AC-3 with the image already converted |"
echo "| Node listed by the gateway (AC-2) | $T_nodes | seconds until GET /nodes returned the node (0 when immediate) |"
echo "| Create while another runs (AC-10) | ${T_warm_concurrent} | same |"
[[ -n "${T_create}" && -n "${T_rtt}" && -n "${T_pause}" && -n "${T_resume}" && -n "${T_fork}" && -n "${T_warm}" ]] && pass 9 "all timing rows recorded" || fail 9 "a timing is missing"
echo
echo "sandboxes left: $(api "$GW/v2/sandboxes")"
echo "== failures: $FAILS"
exit $(( FAILS > 0 ))
