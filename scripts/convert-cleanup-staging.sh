#!/usr/bin/env bash
# Delete the `<instance>-src` staging copies (standard-format images) left in the target
# repository by the conversion builds when their in-build delete failed. Safe to run any
# time: it only touches tags ending in -src whose converted twin exists.
set -uo pipefail
PROJECT=gke-ai-eco-dev
DST=us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified
tags=$(gcloud artifacts docker tags list "$DST" --project "$PROJECT" --format='value(tag)' 2>/dev/null)
n=0
for t in $(echo "$tags" | grep -- '-src$'); do
  base=${t%-src}
  if echo "$tags" | grep -qx "$base"; then
    gcloud artifacts docker images delete "$DST:$t" --project "$PROJECT" --delete-tags --quiet >/dev/null 2>&1 \
      && { n=$((n+1)); echo "deleted $t"; } || echo "could not delete $t"
  else
    echo "keeping $t (no converted twin yet)"
  fi
done
echo "deleted $n staging copies"
