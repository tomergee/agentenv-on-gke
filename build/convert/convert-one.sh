#!/usr/bin/env bash
# Convert one standard OCI image to overlaybd-native format.
#   convert-one.sh <instance-tag>
# Env: SRC_REPO (repo path without tag), DST_REPO (repo path without tag), VSIZE (GB, 64),
#      WORK (scratch dir). Auth: Workload Identity / Cloud Build metadata-server token.
# The convertor only works inside ONE repository (-r), so the source is first copied into
# the destination repository as <instance>-src, converted to <instance>, and the staging
# manifest is deleted. Idempotent: an existing <instance> in DST_REPO is skipped.
set -uo pipefail
inst=$1
src="$SRC_REPO:$inst"; dst="$DST_REPO:$inst"; staging="$DST_REPO:${inst}-src"
work="${WORK:-/workspace/work}/$inst"
start=$(date +%s)
elapsed() { echo "$(( $(date +%s) - start ))s"; }
token() {
  curl -sf -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
    | jq -r .access_token
}
login() {  # refresh crane credentials for both registry hosts; prints the token
  local t; t=$(token) || return 1; [ -n "$t" ] || return 1
  for h in us-docker.pkg.dev us-central1-docker.pkg.dev; do
    crane auth login "$h" -u oauth2accesstoken -p "$t" >/dev/null 2>&1 || return 1
  done
  echo "$t"
}
T=$(login) || { echo "RESULT $inst FAIL auth $(elapsed)"; exit 1; }
if crane manifest "$dst" >/dev/null 2>&1; then echo "RESULT $inst SKIP exists $(elapsed)"; exit 0; fi
if ! crane copy "$src" "$staging" >"/tmp/copy-$inst.log" 2>&1; then
  echo "RESULT $inst FAIL copy $(elapsed)"; tail -3 "/tmp/copy-$inst.log"; exit 1
fi
rm -rf "$work"; mkdir -p "$work"
convertor -r "$DST_REPO" -u "oauth2accesstoken:$T" -i "${inst}-src" --overlaybd "$inst" \
  -d "$work" --vsize "${VSIZE:-64}" >"/tmp/conv-$inst.log" 2>&1
rc=$?
rm -rf "$work"
if [ $rc -ne 0 ]; then echo "RESULT $inst FAIL convert $(elapsed)"; tail -5 "/tmp/conv-$inst.log"; exit 1; fi
# Drop the standard-format staging copy; the converted image has its own layers and config.
# Artifact Registry refuses to delete a manifest that still has a tag
# (GOOGLE_MANIFEST_DANGLING_TAG), so untag first, then delete by digest.
if T=$(login) && d=$(crane digest "$staging" 2>/dev/null) && [ -n "$d" ]; then
  { crane delete "$staging" >/dev/null 2>&1 && crane delete "$DST_REPO@$d" >/dev/null 2>&1; } \
    || echo "WARN $inst staging copy not deleted ($staging); scripts/convert-cleanup-staging.sh removes it"
fi
echo "RESULT $inst OK $(elapsed)"
