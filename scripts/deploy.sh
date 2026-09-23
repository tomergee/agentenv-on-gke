#!/usr/bin/env bash
# Deploy AgentENV to barkland-test: reuse (or first create) the Secrets, apply the overlay,
# wait for the rollouts. Idempotent: re-running keeps the cluster's key and seed.
# ROTATE_SECRETS=1 generates new ones and restarts the gateway and runtime pods.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=agentenv-system
OVERLAY="$HERE/deploy/overlays/barkland-test"
SECRETS="$OVERLAY/.secrets"   # gitignored; never commit or print its contents
K() { kubectl --context "$CTX" "$@"; }

mkdir -p "$SECRETS"
K create namespace "$NS" --dry-run=client -o yaml | K apply -f - >/dev/null

# The cluster's Secrets are the source of truth. Several checkouts (worktrees, other
# machines) each keep their own gitignored .secrets/, and applying a different local key
# over a live deployment breaks every request: the gateway injects ITS copy of the key
# toward the nodes and only reads it at startup, so it kept the old key while the runtime
# pods restarted with the new one (2026-09-23). So: if a Secret exists in the cluster, pull
# it into .secrets/ and leave it alone; generate only when the cluster has none; rotate only
# on request (ROTATE_SECRETS=1), and then restart every consumer.
ROTATE=${ROTATE_SECRETS:-0}
restart_needed=0
if [[ "$ROTATE" != 1 ]] && K -n "$NS" get secret agentenv-auth >/dev/null 2>&1; then
  K -n "$NS" get secret agentenv-auth -o go-template='{{index .data "AENV_API_KEY" | base64decode}}' \
    | { read -r key; printf 'AENV_API_KEY=%s\n' "$key"; } > "$SECRETS/agentenv-auth.env"
  echo "using the API key already in Secret/agentenv-auth (synced to $SECRETS/)"
else
  # 64 hex chars: within AgentENV's 32-256 character API key bounds.
  printf 'AENV_API_KEY=%s\n' "$(openssl rand -hex 32)" > "$SECRETS/agentenv-auth.env"
  echo "generated a new API key in $SECRETS/agentenv-auth.env"
  K -n "$NS" create secret generic agentenv-auth \
    --from-env-file="$SECRETS/agentenv-auth.env" --dry-run=client -o yaml | K apply -f -
  restart_needed=1
fi
if [[ "$ROTATE" != 1 ]] && K -n "$NS" get secret agentenv-runtime-secrets >/dev/null 2>&1; then
  K -n "$NS" get secret agentenv-runtime-secrets \
    -o go-template='{{index .data "sandbox-access-token-hash-seed" | base64decode}}' \
    | tr -d '\n' > "$SECRETS/sandbox-access-token-hash-seed"
  echo "using the sandbox access-token seed already in Secret/agentenv-runtime-secrets"
else
  openssl rand -hex 32 | tr -d '\n' > "$SECRETS/sandbox-access-token-hash-seed"
  echo "generated a new sandbox access-token seed in $SECRETS/"
  K -n "$NS" create secret generic agentenv-runtime-secrets \
    --from-file=sandbox-access-token-hash-seed="$SECRETS/sandbox-access-token-hash-seed" \
    --dry-run=client -o yaml | K apply -f -
  restart_needed=1
fi

K apply -k "$OVERLAY"
if [[ "$restart_needed" == 1 ]]; then
  # Secret values are read at container start (env from secretKeyRef); the gateway and the
  # runtime both hold the API key, and the runtime holds the seed. Restart them so every
  # component agrees on the new values.
  echo "secrets changed: restarting the gateway and the runtime pods"
  K -n "$NS" rollout restart deployment/agentenv-gateway daemonset/agentenv-node >/dev/null 2>&1 || true
fi
K -n "$NS" rollout status deployment/agentenv-scheduler --timeout=300s
K -n "$NS" rollout status deployment/agentenv-gateway --timeout=300s
# The runtime downloads Firecracker, the kernel, the tools drive and overlaybd on first
# start (upstream's startupProbe allows 4 minutes); be generous here.
K -n "$NS" rollout status daemonset/agentenv-node --timeout=900s
K -n "$NS" get pods -o wide
cat <<MSG

Next:
  KEY=\$($HERE/scripts/get-api-key.sh)
  $HERE/scripts/port-forward.sh &      # gateway on http://127.0.0.1:8080
  curl -s -o /dev/null -w '%{http_code}\n' -H "X-API-Key: \$KEY" http://127.0.0.1:8080/health   # 204
MSG
