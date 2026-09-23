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
cleanup() { [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }
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
    list_ids() {
      api "http://127.0.0.1:$PORT/v2/sandboxes?state=running,paused" \
        | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
except Exception:
  d=[]
print("\n".join(s.get("sandboxID","") for s in (d if isinstance(d,list) else [])))'
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
    else
      echo "no sandboxes to kill"
    fi
  else
    echo "gateway not reachable; skipping the sandbox kill step (teardown may wait for the preStop drain)" >&2
  fi
  cleanup; PF=""
fi

# 2. Runtime first, while the scheduler is still serving.
K -n "$NS" delete daemonset agentenv-node --ignore-not-found --wait=true --timeout=900s
# 3. Everything else.
K delete namespace "$NS" --ignore-not-found --wait=true --timeout=600s
echo "namespace $NS deleted. Left on the runtime node by design: /var/lib/aenv (deps, image"
echo "cache, snapshot store, paused sandboxes) and the ublk_drv module; see plans/decisions.md"
echo "and scripts/clear-node-state.sh."
