#!/usr/bin/env bash
# Build the AgentENV gateway and scheduler images with Cloud Build from an upstream
# checkout at the pinned tag. Upstream publishes only the runtime image.
#   AGENTENV_SRC=/tmp/AgentENV-v0.2.2 ./scripts/build-images.sh
set -euo pipefail
PROJECT=${PROJECT:-gke-ai-eco-dev}
REGION=${REGION:-us-central1}
TAG=${TAG:-v0.2.2}
SRC=${AGENTENV_SRC:-/tmp/AgentENV-v0.2.2}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$SRC/services" && -d "$SRC/deploy/docker" ]] || { echo "AGENTENV_SRC=$SRC lacks services/ or deploy/docker/" >&2; exit 1; }
# Trimmed context: the Go services and the Dockerfiles are all these builds need.
CTX="$(mktemp -d)"; trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/deploy" && cp -R "$SRC/services" "$CTX/services" && cp -R "$SRC/deploy/docker" "$CTX/deploy/docker"
gcloud builds submit "$CTX" --config "$HERE/build/cloudbuild.yaml" --project "$PROJECT" --region "$REGION" \
  --substitutions "_TAG=$TAG,_REGISTRY=${REGION}-docker.pkg.dev/${PROJECT}/agentenv"
