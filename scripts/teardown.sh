#!/usr/bin/env bash
# Remove everything the overlay created, in an order that does not stall:
#   1. kill every sandbox (running and paused) through the gateway, because the runtime
#      pod's preStop hook waits until the node reports zero running sandboxes (up to the
#      3600 s grace period);
#   2. delete the runtime DaemonSet while the scheduler is still up, so the runtime's
#      shutdown can unregister from the scheduler instead of waiting on a vanished one;
#   3. delete the namespace.
# Node-local state under /var/lib/aenv on the runtime node and the loaded ublk_drv module
# are NOT removed (hostPath); see plans/decisions.md and scripts/clear-node-state.sh.
set -euo pipefail
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=agentenv-system
PORT=${LOCAL_PORT:-18099}
K() { kubectl --context "$CTX" "$@"; }
api() { curl -s --max-time 20 -H "X-API-Key: $KEY" "$@"; }
PF=""
cleanup() { if [[ -n "$PF" ]]; then kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true; fi; }
trap cleanup EXIT

if ! K get namespace "$NS" >/dev/null 2>&1; then
  echo "namespace $NS does not exist; nothing to tear down"; exit 0
fi

# 1. Kill sandboxes, if the gateway is reachable.
if K -n "$NS" get svc agentenv-gateway >/dev/null 2>&1 \
   && K -n "$NS" get secret agentenv-auth >/dev/null 2>&1; then
  KEY=$(K -n "$NS" get secret agentenv-auth -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')
  K -n "$NS" port-forward svc/agentenv-gateway "$PORT:8080" >/dev/null 2>&1 &
  PF=$!
  up=0
  for _ in $(seq 1 30); do
    if api -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" | grep -q '^20'; then up=1; break; fi
    sleep 1
  done
  if [[ $up == 1 ]]; then
    # v2 list, one state per query (the array parameter is finicky); union the IDs.
    list_ids() {
      for st in running paused; do
        api "http://127.0.0.1:$PORT/v2/sandboxes?state=$st"
        echo
      done | python3 -c 'import json,sys
ids=set()
for line in sys.stdin:
  line=line.strip()
  if not line: continue
  try:
    d=json.loads(line)
  except Exception:
    continue
  for s in (d if isinstance(d,list) else []):
    if s.get("sandboxID"): ids.add(s["sandboxID"])
print("\n".join(sorted(ids)))'
    }
    ids=$(list_ids | sed '/^$/d')
    if [[ -n "$ids" ]]; then
      echo "killing $(echo "$ids" | wc -l | tr -d ' ') sandbox(es) before teardown"
      while read -r id; do
        api -o /dev/null -w "  DELETE $id -> %{http_code}\n" -X DELETE "http://127.0.0.1:$PORT/sandboxes/$id"
      done <<< "$ids"
      for _ in $(seq 1 60); do
        [[ -z "$(list_ids | sed '/^$/d')" ]] && break
        sleep 1
      done
      left=$(list_ids | sed '/^$/d' | wc -l | tr -d ' ')
      [[ "$left" == 0 ]] || echo "WARNING: $left sandbox(es) still listed; the runtime's preStop drain will wait for them (up to 3600 s)" >&2
    else
      echo "no sandboxes to kill"
    fi
  else
    echo "gateway not reachable; skipping the sandbox kill step (teardown may wait for the preStop drain)" >&2
  fi
  cleanup; PF=""
fi

# 2. Runtime first, while the scheduler is still serving. `kubectl delete` returns when the
# DaemonSet object is gone; wait for its pod as well, which is where the preStop drain and
# the runtime's shutdown happen.
K -n "$NS" delete daemonset agentenv-node --ignore-not-found --wait=true --timeout=120s
K -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=agentenv-node --timeout=900s 2>/dev/null || true
# 3. Everything else.
K delete namespace "$NS" --ignore-not-found --wait=true --timeout=600s
echo "namespace $NS deleted. Left on the runtime node by design: /var/lib/aenv (deps, image"
echo "cache, snapshot store, paused sandboxes) and the ublk_drv module; see plans/decisions.md"
echo "and scripts/clear-node-state.sh."
