#!/usr/bin/env bash
# C4 pass on barkland-test: AgentENV matrix (create, resume, template at 1/10/100), then the
# agent-sandbox matrix including the 100-distinct-image runs (image streaming + 300 GB disks).
# Results: tests/concurrency-results/c4-*.jsonl and tests/asbench/results/c4-*.jsonl.
set -u
cd "$(dirname "$0")/../.."
CTX=gke_gke-ai-eco-dev_us-central1-a_barkland-test; K="kubectl --context $CTX"
echo "== $(date +%T) waiting for AgentENV runtime pods on kvm-pool-c4"
for i in $(seq 1 60); do n=$($K -n agentenv-system get pods -l app=agentenv-node -o wide --no-headers 2>/dev/null | grep -c "kvm-pool-c4.*Running\|Running.*kvm-pool-c4"); r=$($K -n agentenv-system get pods -l app=agentenv-node --no-headers 2>/dev/null | grep -c "Running"); [ "$r" -ge 4 ] && { echo "agentenv node pods running: $r"; break; }; sleep 10; done
$K -n agentenv-system get pods -o wide --no-headers | awk '{print $1, $3, $7}' | head -8
ae() { echo "=== $(date +%T) agentenv $*"; JOB_TIMEOUT_S=1800 tests/run-concurrency.sh "$1" "$2" "c4-$3" 2>&1 | tail -1 || true; }
ae create 1 create-1; ae create 10 create-10; ae create 100 create-100; ae create 100 create-100-b
ae resume 1 resume-1; ae resume 10 resume-10; ae resume 100 resume-100
ae template 1 template-1; ae template 10 template-10; ae template 100 template-100; ae template 100 template-100-b
echo "=== $(date +%T) agent-sandbox matrix on kvm-pool-c4"
NODE_POOL=kvm-pool-c4 LABEL_PREFIX=c4- DISTINCT100=1 tests/asbench/run-matrix.sh 2>&1 | grep "^===\|FAILED\|timed out\|done in"
echo "== $(date +%T) barkland C4 pass done"
