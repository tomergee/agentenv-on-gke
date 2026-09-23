#!/usr/bin/env bash
# Launch the overlaybd conversion of the SWE-bench Verified set as N async Cloud Build
# shards (default 10, within the 10-concurrent-builds quota). Re-running is safe: images
# already converted are skipped inside each shard.
#   scripts/convert-launch.sh [SHARDS]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARDS=${1:-10}
PROJECT=gke-ai-eco-dev REGION=us-central1
for s in $(seq 0 $((SHARDS-1))); do
  id=$(gcloud builds submit "$HERE/build/convert" --config "$HERE/build/convert/cloudbuild-convert.yaml" \
        --project "$PROJECT" --region "$REGION" --async --format='value(id)' \
        --substitutions "_SHARD=$s,_SHARDS=$SHARDS" 2>/dev/null)
  echo "shard $s/$SHARDS -> build $id"
done
echo "status: $HERE/scripts/convert-status.sh"
