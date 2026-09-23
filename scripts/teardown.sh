#!/usr/bin/env bash
# Remove everything the overlay created. Node-local state under /var/lib/aenv on the
# runtime node (deps, image cache, paused sandboxes) is NOT removed; it is a hostPath.
set -euo pipefail
CTX=${KUBE_CONTEXT:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}
kubectl --context "$CTX" delete namespace agentenv-system --ignore-not-found --wait=true --timeout=600s
echo "namespace agentenv-system deleted; /var/lib/aenv on the kvm node is left in place"
