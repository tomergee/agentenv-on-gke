#!/usr/bin/env bash
# Forward the gateway Service to localhost:8080 (no TLS or ingress in the prototype).
set -euo pipefail
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
exec kubectl --context "$CTX" -n agentenv-system port-forward svc/agentenv-gateway "${LOCAL_PORT:-8080}:8080"
