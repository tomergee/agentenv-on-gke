#!/usr/bin/env bash
# glottman-sandbox-test-1: replace bench-c2-kvm (4 x c2-standard-8) with bench-c4-kvm, same C4 shape.
# The substrate version label is stamped at creation so atelet lands on the new nodes at once.
set -euo pipefail
P=gke-ai-eco-dev; C=glottman-sandbox-test-1; R=us-central1; Z=us-central1-a
echo "== $(date +%T) scale bench-c2-kvm -> 0"
gcloud container clusters resize "$C" --project "$P" --region "$R" --node-pool bench-c2-kvm --num-nodes 0 --quiet
echo "== $(date +%T) create bench-c4-kvm"
gcloud container node-pools create bench-c4-kvm --cluster "$C" --project "$P" --region "$R" --node-locations "$Z" \
  --machine-type c4-standard-8 --num-nodes 4 --image-type COS_CONTAINERD \
  --disk-type hyperdisk-balanced --disk-size 300 \
  --boot-disk-provisioned-iops 6000 --boot-disk-provisioned-throughput 600 \
  --enable-nested-virtualization \
  --node-labels ate.dev/substrate-version=7ccf1aa6,bench=c4kvm --no-enable-autoupgrade --quiet
echo "== $(date +%T) done; nodes:"
kubectl --context "gke_${P}_${R}_${C}" get nodes -l bench=c4kvm -o wide
