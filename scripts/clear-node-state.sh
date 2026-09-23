#!/usr/bin/env bash
# Clear the node-local state that scripts/teardown.sh leaves on the runtime node:
# /var/lib/aenv (runtime deps, image cache, snapshot store, paused sandboxes, generated
# access-token seed) and the loaded ublk_drv module. Runs a one-shot privileged pod in a
# temporary namespace pinned to the kvm node, then removes that namespace. Refuses to run
# while agentenv-system exists (the runtime would be using the state).
set -euo pipefail
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=agentenv-cleanup
K() { kubectl --context "$CTX" "$@"; }
if K get namespace agentenv-system >/dev/null 2>&1; then
  echo "agentenv-system still exists; run scripts/teardown.sh first" >&2; exit 1
fi
K create namespace "$NS" --dry-run=client -o yaml | K apply -f - >/dev/null
trap 'K delete namespace "$NS" --ignore-not-found --wait=false >/dev/null' EXIT
K -n "$NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: clear-aenv-state
spec:
  restartPolicy: Never
  hostPID: true
  nodeSelector: {kvm: "true"}
  containers:
    - name: clear
      image: busybox:1.36
      securityContext: {privileged: true}
      command: ["sh", "-c"]
      args:
        - |
          set -u
          du -sh /host/var/lib/aenv 2>/dev/null || echo "/var/lib/aenv absent"
          rm -rf /host/var/lib/aenv && echo "removed /var/lib/aenv"
          if nsenter -t 1 -m -- sh -c '[ -d /sys/module/ublk_drv ]'; then
            nsenter -t 1 -m -- modprobe -r ublk_drv && echo "unloaded ublk_drv" || echo "ublk_drv busy; left loaded"
          else
            echo "ublk_drv not loaded"
          fi
      volumeMounts:
        - {name: host-var-lib, mountPath: /host/var/lib}
  volumes:
    - name: host-var-lib
      hostPath: {path: /var/lib, type: Directory}
YAML
K -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/clear-aenv-state --timeout=180s >/dev/null
K -n "$NS" logs clear-aenv-state
