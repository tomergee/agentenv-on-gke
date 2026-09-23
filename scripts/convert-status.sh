#!/usr/bin/env bash
# Progress of the SWE-bench Verified overlaybd conversion: converted tags vs the list, and
# the conversion builds' states.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT=gke-ai-eco-dev REGION=us-central1
DST=us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified
want=$(grep -c . "$HERE/build/convert/verified-instances.txt")
tags=$(gcloud artifacts docker tags list "$DST" --project "$PROJECT" --format='value(tag)' 2>/dev/null)
done_n=$(echo "$tags" | grep -c '^sweb\.eval\.' | tr -d ' ')
staging=$(echo "$tags" | grep -c -- '-src$' | tr -d ' ')
converted=$(( done_n - staging ))
echo "converted: $converted / $want   (staging copies in flight: $staging)"
echo "--- conversion builds (last 24h):"
gcloud builds list --project "$PROJECT" --region "$REGION" --filter='substitutions._DST_REPO~agentenv-images' \
  --format='table(id,status,createTime.date(tz=UTC),duration,substitutions._SHARD,substitutions._INSTANCES)' 2>/dev/null | head -20
echo "--- missing (first 10):"
comm -23 <(sort "$HERE/build/convert/verified-instances.txt") <(echo "$tags" | grep '^sweb\.eval\.' | grep -v -- '-src$' | sort) | head -10
