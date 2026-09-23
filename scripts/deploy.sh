#!/usr/bin/env bash
# Deploy AgentENV to barkland-test: generate secrets once, apply the overlay, wait.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=agentenv-system
OVERLAY="$HERE/deploy/overlays/barkland-test"
K() { kubectl --context "$CTX" "$@"; }
mkdir -p "$OVERLAY/.secrets"
if [[ ! -s "$OVERLAY/.secrets/agentenv-auth.env" ]]; then
  # 64 hex chars: within AgentENV's 32-256 character API key bounds.
  printf 'AENV_API_KEY=%s\n' "$(openssl rand -hex 32)" > "$OVERLAY/.secrets/agentenv-auth.env"
  echo "generated API key in $OVERLAY/.secrets/agentenv-auth.env"
fi
if [[ ! -s "$OVERLAY/.secrets/sandbox-access-token-hash-seed" ]]; then
  openssl rand -hex 32 | tr -d '\n' > "$OVERLAY/.secrets/sandbox-access-token-hash-seed"
  echo "generated sandbox access-token seed"
fi
K apply -k "$OVERLAY"
K -n "$NS" rollout status deployment/agentenv-scheduler --timeout=300s
K -n "$NS" rollout status deployment/agentenv-gateway --timeout=300s
# The runtime downloads Firecracker, the kernel, the tools drive and overlaybd on first
# start (upstream's startupProbe allows 4 minutes); be generous here.
K -n "$NS" rollout status daemonset/agentenv-node --timeout=900s
K -n "$NS" get pods -o wide
echo
echo "API key: $HERE/scripts/get-api-key.sh"
echo "Access:  $HERE/scripts/port-forward.sh   (then curl -H \"X-API-Key: \$KEY\" http://localhost:8080/health)"
