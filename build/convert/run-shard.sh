#!/usr/bin/env bash
# Run convert-one.sh over a set of instances.
#   INSTANCES="a,b,c"            explicit list, or
#   SHARD=<0..SHARDS-1> SHARDS=N  every Nth line (offset SHARD) of INSTANCES_FILE
set -uo pipefail
list=${INSTANCES_FILE:-/workspace/verified-instances.txt}
if [ -n "${INSTANCES:-}" ]; then
  items=$(echo "$INSTANCES" | tr ',' '\n' | sed '/^$/d')
else
  items=$(awk -v s="${SHARD:-0}" -v n="${SHARDS:-1}" 'NR % n == s' "$list")
fi
total=$(echo "$items" | grep -c .); ok=0; skip=0; fail=0; i=0
echo "START shard=${SHARD:-list} items=$total src=$SRC_REPO dst=$DST_REPO $(date -u +%FT%TZ)"
for inst in $items; do
  i=$((i+1))
  out=$(convert-one.sh "$inst" 2>&1); echo "[$i/$total] $out"
  case "$out" in *" OK "*) ok=$((ok+1));; *" SKIP "*) skip=$((skip+1));; *) fail=$((fail+1));; esac
done
echo "SUMMARY shard=${SHARD:-list} ok=$ok skip=$skip fail=$fail $(date -u +%FT%TZ)"
[ "$fail" -eq 0 ]
