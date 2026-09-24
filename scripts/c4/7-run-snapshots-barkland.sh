#!/usr/bin/env bash
# agent-sandbox on the GKE Sandbox (gVisor) pool: the snapshot rows plus a gVisor baseline.
# Runs after scripts/c4/3-run-barkland.sh (same asbench namespace and ConfigMap).
# Prereqs: scripts/c4/5-snapshot-prereqs.sh applied (bucket, IAM, storage config, policies) and
# gvisor-pool-c2 up (scripts/c4/6-gvisor-pool-barkland.sh or the inline create).
# Results: tests/asbench/results/gv-*.jsonl
set -u
cd "$(dirname "$0")/../.."
export NODE_POOL=gvisor-pool-c2 RUNTIME_CLASS=gvisor POD_SA=asbench-pods JOB_TIMEOUT_S=3600
CTX=gke_gke-ai-eco-dev_us-central1-a_barkland-test; K="kubectl --context $CTX"
echo "== $(date +%T) gvisor nodes:"; $K get nodes -l bench=c2gvisor --no-headers | awk '{print $1, $2}'
$K get podsnapshotstorageconfigs asbench-snapshots >/dev/null || { echo "storage config missing"; exit 1; }
run() { echo "=== $(date +%T) run $*"; tests/asbench/run.sh "$1" "$2" "gv-$3" 2>&1 | tail -1 || true; }
run warm-one 1 warm-one-1; run warm-one 10 warm-one-10; run warm-one 100 warm-one-100; run warm-one 100 warm-one-100-b
run cold-one 1 cold-one-1; run cold-one 10 cold-one-10; run cold-one 100 cold-one-100
run suspend 1 suspend-1; run suspend 10 suspend-10; run suspend 100 suspend-100
run golden 1 golden-1; run golden 10 golden-10; run golden 100 golden-100
run warm-distinct 10 warm-distinct-10; run cold-distinct 10 cold-distinct-10
echo "== $(date +%T) snapshot phase done"
