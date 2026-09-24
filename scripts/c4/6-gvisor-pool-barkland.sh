#!/usr/bin/env bash
# gVisor (GKE Sandbox) pool for the agent-sandbox snapshot rows: same shape as the C2 comparison
# (4 x c2-standard-8). If regional CPU quota is short, scale kvm-pool-c4 to 0 first; run this
# only after scripts/c4/3-run-barkland.sh has finished. Pod Snapshots need a non-E2 family.
set -euo pipefail
P=gke-ai-eco-dev; C=barkland-test; Z=us-central1-a
echo "== $(date +%T) scale kvm-pool-c4 -> 0"
gcloud container clusters resize "$C" --project "$P" --zone "$Z" --node-pool kvm-pool-c4 --num-nodes 0 --quiet
echo "== $(date +%T) create gvisor-pool-c2"
gcloud container node-pools create gvisor-pool-c2 --cluster "$C" --project "$P" --zone "$Z" \
  --machine-type c2-standard-8 --num-nodes 4 --image-type cos_containerd --sandbox type=gvisor \
  --disk-type pd-ssd --disk-size 300 --enable-image-streaming \
  --node-labels bench=c2gvisor --no-enable-autoupgrade --quiet
kubectl --context "gke_${P}_${Z}_${C}" get nodes -l bench=c2gvisor -o wide
