#!/usr/bin/env bash
# Deploy AgentENV to barkland-test: generate secrets once, create them, apply the overlay,
# wait for the rollouts. Idempotent: re-running reuses the existing key and seed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
NS=agentenv-system
OVERLAY="$HERE/deploy/overlays/barkland-test"
SECRETS="$OVERLAY/.secrets"   # gitignored; never commit or print its contents
K() { kubectl --context "$CTX" "$@"; }

mkdir -p "$SECRETS"
if [[ ! -s "$SECRETS/agentenv-auth.env" ]]; then
  # 64 hex chars: within AgentENV's 32-256 character API key bounds.
  printf 'AENV_API_KEY=%s\n' "$(openssl rand -hex 32)" > "$SECRETS/agentenv-auth.env"
  echo "generated API key in $SECRETS/agentenv-auth.env"
fi
if [[ ! -s "$SECRETS/sandbox-access-token-hash-seed" ]]; then
  openssl rand -hex 32 | tr -d '\n' > "$SECRETS/sandbox-access-token-hash-seed"
  echo "generated sandbox access-token seed in $SECRETS/"
fi

# Secrets live outside kustomize so the overlay renders without them (see the overlay's
# kustomization.yaml). Create them before the workloads so pods never start with an
# empty key. The namespace comes from the base; create it first for the Secrets.
K create namespace "$NS" --dry-run=client -o yaml | K apply -f - >/dev/null
K -n "$NS" create secret generic agentenv-auth \
  --from-env-file="$SECRETS/agentenv-auth.env" --dry-run=client -o yaml | K apply -f -
K -n "$NS" create secret generic agentenv-runtime-secrets \
  --from-file=sandbox-access-token-hash-seed="$SECRETS/sandbox-access-token-hash-seed" \
  --dry-run=client -o yaml | K apply -f -

K apply -k "$OVERLAY"
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
