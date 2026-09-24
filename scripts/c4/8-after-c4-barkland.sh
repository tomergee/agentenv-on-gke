#!/usr/bin/env bash
# Chain after scripts/c4/3-run-barkland.sh on barkland-test:
#  1. AgentENV create reruns now that the C4 nodes' block caches are warm (the first matrix ran on
#     brand-new nodes), plus a second resume-100.
#  2. Release kvm-pool-c4 (quota), create the GKE Sandbox pool (4 x c2-standard-8), retrying while
#     the shared region is at its CPU ceiling.
#  3. The agent-sandbox snapshot phase on gVisor (scripts/c4/7-run-snapshots-barkland.sh).
set -u
cd "$(dirname "$0")/../.."
P=gke-ai-eco-dev; C=barkland-test; Z=us-central1-a; CTX="gke_${P}_${Z}_${C}"; K="kubectl --context $CTX --request-timeout=60s"
echo "== $(date +%T) waiting for the C4 phase to finish"
while pgrep -f "3-run-barkland.sh" >/dev/null; do sleep 30; done
echo "== $(date +%T) AgentENV warm-cache reruns"
for n in 1 10 100; do echo "=== create $n (warm caches)"; JOB_TIMEOUT_S=1800 tests/run-concurrency.sh create "$n" "c4-create-$n-warm" 2>&1 | tail -1 || true; done
echo "=== resume 100 (repeat)"; JOB_TIMEOUT_S=1800 tests/run-concurrency.sh resume 100 c4-resume-100-b 2>&1 | tail -1 || true
echo "== $(date +%T) release kvm-pool-c4 (scale to 0)"
gcloud container clusters resize "$C" --project "$P" --zone "$Z" --node-pool kvm-pool-c4 --num-nodes 0 --quiet 2>&1 | tail -1
for attempt in $(seq 1 12); do
  FREE=$(gcloud compute regions describe us-central1 --project "$P" --format=json 2>/dev/null | python3 -c 'import json,sys; q={x["metric"]:x for x in json.load(sys.stdin)["quotas"]}; print(int(q["CPUS"]["limit"]-q["CPUS"]["usage"]))')
  echo "== $(date +%T) attempt $attempt: free CPUs=$FREE"
  if [ "${FREE:-0}" -ge 32 ]; then
    if gcloud container node-pools create gvisor-pool-c2 --cluster "$C" --project "$P" --zone "$Z" \
        --machine-type c2-standard-8 --num-nodes 4 --image-type cos_containerd --sandbox type=gvisor \
        --disk-type pd-ssd --disk-size 300 --enable-image-streaming \
        --node-labels bench=c2gvisor --no-enable-autoupgrade --quiet 2>&1 | tail -2; then break; fi
  fi
  sleep 120
done
for i in $(seq 1 60); do n=$($K get nodes -l bench=c2gvisor --no-headers 2>/dev/null | grep -c " Ready"); [ "$n" -ge 4 ] && { echo "== $(date +%T) 4 gvisor nodes Ready"; break; }; sleep 10; done
$K get runtimeclass gvisor -o name 2>/dev/null || echo "WARNING: no gvisor RuntimeClass"
$K get nodes -l bench=c2gvisor -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type' --no-headers 2>/dev/null
echo "== $(date +%T) snapshot phase"
bash scripts/c4/7-run-snapshots-barkland.sh
echo "== $(date +%T) all done"
