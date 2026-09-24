#!/usr/bin/env bash
# C4 pass on glottman-sandbox-test-1: gVisor then microVM matrices on bench-c4-kvm. Goldens baked
# on Cascade Lake cannot restore on the new CPUs, so every swe-*/mvm-* template is deleted first
# and re-baked by the harness. Results: substrate/benchmarking/rl-image/concurrency/results/c4-*.jsonl, c4mvm-*.jsonl.
set -u
SUB=~/dev/substrate/benchmarking/rl-image/concurrency
CTX=gke_gke-ai-eco-dev_us-central1_glottman-sandbox-test-1; K="kubectl --context $CTX"; KA="/tmp/kubectl-ate --context $CTX"
GUEST=gcr.io/gke-ai-eco-dev/ate-images-glottman/ate-env-guest@sha256:ab7319567508ab29ff61615a5800c2bf0c20146f97e6d090b0e8c94974503d9d
echo "== $(date +%T) atelet + kvm on bench-c4-kvm"
for i in $(seq 1 30); do n=$($K -n ate-system get pods -l app=atelet -o wide --no-headers 2>/dev/null | grep -c "bench-c4-kvm.*Running\|Running.*bench-c4-kvm"); [ "$n" -ge 4 ] && { echo "atelet running on $n c4 nodes"; break; }; sleep 10; done
$K get nodes -l bench=c4kvm -o json | python3 -c 'import json,sys; ns=json.load(sys.stdin)["items"]; print("ate.dev/kvm total:", sum(int(n["status"]["allocatable"].get("ate.dev/kvm",0)) for n in ns), "nodes:", len(ns))'
echo "== $(date +%T) delete Cascade Lake templates (re-bake on C4)"
$KA get actor-templates -a rl-bench -o json 2>/dev/null | python3 -c 'import json,sys,re; d=json.load(sys.stdin); t=d if isinstance(d,list) else d.get("actorTemplates", d.get("actor_templates",[])); print("\n".join(x["metadata"]["name"] for x in t if re.match(r"^(swe|mvm)-([0-9]+|one)$", x["metadata"]["name"])))' > /tmp/c4-templates.txt
$KA get actors -a rl-bench -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d if isinstance(d,list) else d.get("actors",[]); print("\n".join(x["metadata"]["name"] for x in a))' | xargs -r -P 8 -I{} sh -c "$KA delete actor {} -a rl-bench --any-state >/dev/null 2>&1 || true"
wc -l < /tmp/c4-templates.txt | xargs echo "templates to delete:"
xargs -r -P 8 -I{} sh -c "$KA delete actor-template {} -a rl-bench >/dev/null 2>&1 || echo 'failed: {}'" < /tmp/c4-templates.txt | head -3
echo "== $(date +%T) apply C4 worker pools (gVisor 200, microVM 0)"
$K apply -f "$SUB/workerpool-c4.yaml" | tail -2
$K -n rl-bench patch workerpool rl-bench-ateom-c2 --type merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1; $K -n rl-bench patch workerpool rl-bench-microvm-c2 --type merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1
for i in $(seq 1 90); do r=$($K -n rl-bench get workerpool rl-bench-ateom-c4 -o jsonpath='{.status.readyReplicas}' 2>/dev/null); [ "${r:-0}" -ge 195 ] && { echo "gvisor c4 workers ready: $r"; break; }; sleep 10; done
echo "=== $(date +%T) gVisor matrix"
( cd "$SUB" && LABEL_PREFIX=c4- SKIP_POOL=1 GUEST_IMAGE=$GUEST ./run-matrix.sh 2>&1 | grep "^===\|FAILED\|timed out" )
echo "== $(date +%T) swap to microVM workers"
$K -n rl-bench patch workerpool rl-bench-ateom-c4 --type merge -p '{"spec":{"replicas":0}}' >/dev/null; $K -n rl-bench patch workerpool rl-bench-microvm-c4 --type merge -p '{"spec":{"replicas":200}}' >/dev/null
for i in $(seq 1 90); do r=$($K -n rl-bench get workerpool rl-bench-microvm-c4 -o jsonpath='{.status.readyReplicas}' 2>/dev/null); g=$($K -n rl-bench get pods -l workload=rl-bench-ateom --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "${r:-0}" -ge 195 ] && [ "$g" -le 5 ] && { echo "microvm c4 workers ready: $r"; break; }; sleep 10; done
echo "=== $(date +%T) microVM matrix"
( cd "$SUB" && SANDBOX_CLASS=SANDBOX_CLASS_MICROVM SANDBOX_CONFIG=microvm POOL_LABEL=workload=rl-bench-microvm TEMPLATE_PREFIX=mvm LABEL_PREFIX=c4mvm- SKIP_POOL=1 GUEST_IMAGE=$GUEST ./run-matrix.sh 2>&1 | grep "^===\|FAILED\|timed out" )
echo "== $(date +%T) glottman C4 pass done"
