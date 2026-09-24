#!/usr/bin/env bash
# tests/asbench/run.sh MODE N [LABEL]    MODE = warm-one | warm-distinct | cold-one | cold-distinct
# Env: CTX, KEEP (1 keeps pools/templates between runs), JOB_TIMEOUT_S (3600), IMAGES_TSV, NODE_POOL (kvm-pool-c2).
set -euo pipefail
cd "$(dirname "$0")"
MODE=$1; N=$2; LABEL=${3:-$MODE-$N}; KEEP=${KEEP:-0}; NODE_POOL=${NODE_POOL:-kvm-pool-c2}; RUNTIME_CLASS=${RUNTIME_CLASS:-}; POD_SA=${POD_SA:-}
CTX=${CTX:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}; K="kubectl --context $CTX --request-timeout=60s"
$K apply -f rbac.yaml >/dev/null
$K -n asbench create configmap asbench --from-file=asbench.py --from-file=images.tsv="${IMAGES_TSV:-images.tsv}" --dry-run=client -o yaml | $K apply -f - >/dev/null
job="asbench-$MODE-$N"; $K -n asbench delete job "$job" --ignore-not-found --wait=true >/dev/null
sed "s/__MODE__/$MODE/g; s/__N__/$N/g; s/__LABEL__/$LABEL/g; s/__KEEP__/$KEEP/g; s/__NODE_POOL__/$NODE_POOL/g; s/__RUNTIME_CLASS__/$RUNTIME_CLASS/g; s/__POD_SA__/$POD_SA/g" job.yaml.tmpl | $K apply -f - >/dev/null
t0=$(date +%s)
while :; do
  st=$($K -n asbench get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)
  case "$st" in 1/*) echo "$job: done in $(( $(date +%s) - t0 )) s"; break;; */1) echo "$job: FAILED"; $K -n asbench logs "job/$job" | tail -20; exit 1;; esac
  if (( $(date +%s) - t0 > ${JOB_TIMEOUT_S:-3600} )); then echo "$job: timed out"; exit 1; fi; sleep 5
done
mkdir -p results; $K -n asbench logs "job/$job" | grep '^{' > "results/$LABEL.jsonl"; $K -n asbench delete job "$job" --ignore-not-found >/dev/null
echo "results: results/$LABEL.jsonl"
