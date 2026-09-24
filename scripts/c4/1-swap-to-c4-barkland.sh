#!/usr/bin/env bash
# barkland-test: replace kvm-pool-c2 (4 x c2-standard-8) with kvm-pool-c4 (4 x c4-standard-8, nested
# virtualization, 300 GB Hyperdisk Balanced with provisioned IOPS/throughput, image streaming).
# Regional CPU quota is full, so the C2 pool is scaled to 0 first (kept for rollback).
# AgentENV's DaemonSet follows the kvm=true label onto the new pool; its node-local caches,
# templates and paused sandboxes on the C2 nodes are lost (the harness rebuilds the template).
set -euo pipefail
P=gke-ai-eco-dev; C=barkland-test; Z=us-central1-a
echo "== $(date +%T) scale kvm-pool-c2 -> 0"
gcloud container clusters resize "$C" --project "$P" --zone "$Z" --node-pool kvm-pool-c2 --num-nodes 0 --quiet
echo "== $(date +%T) create kvm-pool-c4"
gcloud container node-pools create kvm-pool-c4 --cluster "$C" --project "$P" --zone "$Z" \
  --machine-type c4-standard-8 --num-nodes 4 --image-type COS_CONTAINERD \
  --disk-type hyperdisk-balanced --disk-size 300 \
  --boot-disk-provisioned-iops 6000 --boot-disk-provisioned-throughput 600 \
  --enable-nested-virtualization --enable-image-streaming \
  --node-labels kvm=true,bench=c4 --no-enable-autoupgrade --quiet
echo "== $(date +%T) done; nodes:"
kubectl --context "gke_${P}_${Z}_${C}" get nodes -l bench=c4 -o wide
