#!/usr/bin/env bash
# Run tests/concurrency.py as an in-cluster Job and save its output.
#   tests/run-concurrency.sh MODE N [LABEL]        MODE = create | resume | template | fill
# Env: CPU (2), MEM (2048), FILL_TOTAL (400), FILL_BATCH (40), CTX, INSTANCES_FILE, JOB_TIMEOUT_S (1800).
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=$1; N=$2; LABEL=${3:-$MODE-$N}
CPU=${CPU:-2}; MEM=${MEM:-2048}; FILL_TOTAL=${FILL_TOTAL:-400}; FILL_BATCH=${FILL_BATCH:-40}
CTX=${CTX:-gke_gke-ai-eco-dev_us-central1-a_barkland-test}; K="kubectl --context $CTX -n agentenv-system"
INST=${INSTANCES_FILE:-tests/concurrency-instances.txt}
$K create configmap agentenv-concurrency --from-file=concurrency.py=tests/concurrency.py --from-file=instances.txt="$INST" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
job="agentenv-concurrency-$MODE-$N"
$K delete job "$job" --ignore-not-found --wait=true >/dev/null
sed "s/__N__/$N/; s/__LABEL__/$LABEL/; s/__MODE__/$MODE/; s/__CPU__/$CPU/; s/__MEM__/$MEM/; s/__FILL_TOTAL__/$FILL_TOTAL/; s/__FILL_BATCH__/$FILL_BATCH/" \
  tests/concurrency-job.yaml | $K apply -f - >/dev/null
t0=$(date +%s)
while :; do
  st=$($K get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)
  case "$st" in
    1/*) echo "$job: done in $(( $(date +%s) - t0 )) s"; break;;
    */1) echo "$job: FAILED"; $K logs "job/$job" | tail -20; exit 1;;
  esac
  if (( $(date +%s) - t0 > ${JOB_TIMEOUT_S:-1800} )); then echo "$job: timed out"; exit 1; fi
  sleep 5
done
mkdir -p tests/concurrency-results
$K logs "job/$job" | grep '^{' > "tests/concurrency-results/$LABEL.jsonl"
$K delete job "$job" --ignore-not-found >/dev/null
echo "results: tests/concurrency-results/$LABEL.jsonl"
