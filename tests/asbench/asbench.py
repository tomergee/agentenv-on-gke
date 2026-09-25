#!/usr/bin/env python3
"""Burst-concurrency harness for agent-sandbox (kubernetes-sigs), mirroring tests/concurrency.py
(AgentENV) and the Substrate harness: one thread per sandbox released by a barrier, the same
100 SWE-bench images, 2 vCPU / 2 GiB limits, first command through the API server's exec path.

Modes (MODE):
  warm-one       one SandboxTemplate + one SandboxWarmPool with N replicas (template start, one image)
  warm-distinct  N templates + N pools of 1 replica (template start, N images)
  cold-one       one template, pool with 0 replicas: every claim creates a fresh pod (cold, one image)
  cold-distinct  N templates, N pools with 0 replicas (cold, N images)
  suspend        warm-one, then per sandbox: seed state, PodSnapshotManualTrigger (snapshot to GCS),
                 operatingMode=Suspended (pod terminated), operatingMode=Running (pod restored from
                 the snapshot), verify state, first command. GKE Pod Snapshots on gVisor.
  golden         one template + pool of 1 (primer): seed state, snapshot it under a golden-pool
                 label group, scale the pool to N (members boot restored from the golden), burst
                 N claims, verify every one carries the primer's state. Template start from a golden.
Setup (pool fill) is timed like a golden bake. Snapshot modes need RUNTIME_CLASS=gvisor, a pod
ServiceAccount with bucket access (POD_SA), the policies in snapshots/05-policies.yaml and the
podsnapshot.gke.io CRDs.

Env: MODE, N, IMAGES (tsv tag\\tdigest), IMG_REPO, NAMESPACE, NODE_POOL, CPU_LIMIT (2), MEM_LIMIT (2Gi),
CPU_REQ (250m), MEM_REQ (512Mi), RUN_LABEL, POOL_TIMEOUT_S (1800), KEEP (1 = leave pools/templates).
"""
import json, os, sys, time, threading, uuid, traceback
from concurrent.futures import ThreadPoolExecutor
from kubernetes import client, config
from kubernetes.stream import stream

MODE = os.environ.get("MODE", "warm-one"); N = int(os.environ.get("N", "1")); LABEL = os.environ.get("RUN_LABEL", "")
NS = os.environ.get("NAMESPACE", "asbench"); NODE_POOL = os.environ.get("NODE_POOL", "kvm-pool-c2")
IMG_REPO = os.environ.get("IMG_REPO", "us-docker.pkg.dev/gke-ai-eco-dev/swebench-mirror/swebench-verified")
CPU_LIMIT = os.environ.get("CPU_LIMIT", "2"); MEM_LIMIT = os.environ.get("MEM_LIMIT", "2Gi")
CPU_REQ = os.environ.get("CPU_REQ", "100m"); MEM_REQ = os.environ.get("MEM_REQ", "256Mi")   # requests only place pods; limits carry the 2 vCPU / 2 GiB size
POOL_TIMEOUT = float(os.environ.get("POOL_TIMEOUT_S", "1800")); KEEP = os.environ.get("KEEP", "0") == "1"
RUNTIME_CLASS = os.environ.get("RUNTIME_CLASS", "")          # "gvisor" on a GKE Sandbox pool
POD_SA = os.environ.get("POD_SA", "")                        # KSA the sandbox pods run as (bucket access)
SNAP_SETTLE = float(os.environ.get("SNAP_SETTLE_S", "5"))
PS = ("podsnapshot.gke.io", "v1")
SNAP_MODE = MODE in ("suspend", "golden")
RUN = uuid.uuid4().hex[:6]
EXT = ("extensions.agents.x-k8s.io", "v1beta1"); CORE = ("agents.x-k8s.io", "v1beta1")

images = []
for line in open(os.environ.get("IMAGES", "/work/images.tsv")):
    if line.strip() and not line.startswith("#"):
        p = line.rstrip("\n").split("\t"); images.append((p[0], p[1] if len(p) > 1 else None))
one_image = MODE.endswith("-one") or SNAP_MODE; warm = MODE.startswith("warm") or SNAP_MODE
assert one_image or len(images) >= N, f"need {N} images, have {len(images)}"

config.load_incluster_config()
# The websocket exec path does not pick up the in-cluster token from the refresh hook in
# current client versions (the handshake goes out unauthenticated and surfaces as a bodyless
# ApiException), so put the bearer token on the configuration explicitly.
_cfg = client.Configuration.get_default_copy()
_cfg.api_key = {"authorization": "Bearer " + open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()}
client.Configuration.set_default(_cfg)
cust = client.CustomObjectsApi(); core = client.CoreV1Api()

def img_ref(tag, digest): return f"{IMG_REPO}@{digest}" if digest else f"{IMG_REPO}:{tag}"

def template_body(name, tag, digest):
    pod_labels = {"asbench": "1"}
    if MODE == "suspend": pod_labels["asbench-snap"] = "per-sandbox"
    if MODE == "golden": pod_labels.update({"asbench-snap": "golden", "golden-pool": f"asb-golden-{RUN}"})
    spec_extra = {}
    if RUNTIME_CLASS: spec_extra["runtimeClassName"] = RUNTIME_CLASS
    if POD_SA: spec_extra["serviceAccountName"] = POD_SA
    return {"apiVersion": f"{EXT[0]}/{EXT[1]}", "kind": "SandboxTemplate",
            "metadata": {"name": name, "namespace": NS, "labels": {"asbench": "1"}},
            "spec": {"podTemplate": {"metadata": {"labels": pod_labels}, "spec": {
                **spec_extra,
                "nodeSelector": {"cloud.google.com/gke-nodepool": NODE_POOL},
                # Tiny requests plus image locality let the scheduler pack ~95 of 100 pods on one
                # node; spread them so N=100 is 25 per node like the other systems.
                "topologySpreadConstraints": [{"maxSkew": 2, "topologyKey": "kubernetes.io/hostname",
                                               "whenUnsatisfiable": "ScheduleAnyway",
                                               "labelSelector": {"matchLabels": {"asbench": "1"}}}],
                "terminationGracePeriodSeconds": 1,
                "containers": [{"name": "main", "image": img_ref(tag, digest), "command": ["/bin/sh", "-c", "sleep infinity"],
                                "resources": {"requests": {"cpu": CPU_REQ, "memory": MEM_REQ},
                                              "limits": {"cpu": CPU_LIMIT, "memory": MEM_LIMIT}}}]}}}}

def pool_body(name, template, replicas):
    return {"apiVersion": f"{EXT[0]}/{EXT[1]}", "kind": "SandboxWarmPool",
            "metadata": {"name": name, "namespace": NS, "labels": {"asbench": "1"}},
            "spec": {"replicas": replicas, "sandboxTemplateRef": {"name": template}}}

def claim_body(name, pool):
    return {"apiVersion": f"{EXT[0]}/{EXT[1]}", "kind": "SandboxClaim",
            "metadata": {"name": name, "namespace": NS, "labels": {"asbench": "1", "asbench-run": RUN}},
            "spec": {"warmPoolRef": {"name": pool}}}

def create(plural, body):
    try: return cust.create_namespaced_custom_object(EXT[0], EXT[1], NS, plural, body)
    except client.exceptions.ApiException as e:
        if e.status == 409: return cust.get_namespaced_custom_object(EXT[0], EXT[1], NS, plural, body["metadata"]["name"])
        raise

def retry(fn, tries=4, base=0.3):
    """The python client turns some transport errors into a bodyless ApiException that it then
    fails to decode (AttributeError); treat those like any transient error and retry."""
    for i in range(tries):
        try: return fn()
        except client.exceptions.ApiException as e:
            if e.status in (404, 409): raise
            if i == tries - 1: raise
        except (AttributeError, OSError):
            if i == tries - 1: raise
        time.sleep(base * (2 ** i))

def get(plural, name):
    try: return retry(lambda: cust.get_namespaced_custom_object(EXT[0], EXT[1], NS, plural, name))
    except client.exceptions.ApiException as e:
        if e.status == 404: return None
        raise

def delete(plural, name):
    try: cust.delete_namespaced_custom_object(EXT[0], EXT[1], NS, plural, name, body={"propagationPolicy": "Background"})
    except client.exceptions.ApiException as e:
        if e.status != 404: raise

def cond(obj, ctype):
    for c in ((obj or {}).get("status") or {}).get("conditions", []) or []:
        if c.get("type") == ctype: return c.get("status"), c.get("reason", "")
    return None, ""

def run_cmd(pod, argv, timeout=180):
    out = stream(core.connect_get_namespaced_pod_exec, pod, NS, command=argv, container="main",
                 stderr=True, stdin=False, stdout=True, tty=False, _preload_content=False)
    out.run_forever(timeout=timeout); rc = out.returncode; txt = (out.read_stdout() or "") + (out.read_stderr() or "")
    out.close(); return (rc if rc is not None else -1), txt

# ---------------------------------------------------------------- snapshot helpers
SEED_CMD = ("nonce=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \\n'); echo $nonce > /dev/shm/nonce; "
            "echo marker-$nonce > /root/asbench-marker; "
            "(i=0; while :; do i=$((i+1)); echo $i > /dev/shm/counter; sleep 1; done) >/dev/null 2>&1 & "
            "sleep 2; echo NONCE=$nonce COUNTER=$(cat /dev/shm/counter)")
STATE_CMD = "echo NONCE=$(cat /dev/shm/nonce 2>/dev/null) COUNTER=$(cat /dev/shm/counter 2>/dev/null) MARKER=$(cat /root/asbench-marker 2>/dev/null)"

def parse_kv(txt):
    out = {}
    for tok in txt.split():
        if "=" in tok: k, v = tok.split("=", 1); out[k] = v
    return out

def snapshot_pod(pod, trigger_name, timeout=600):
    """PodSnapshotManualTrigger -> wait for the PodSnapshot it created to be Ready. Returns (ok, snapshot_name, seconds, why)."""
    t0 = time.monotonic()
    body = {"apiVersion": f"{PS[0]}/{PS[1]}", "kind": "PodSnapshotManualTrigger",
            "metadata": {"name": trigger_name, "namespace": NS, "labels": {"asbench": "1"}}, "spec": {"targetPod": pod}}
    try: cust.create_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshotmanualtriggers", body)
    except client.exceptions.ApiException as e:
        if e.status != 409: return False, None, round(time.monotonic() - t0, 3), f"trigger create: {e.status} {e.reason}"
    snap = None
    while time.monotonic() - t0 < timeout:
        try: tr = cust.get_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshotmanualtriggers", trigger_name)
        except client.exceptions.ApiException: tr = {}
        st = tr.get("status") or {}
        snap = st.get("podSnapshotName") or st.get("snapshotName") or (st.get("podSnapshot") or {}).get("name")
        if not snap:
            for c in st.get("conditions", []) or []:
                if c.get("type") == "Triggered" and c.get("status") == "True": snap = snap or c.get("message", "").split()[-1]
        if snap:
            try: ps = cust.get_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshots", snap)
            except client.exceptions.ApiException: ps = None
            if ps:
                for c in ((ps.get("status") or {}).get("conditions") or []):
                    if c.get("type") == "Ready" and c.get("status") == "True": return True, snap, round(time.monotonic() - t0, 3), ""
                    if c.get("type") == "Ready" and c.get("status") == "False" and c.get("reason", "").lower().startswith("fail"): return False, snap, round(time.monotonic() - t0, 3), c.get("message", "")[:200]
        time.sleep(0.25)
    return False, snap, round(time.monotonic() - t0, 3), "timeout waiting for PodSnapshot Ready"

def latest_ready_snapshot(label_selector):
    items = cust.list_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshots", label_selector=label_selector).get("items", [])
    ready = [i for i in items if any(c.get("type") == "Ready" and c.get("status") == "True" for c in ((i.get("status") or {}).get("conditions") or []))]
    ready.sort(key=lambda i: i["metadata"].get("creationTimestamp", "")); return ready[-1]["metadata"]["name"] if ready else None

def set_operating_mode(sandbox, mode):
    cust.patch_namespaced_custom_object(CORE[0], CORE[1], NS, "sandboxes", sandbox, {"spec": {"operatingMode": mode}})

def pod_restored(pod):
    try: p = core.read_namespaced_pod(pod, NS)
    except client.exceptions.ApiException: return None, ""
    for c in (p.status.conditions or []):
        if c.type == "PodRestored": return c.status == "True", (c.message or "")[:160]
    return False, "no PodRestored condition"

def wait_pod_gone(pod, uid, timeout=300):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        try:
            p = core.read_namespaced_pod(pod, NS)
            if p.metadata.uid != uid: return round(time.monotonic() - t0, 3)
        except client.exceptions.ApiException as e:
            if e.status == 404: return round(time.monotonic() - t0, 3)
        time.sleep(0.2)
    return None

def wait_claim_ready(name, t0, timeout=900):
    while time.monotonic() - t0 < timeout:
        c = get("sandboxclaims", name) or {}; s, _ = cond(c, "Ready")
        if s == "True": return True
        time.sleep(0.2)
    return False

# ---------------------------------------------------------------- setup (templates + pools)
setup = {"mode": MODE}; ts0 = time.monotonic()
MODE_TAG = {"warm-one": "w", "cold-one": "c", "suspend": "s", "golden": "g"}.get(MODE, "w" if warm else "c")
if one_image:
    # One template per mode: pod labels differ per mode (snapshot policies key on them) and a
    # golden run that exits early must not leave a template a later warm run would reuse.
    tag, digest = images[0]; tname = f"asb-{MODE_TAG}-one"; pname = tname
    create("sandboxtemplates", template_body(tname, tag, digest))
    replicas = N if warm else 0
    existing = get("sandboxwarmpools", pname)
    if existing and (existing.get("spec") or {}).get("replicas") != replicas:
        cust.patch_namespaced_custom_object(EXT[0], EXT[1], NS, "sandboxwarmpools", pname, {"spec": {"replicas": replicas}})
    else: create("sandboxwarmpools", pool_body(pname, tname, replicas))
    plan = [(pname, tag)] * N; pools = [pname]
else:
    plan = []; pools = []
    def mk(i):
        tag, digest = images[i]; tname = f"asb-{'w' if warm else 'c'}-{i}"
        create("sandboxtemplates", template_body(tname, tag, digest))
        existing = get("sandboxwarmpools", tname); replicas = 1 if warm else 0
        if existing and (existing.get("spec") or {}).get("replicas") != replicas:
            cust.patch_namespaced_custom_object(EXT[0], EXT[1], NS, "sandboxwarmpools", tname, {"spec": {"replicas": replicas}})
        elif not existing: create("sandboxwarmpools", pool_body(tname, tname, replicas))
        return (tname, tag)
    with ThreadPoolExecutor(max_workers=min(N, 20)) as ex: plan = list(ex.map(mk, range(N)))
    pools = [p for p, _ in plan]
golden = {}
if MODE == "golden":
    # Primer: one pool member, claim it, seed memory + rootfs state, snapshot it. Then scale the pool
    # to N: every new member restores from the group's latest Ready snapshot before any claim exists.
    tg0 = time.monotonic(); pname = pools[0]
    cust.patch_namespaced_custom_object(EXT[0], EXT[1], NS, "sandboxwarmpools", pname, {"spec": {"replicas": 1}})
    while time.monotonic() - tg0 < POOL_TIMEOUT:
        if int(((get("sandboxwarmpools", pname) or {}).get("status") or {}).get("readyReplicas") or 0) >= 1: break
        time.sleep(1)
    golden["primer_pool_ready_s"] = round(time.monotonic() - tg0, 1)
    primer = f"asb-primer-{RUN}"; create("sandboxclaims", claim_body(primer, pname)); tc = time.monotonic()
    if not wait_claim_ready(primer, tc): print(json.dumps({"fatal": "primer claim never ready"}), flush=True); sys.exit(1)
    primer_pod = ((get("sandboxclaims", primer) or {}).get("status") or {}).get("sandbox", {}).get("name") or primer
    rc, txt = run_cmd(primer_pod, ["/bin/sh", "-c", SEED_CMD]); golden["primer_seed"] = parse_kv(txt); golden["primer_pod"] = primer_pod
    ok, snap, snap_s, why = snapshot_pod(primer_pod, f"golden-{RUN}")
    golden.update({"snapshot_ok": ok, "snapshot": snap, "snapshot_s": snap_s, "snapshot_error": why})
    if not ok: print(json.dumps({"fatal": f"golden snapshot failed: {why}"}), flush=True); sys.exit(1)
    time.sleep(SNAP_SETTLE)
    tfill = time.monotonic(); cust.patch_namespaced_custom_object(EXT[0], EXT[1], NS, "sandboxwarmpools", pname, {"spec": {"replicas": N + 1}})
    while time.monotonic() - tfill < POOL_TIMEOUT:
        if int(((get("sandboxwarmpools", pname) or {}).get("status") or {}).get("readyReplicas") or 0) >= N + 1: break
        time.sleep(1)
    golden["golden_fill_s"] = round(time.monotonic() - tfill, 1)   # N members restored from the golden
    members = [p for p in core.list_namespaced_pod(NS, label_selector="asbench=1").items if p.metadata.name != primer_pod]
    golden["members_restored"] = sum(1 for p in members if any(c.type == "PodRestored" and c.status == "True" for c in (p.status.conditions or [])))
    golden["members"] = len(members); setup["golden"] = golden; warm = False   # pool is already full; skip the generic wait
if warm:   # wait for every pool to be full: this is the "bake"
    want = {p: (N if one_image else 1) for p in pools}; ready_at = {}; t0 = time.monotonic()
    while len(ready_at) < len(pools) and time.monotonic() - t0 < POOL_TIMEOUT:
        for p in pools:
            if p in ready_at: continue
            st = (get("sandboxwarmpools", p) or {}).get("status") or {}
            if int(st.get("readyReplicas") or 0) >= want[p]: ready_at[p] = round(time.monotonic() - t0, 1)
        if len(ready_at) < len(pools): time.sleep(2)
    v = sorted(ready_at.values()); setup["pools_ready"] = len(ready_at); setup["pools_pending"] = [p for p in pools if p not in ready_at]
    if v: setup["pool_ready_s"] = {"p50": v[len(v) // 2], "p90": v[min(len(v) - 1, int(round(0.9 * (len(v) - 1))))], "max": v[-1]}
setup["setup_s"] = round(time.monotonic() - ts0, 1)
print(json.dumps({"setup": setup}), flush=True)
time.sleep(3)

# ---------------------------------------------------------------- burst
barrier = threading.Barrier(N); claims = []; lock = threading.Lock()

def one(i, pool, tag):
    name = f"asb-{RUN}-{i}"; rec = {"instance": tag, "pool": pool, "claim": name, "n": N, "label": LABEL, "mode": MODE}
    barrier.wait(timeout=300); t0 = time.monotonic(); rec["t_start_epoch"] = time.time()
    try:
        create("sandboxclaims", claim_body(name, pool))
        with lock: claims.append(name)
        rec["t_post"] = round(time.monotonic() - t0, 3)
        sb = None; state = ""
        while time.monotonic() - t0 < 900:
            c = get("sandboxclaims", name) or {}; st = c.get("status") or {}
            sbname = (st.get("sandbox") or {}).get("name")
            if sbname and "t_bound" not in rec: rec["t_bound"] = round(time.monotonic() - t0, 3); sb = sbname
            s, reason = cond(c, "Ready")
            if s == "True": state = "ready"; break
            time.sleep(0.2)
        rec["t_running"] = round(time.monotonic() - t0, 3)
        if state != "ready": rec["status"] = "not_ready"; return rec
        pod = sb or name
        try:
            p = retry(lambda: core.read_namespaced_pod(pod, NS)); rec["node"] = p.spec.node_name
        except Exception: pass                  # noqa: BLE001
        t1 = time.monotonic()
        rc, txt = run_cmd(pod, ["/bin/sh", "-c", "echo ready && test -d /testbed && echo TESTBED_OK"])
        rec["t_first_cmd"] = round(time.monotonic() - t0, 3); rec["cmd_s"] = round(time.monotonic() - t1, 3); rec["cmd_exit"] = rc
        rec["status"] = "pass" if (rc == 0 and "TESTBED_OK" in txt) else "cmd_failed"
        if rec["status"] != "pass": rec["cmd_out"] = txt[-200:]
        if MODE == "golden" and rec["status"] == "pass":
            rc2, st = run_cmd(pod, ["/bin/sh", "-c", STATE_CMD]); kv = parse_kv(st)
            rec["restored_state"] = kv; rec["restored"], rec["restored_msg"] = pod_restored(pod)
            prim = (setup.get("golden") or {}).get("primer_seed") or {}
            rec["state_matches_primer"] = bool(kv.get("NONCE")) and kv.get("NONCE") == prim.get("NONCE")
            if not rec["state_matches_primer"]: rec["status"] = "not_restored"
        if MODE == "suspend" and rec["status"] == "pass":
            rc2, st = run_cmd(pod, ["/bin/sh", "-c", SEED_CMD]); seed = parse_kv(st); rec["seed"] = seed
            sb_obj = get("sandboxclaims", name) or {}; sbname = (sb_obj.get("status") or {}).get("sandbox", {}).get("name") or pod
            pod_uid = core.read_namespaced_pod(pod, NS).metadata.uid
            ok, snap, snap_s, why = snapshot_pod(pod, f"susp-{RUN}-{i}")
            rec["snapshot_s"] = snap_s; rec["snapshot"] = snap
            if not ok: rec["status"] = "snapshot_failed"; rec["error"] = why; return rec
            tp = time.monotonic(); set_operating_mode(sbname, "Suspended")
            gone = wait_pod_gone(pod, pod_uid); rec["suspend_s"] = gone if gone is not None else -1
            rec["park_s"] = round(rec["snapshot_s"] + (gone or 0), 3)     # snapshot + termination = the "pause"
            if gone is None: rec["status"] = "suspend_failed"; return rec
            time.sleep(SNAP_SETTLE)
            tr = time.monotonic(); rec["t_resume_start_epoch"] = time.time(); set_operating_mode(sbname, "Running")
            rec["resume_call_s"] = round(time.monotonic() - tr, 3)
            ready = wait_claim_ready(name, tr); rec["resume_running_s"] = round(time.monotonic() - tr, 3)
            if not ready: rec["status"] = "resume_not_ready"; return rec
            rec["restored"], rec["restored_msg"] = pod_restored(pod)
            rc3, st3 = run_cmd(pod, ["/bin/sh", "-c", STATE_CMD]); kv = parse_kv(st3)
            rec["resume_first_cmd_s"] = round(time.monotonic() - tr, 3); rec["resume_state"] = kv
            rec["state_restored"] = kv.get("NONCE") == seed.get("NONCE") and kv.get("MARKER", "").endswith(seed.get("NONCE", "?"))
            try: rec["counter_advanced"] = int(kv.get("COUNTER", "0")) >= int(seed.get("COUNTER", "0"))
            except ValueError: rec["counter_advanced"] = None
            if not rec["state_restored"]: rec["status"] = "not_restored"
    except Exception as e:                      # noqa: BLE001
        rec.setdefault("status", "error"); rec["error"] = f"{type(e).__name__}: {e}"[:300]
        rec["trace"] = traceback.format_exc()[-700:]
    return rec

with ThreadPoolExecutor(max_workers=N) as ex:
    results = list(ex.map(lambda ip: one(ip[0], ip[1][0], ip[1][1]), enumerate(plan)))
time.sleep(5)
kill_t0 = time.monotonic()
with ThreadPoolExecutor(max_workers=20) as ex: list(ex.map(lambda c: delete("sandboxclaims", c), claims))
kill_s = round(time.monotonic() - kill_t0, 1)
# wait until the claimed pods are gone, so the next run starts clean
tg = time.monotonic()
while time.monotonic() - tg < 90:      # pods of deleted claims usually vanish in seconds; do not stall a run on stragglers
    try:
        left = [p for p in retry(lambda: core.list_namespaced_pod(NS, label_selector="asbench=1")).items if (p.metadata.labels or {}).get("agents.x-k8s.io/claim-uid") or p.metadata.deletion_timestamp]
    except Exception:                           # noqa: BLE001
        left = ["?"]
    if not left: break
    time.sleep(2)
gone_s = round(time.monotonic() - kill_t0, 1)
if SNAP_MODE:
    try:
        for tr in cust.list_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshotmanualtriggers", label_selector="asbench=1").get("items", []):
            try: cust.delete_namespaced_custom_object(PS[0], PS[1], NS, "podsnapshotmanualtriggers", tr["metadata"]["name"])
            except client.exceptions.ApiException: pass
    except Exception: pass                   # noqa: BLE001
if not KEEP:
    for p in pools: delete("sandboxwarmpools", p)
    for p in {t for t, _ in plan}: delete("sandboxtemplates", p)
for r in results: print(json.dumps(r), flush=True)
def pct(v, p):
    v = sorted(v); return round(v[min(len(v) - 1, int(round(p * (len(v) - 1))))], 2) if v else None
ok = [r for r in results if r.get("status") == "pass"]
per_node = {}
for r in ok: per_node[r.get("node") or "?"] = per_node.get(r.get("node") or "?", 0) + 1
summ = {"summary": True, "system": "agent-sandbox", "mode": MODE, "n": N, "label": LABEL, "pass": len(ok), "fail": N - len(ok),
        "cpu": CPU_LIMIT, "mem": MEM_LIMIT, "template_setup": setup, "per_node": per_node, "kill_all_s": kill_s, "pods_gone_s": gone_s}
keys = ["t_post", "t_bound", "t_running", "t_first_cmd", "cmd_s"]
if MODE == "suspend": keys += ["snapshot_s", "suspend_s", "park_s", "resume_call_s", "resume_running_s", "resume_first_cmd_s"]
for k in keys:
    v = [r[k] for r in ok if k in r and isinstance(r[k], (int, float))]; summ[k] = {"p50": pct(v, .5), "p90": pct(v, .9), "max": pct(v, 1.0), "min": pct(v, 0.0)}
if SNAP_MODE:
    summ["restored_count"] = sum(1 for r in results if r.get("restored") is True)
    summ["state_ok_count"] = sum(1 for r in results if r.get("state_restored") is True or r.get("state_matches_primer") is True)
summ["failures"] = [{k: r.get(k) for k in ("instance", "claim", "status", "error", "cmd_exit", "cmd_out")} for r in results if r.get("status") != "pass"][:20]
print(json.dumps(summ), flush=True)
