#!/usr/bin/env bash
# agent-sandbox matrix on kvm-pool-c2 (4 x c2-standard-8). Without GKE image streaming the nodes'
# 100 GB disks cannot hold 25 distinct SWE images each, so the distinct-image modes stop at N=10
# here; run `DISTINCT100=1 run-matrix.sh` after enabling image streaming on the pool.
set -u
cd "$(dirname "$0")"
export JOB_TIMEOUT_S=3600
PFX=${LABEL_PREFIX:-}
run() { echo "=== $(date +%T) run $*"; ./run.sh "$1" "$2" "$PFX$3" 2>&1 | tail -1 || true; }
run warm-one 10  warm-one-10
run warm-one 100 warm-one-100
run warm-one 100 warm-one-100-b
run warm-one 1   warm-one-1-b
run warm-distinct 1  warm-distinct-1
run warm-distinct 10 warm-distinct-10
run cold-one 1   cold-one-1
run cold-one 10  cold-one-10
run cold-one 100 cold-one-100
run cold-one 100 cold-one-100-b
run cold-distinct 1  cold-distinct-1
run cold-distinct 10 cold-distinct-10
if [ "${DISTINCT100:-0}" = 1 ]; then
  run warm-distinct 100 warm-distinct-100
  run warm-distinct 100 warm-distinct-100-b
  run cold-distinct 100 cold-distinct-100
fi
echo "=== $(date +%T) matrix done"
