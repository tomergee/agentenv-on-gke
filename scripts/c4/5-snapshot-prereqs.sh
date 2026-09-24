#!/usr/bin/env bash
# Pod Snapshots prerequisites for the agent-sandbox snapshot rows on barkland-test:
# a bucket in the cluster's region with the settings GKE requires, IAM for the sandbox pods' KSA
# and for the GKE service agent, then the storage config and the two policies.
# Usage: SNAPSHOT_BUCKET=gke-ai-eco-dev-asbench-snap-0924 scripts/c4/5-snapshot-prereqs.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
P=gke-ai-eco-dev; PN=142966328212; CTX=gke_gke-ai-eco-dev_us-central1-a_barkland-test; K="kubectl --context $CTX"
: "${SNAPSHOT_BUCKET:?set SNAPSHOT_BUCKET}"
POD_KSA="principal://iam.googleapis.com/projects/$PN/locations/global/workloadIdentityPools/$P.svc.id.goog/subject/ns/asbench/sa/asbench-pods"
gcloud storage buckets describe "gs://$SNAPSHOT_BUCKET" --project "$P" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://$SNAPSHOT_BUCKET" --project "$P" --location=us-central1 \
    --uniform-bucket-level-access --enable-hierarchical-namespace --soft-delete-duration=0
gcloud storage buckets add-iam-policy-binding "gs://$SNAPSHOT_BUCKET" --project "$P" --member="$POD_KSA" --role=roles/storage.bucketViewer --format=none
gcloud storage buckets add-iam-policy-binding "gs://$SNAPSHOT_BUCKET" --project "$P" --member="$POD_KSA" --role=roles/storage.objectUser --format=none
gcloud storage buckets add-iam-policy-binding "gs://$SNAPSHOT_BUCKET" --project "$P" \
  --member="serviceAccount:service-$PN@container-engine-robot.iam.gserviceaccount.com" --role=roles/storage.objectUser --format=none
$K apply -f tests/asbench/rbac.yaml
sed "s/\${SNAPSHOT_BUCKET}/$SNAPSHOT_BUCKET/" tests/asbench/snapshots/00-storageconfig.yaml.tmpl | $K apply -f -
$K apply -f tests/asbench/snapshots/05-policies.yaml
$K get podsnapshotstorageconfigs,podsnapshotpolicies -A
