#!/usr/bin/env python3
"""Burst-concurrency test: start N sandboxes at the same moment from N distinct converted
images, measure per sandbox the time to (a) the create call returning, (b) state running,
(c) the first command completing inside the sandbox, keep all N alive until every one has
finished its first command, then kill them all. Prints one JSON line per sandbox and a
summary JSON line. Runs inside the cluster (Job) or from a laptop with a port-forward.

Env: GW (gateway URL), KEY (API key), N (concurrency), INSTANCES (path or comma list of
instance tags), IMG_REPO, CPU (default 2), MEM (default 2048), TIMEOUT (sandbox TTL s),
ENVD_VERSION (default 0.5.15), RUN_LABEL (free text recorded in the output).
"""
import json, os, sys, time, threading
from concurrent.futures import ThreadPoolExecutor
import requests
from packaging.version import Version
from e2b import Sandbox
from e2b.connection_config import ConnectionConfig

GW = os.environ["GW"].rstrip("/"); KEY = os.environ["KEY"]; N = int(os.environ.get("N", "1"))
IMG_REPO = os.environ.get("IMG_REPO", "us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified")
CPU = int(os.environ.get("CPU", "2")); MEM = int(os.environ.get("MEM", "2048")); TIMEOUT = int(os.environ.get("TIMEOUT", "900"))
ENVD = Version(os.environ.get("ENVD_VERSION", "0.5.15")); LABEL = os.environ.get("RUN_LABEL", "")
raw = os.environ.get("INSTANCES", "")
insts = [l.strip() for l in (open(raw) if os.path.exists(raw) else raw.split(",")) if l.strip()][:N]
assert len(insts) == N, f"need {N} instances, got {len(insts)}"
H = {"X-API-Key": KEY}
S = requests.Session()

def api(method, path, **kw):
    return S.request(method, GW + path, headers=H, timeout=300, **kw)

def sbx(sid):
    hdr = {"X-API-Key": KEY, "e2b-sandbox-id": sid, "e2b-sandbox-port": "49983"}
    cfg = ConnectionConfig(api_url=GW, sandbox_url=GW, api_key=KEY, extra_sandbox_headers=hdr)
    return Sandbox(sandbox_id=sid, sandbox_domain=None, envd_version=ENVD, envd_access_token=None,
                   traffic_access_token=None, connection_config=cfg)

start_barrier = threading.Barrier(N)
release = threading.Event()
ids = []; lock = threading.Lock()

def one(inst):
    rec = {"instance": inst, "n": N, "label": LABEL}
    start_barrier.wait()                       # all N POST at the same moment
    t0 = time.monotonic(); rec["t_start_epoch"] = time.time()
    try:
        r = api("POST", "/sandboxes-cold", json={"image": f"{IMG_REPO}:{inst}", "cpuCount": CPU, "memoryMB": MEM, "timeout": TIMEOUT})
        rec["http"] = r.status_code
        sid = r.json().get("sandboxID") if r.headers.get("content-type", "").startswith("application/json") else None
        rec["t_post"] = round(time.monotonic() - t0, 3)
        if not sid:
            rec["status"] = "create_failed"; rec["body"] = r.text[:200]; return rec
        rec["id"] = sid
        with lock: ids.append(sid)
        state = ""
        while time.monotonic() - t0 < 600:
            st = api("GET", f"/sandboxes/{sid}")
            state = st.json().get("state", "") if st.ok else ""
            if state == "running": break
            time.sleep(0.25)
        rec["t_running"] = round(time.monotonic() - t0, 3)
        if state != "running":
            rec["status"] = "not_running"; rec["state"] = state; return rec
        t1 = time.monotonic()
        out = sbx(sid).commands.run("echo ready && test -d /testbed && echo TESTBED_OK", timeout=180)
        rec["t_first_cmd"] = round(time.monotonic() - t0, 3); rec["cmd_s"] = round(time.monotonic() - t1, 3)
        rec["status"] = "pass" if (out.exit_code == 0 and "TESTBED_OK" in out.stdout) else "cmd_failed"
        if rec["status"] != "pass": rec["cmd_out"] = (out.stdout + out.stderr)[-200:]
        return rec
    except Exception as e:                      # noqa: BLE001
        rec.setdefault("status", "error"); rec["error"] = f"{type(e).__name__}: {e}"[:300]; return rec

with ThreadPoolExecutor(max_workers=N) as ex:
    results = list(ex.map(one, insts))
# every sandbox stayed alive until here: let heartbeats catch up, snapshot per-node counts, then kill everything
time.sleep(12)
try:
    nodes = api("GET", "/nodes").json()
    per_node = {n.get("id"): n.get("sandboxCount") for n in nodes}
except Exception as e:                          # noqa: BLE001
    per_node = {"error": str(e)[:100]}
kill_t0 = time.monotonic()
for sid in ids: api("DELETE", f"/sandboxes/{sid}")
kill_s = round(time.monotonic() - kill_t0, 2)
for r in results: print(json.dumps(r), flush=True)
def pct(v, p):
    v = sorted(v); return round(v[min(len(v) - 1, int(round(p * (len(v) - 1))))], 2) if v else None
ok = [r for r in results if r.get("status") == "pass"]
summ = {"summary": True, "n": N, "label": LABEL, "pass": len(ok), "fail": N - len(ok),
        "cpu": CPU, "mem_mb": MEM, "per_node_running_at_peak": per_node, "kill_all_s": kill_s}
for k in ("t_post", "t_running", "t_first_cmd", "cmd_s"):
    v = [r[k] for r in ok if k in r]
    summ[k] = {"p50": pct(v, .5), "p90": pct(v, .9), "max": pct(v, 1.0), "min": pct(v, 0.0)}
bad = [r for r in results if r.get("status") != "pass"]
summ["failures"] = [{k: r.get(k) for k in ("instance", "status", "http", "error", "state", "body")} for r in bad][:20]
print(json.dumps(summ), flush=True)
