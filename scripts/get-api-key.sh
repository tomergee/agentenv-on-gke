#!/usr/bin/env bash
# Print the shared API key from the cluster Secret.
set -euo pipefail
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
kubectl --context "$CTX" -n agentenv-system get secret agentenv-auth -o go-template='{{index .data "AENV_API_KEY" | base64decode}}{{"\n"}}'
