#!/usr/bin/env python3
"""Burst-concurrency test: start N sandboxes at the same moment from N distinct converted
images, measure per sandbox the time to (a) the create call returning, (b) state running,
(c) the first command completing inside the sandbox, keep all N alive until every one has
finished its first command, then kill them all. Prints one JSON line per sandbox and a
summary JSON line. Runs inside the cluster (Job) or from a laptop with a port-forward.

Env: GW (gateway URL), KEY (API key), N (concurrency), INSTANCES (path or comma list of
instance tags), IMG_REPO, CPU (default 2), MEM (default 2048), TIMEOUT (sandbox TTL s),
ENVD_VERSION (default 0.5.15), RUN_LABEL (free text recorded in the output).
MODE=fill keeps adding sandboxes in batches of FILL_BATCH up to FILL_TOTAL (cycling through the
N instances), records per level the batch latencies, a probe command on the oldest sandbox and
per-node count / CPU / memory from /nodes, and stops early when a batch mostly fails, a node
passes FILL_STOP_MEM_PERCENT memory, or the probe exceeds FILL_PROBE_MAX_S.
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
MODE = os.environ.get("MODE", "create")   # create | resume | template (build a template on every node, then N creates from it)
TEMPLATE = os.environ.get("TEMPLATE", "swe-tpl")  # template (snapshot) name used in template mode
SOURCES = int(os.environ.get("SOURCES", "12"))   # source sandboxes to snapshot in template mode (round-robin covers every node)
PRIME_CMD = os.environ.get("PRIME_CMD", "cd /testbed && python -c \"import sys; print(sys.version)\"")
SETTLE = float(os.environ.get("PAUSE_SETTLE_S", "5"))
FILL_TOTAL = int(os.environ.get("FILL_TOTAL", "400")); FILL_BATCH = int(os.environ.get("FILL_BATCH", "40"))
FILL_STOP_MEM = float(os.environ.get("FILL_STOP_MEM_PERCENT", "85")); FILL_PROBE_MAX_S = float(os.environ.get("FILL_PROBE_MAX_S", "30"))
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
pause_barrier = threading.Barrier(N)
resume_barrier = threading.Barrier(N)
release = threading.Event()
ids = []; lock = threading.Lock()

def arrive(b):
    try: b.wait(timeout=600)
    except threading.BrokenBarrierError: pass

def create_phase(inst, rec):
    """Create, wait running, first command. Returns the sandbox id or None; sets rec['status']."""
    t0 = time.monotonic(); rec["t_start_epoch"] = time.time()
    if MODE == "template":   # v0.2.2: template creates go through POST /sandboxes (v2 is GET-only)
        # Every sandbox comes from the one template; "instance" above is only the thread's label.
        rec["template"] = TEMPLATE; rec["image"] = f"{IMG_REPO}:{insts[0]}"
        r = api("POST", "/sandboxes", json={"templateID": TEMPLATE, "timeout": TIMEOUT})
    else:
        r = api("POST", "/sandboxes-cold", json={"image": f"{IMG_REPO}:{inst}", "cpuCount": CPU, "memoryMB": MEM, "timeout": TIMEOUT})
    rec["http"] = r.status_code
    sid = r.json().get("sandboxID") if r.headers.get("content-type", "").startswith("application/json") else None
    rec["t_post"] = round(time.monotonic() - t0, 3)
    if not sid:
        rec["status"] = "create_failed"; rec["body"] = r.text[:300]; return None
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
        rec["status"] = "not_running"; rec["state"] = state; return None
    t1 = time.monotonic()
    out = sbx(sid).commands.run("echo ready && test -d /testbed && echo TESTBED_OK", timeout=180)
    rec["t_first_cmd"] = round(time.monotonic() - t0, 3); rec["cmd_s"] = round(time.monotonic() - t1, 3)
    rec["status"] = "pass" if (out.exit_code == 0 and "TESTBED_OK" in out.stdout) else "cmd_failed"
    if rec["status"] != "pass": rec["cmd_out"] = (out.stdout + out.stderr)[-200:]; return None
    return sid

def resume_phase(sid, rec):
    """Pause (after the pause barrier), wait, resume (after the resume barrier), first command."""
    tp = time.monotonic()
    pr = api("POST", f"/sandboxes/{sid}/pause")
    rec["pause_http"] = pr.status_code; rec["pause_s"] = round(time.monotonic() - tp, 3)
    if pr.status_code != 204: rec["status"] = "pause_failed"; rec["body"] = pr.text[:200]; return False
    return True

def resume_phase2(sid, rec):
    tr = time.monotonic(); rec["t_resume_start_epoch"] = time.time()
    rr = api("POST", f"/sandboxes/{sid}/resume", json={"timeout": TIMEOUT})
    rec["resume_http"] = rr.status_code; rec["resume_call_s"] = round(time.monotonic() - tr, 3)
    if rr.status_code not in (200, 201): rec["status"] = "resume_failed"; rec["body"] = rr.text[:200]; return
    state = ""
    while time.monotonic() - tr < 300:
        st = api("GET", f"/sandboxes/{sid}"); state = st.json().get("state", "") if st.ok else ""
        if state == "running": break
        time.sleep(0.1)
    rec["resume_running_s"] = round(time.monotonic() - tr, 3)
    if state != "running": rec["status"] = "resume_not_running"; rec["state"] = state; return
    tc = time.monotonic()
    out2 = sbx(sid).commands.run("echo back && test -d /testbed && echo TESTBED_OK", timeout=180)
    rec["resume_first_cmd_s"] = round(time.monotonic() - tr, 3); rec["resume_cmd_s"] = round(time.monotonic() - tc, 3)
    if not (out2.exit_code == 0 and "TESTBED_OK" in out2.stdout): rec["status"] = "resume_cmd_failed"; rec["cmd_out"] = (out2.stdout + out2.stderr)[-200:]

def pct(v, p):
    v = sorted(v); return round(v[min(len(v) - 1, int(round(p * (len(v) - 1))))], 2) if v else None

def node_snapshot():
    out = {}
    for n in api("GET", "/nodes").json():
        m = n.get("metrics") or {}; tot = m.get("memoryTotalBytes") or 0; used = m.get("memoryUsedBytes") or 0
        out[n.get("id")] = {"sandboxes": n.get("sandboxCount"), "cpu_percent": m.get("cpuPercent"),
                            "mem_used_gb": round(used / 2**30, 1), "mem_percent": round(100 * used / tot, 1) if tot else None}
    return out

def probe_cmd(sid):
    tp = time.monotonic()
    try:
        out = sbx(sid).commands.run("echo probe", timeout=120)
        return round(time.monotonic() - tp, 2) if out.exit_code == 0 else -1
    except Exception:                           # noqa: BLE001
        return -1

def fill_run():
    """Fill the cluster level by level until FILL_TOTAL or a stop condition, then kill everything."""
    levels = []; all_recs = []; probe = None; total_ok = 0; stop = None
    while total_ok < FILL_TOTAL and not stop:
        b = min(FILL_BATCH, FILL_TOTAL - total_ok)
        recs = [{"instance": insts[(len(all_recs) + i) % len(insts)], "n": N, "label": LABEL, "batch": len(levels)} for i in range(b)]
        def go(rec):
            try: create_phase(rec["instance"], rec)
            except Exception as e:              # noqa: BLE001
                rec.setdefault("status", "error"); rec["error"] = f"{type(e).__name__}: {e}"[:300]
            return rec
        tb = time.monotonic()
        with ThreadPoolExecutor(max_workers=b) as ex: recs = list(ex.map(go, recs))
        batch_s = round(time.monotonic() - tb, 2)
        ok = [r for r in recs if r.get("status") == "pass"]; total_ok += len(ok); all_recs += recs
        if probe is None and ok: probe = ok[0]["id"]
        probe_s = probe_cmd(probe) if probe else None
        time.sleep(3)                           # let node heartbeats catch up before sampling
        try: nodes = node_snapshot()
        except Exception as e:                  # noqa: BLE001
            nodes = {}; print(json.dumps({"warn": f"nodes: {e}"[:200]}), flush=True)
        level = {"level": len(levels), "batch_size": b, "batch_ok": len(ok), "running_total": total_ok, "batch_s": batch_s,
                 "t_running": {"p50": pct([r["t_running"] for r in ok], .5), "p90": pct([r["t_running"] for r in ok], .9)},
                 "t_first_cmd": {"p50": pct([r["t_first_cmd"] for r in ok], .5), "p90": pct([r["t_first_cmd"] for r in ok], .9)},
                 "probe_cmd_s": probe_s, "nodes": nodes,
                 "fail_sample": [(r.get("status"), r.get("http"), (r.get("body") or r.get("error") or "")[:120]) for r in recs if r.get("status") != "pass"][:3]}
        levels.append(level); print(json.dumps(level), flush=True)
        mem_max = max([v.get("mem_percent") or 0 for v in nodes.values()] or [0])
        if len(ok) < b / 2: stop = f"{b - len(ok)} of {b} creates failed"
        elif mem_max >= FILL_STOP_MEM: stop = f"node memory {mem_max}% >= {FILL_STOP_MEM}%"
        elif probe_s is not None and (probe_s < 0 or probe_s > FILL_PROBE_MAX_S): stop = f"probe command {probe_s} s"
    time.sleep(20)                              # steady state at the final level
    try: steady = node_snapshot()
    except Exception as e:                      # noqa: BLE001
        steady = {"error": str(e)[:100]}
    probe_steady = probe_cmd(probe) if probe else None
    kill_t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=20) as ex: list(ex.map(lambda s: api("DELETE", f"/sandboxes/{s}"), ids))
    kill_s = round(time.monotonic() - kill_t0, 1)
    for r in all_recs: print(json.dumps(r), flush=True)
    summ = {"summary": True, "mode": "fill", "label": LABEL, "cpu": CPU, "mem_mb": MEM, "fill_total_target": FILL_TOTAL, "batch": FILL_BATCH,
            "running_reached": total_ok, "stop_reason": stop or "target reached", "levels": levels,
            "steady_state_nodes": steady, "steady_probe_cmd_s": probe_steady, "kill_all_s": kill_s, "killed": len(ids)}
    print(json.dumps(summ), flush=True)

def one(inst):
    rec = {"instance": inst, "n": N, "label": LABEL}
    start_barrier.wait(timeout=120)            # all N POST at the same moment
    sid = None
    try:
        sid = create_phase(inst, rec)
    except Exception as e:                      # noqa: BLE001
        rec.setdefault("status", "error"); rec["error"] = f"{type(e).__name__}: {e}"[:300]
    if MODE != "resume": return rec
    # Every thread arrives at both barriers so one failure never stalls the others.
    arrive(pause_barrier)
    paused = False
    if sid and rec.get("status") == "pass":
        try: paused = resume_phase(sid, rec)
        except Exception as e:                  # noqa: BLE001
            rec["status"] = "error"; rec["error"] = f"{type(e).__name__}: {e}"[:300]
    time.sleep(SETTLE)
    arrive(resume_barrier)
    if paused:
        try: resume_phase2(sid, rec)
        except Exception as e:                  # noqa: BLE001
            rec["status"] = "error"; rec["error"] = f"{type(e).__name__}: {e}"[:300]
    return rec

if MODE == "fill":
    fill_run(); sys.exit(0)

setup = {}
if MODE == "template":
    # Build the template on every runtime node: the prototype's snapshot repository is
    # node-local and placement is round-robin, so snapshot SOURCES cold-started sandboxes
    # under one name; repeats on the same node just re-point the name.
    ts0 = time.monotonic()
    def build_source(i):
        info = {"i": i}
        try:
            r = api("POST", "/sandboxes-cold", json={"image": f"{IMG_REPO}:{insts[0]}", "cpuCount": CPU, "memoryMB": MEM, "timeout": TIMEOUT})
            sid = r.json()["sandboxID"]
            for _ in range(600):
                if api("GET", f"/sandboxes/{sid}").json().get("state") == "running": break
                time.sleep(0.25)
            out = sbx(sid).commands.run(PRIME_CMD, timeout=180); info["prime_rc"] = out.exit_code
            t1 = time.monotonic()
            sr = api("POST", f"/sandboxes/{sid}/snapshots", json={"name": TEMPLATE})
            info["snapshot_http"] = sr.status_code; info["snapshot_s"] = round(time.monotonic() - t1, 2)
            info["snapshot_id"] = sr.json().get("snapshotID") if sr.ok else sr.text[:120]
            # v0.2.2 aliases are immutable: a second snapshot under the same name on a node
            # answers 400 "already points to ...", which means that node is already covered.
            info["alias_state"] = "created" if sr.ok else ("existing" if "already points" in sr.text else "error")
            api("DELETE", f"/sandboxes/{sid}")
        except Exception as e:                  # noqa: BLE001
            info["error"] = f"{type(e).__name__}: {e}"[:200]
        return info
    with ThreadPoolExecutor(max_workers=SOURCES) as ex:
        setup["sources"] = list(ex.map(build_source, range(SOURCES)))
    setup["template"] = TEMPLATE; setup["setup_s"] = round(time.monotonic() - ts0, 1)
    setup["snapshots_created"] = sum(1 for x in setup["sources"] if x.get("alias_state") == "created")
    setup["snapshots_existing"] = sum(1 for x in setup["sources"] if x.get("alias_state") == "existing")
    setup["snapshot_errors"] = [x for x in setup["sources"] if x.get("alias_state") not in ("created", "existing")]
    time.sleep(3)

with ThreadPoolExecutor(max_workers=N) as ex:
    results = list(ex.map(one, insts))
# every sandbox stayed alive until here: let heartbeats catch up, snapshot per-node counts, then kill everything
time.sleep(12)
try:
    nodes = api("GET", "/nodes").json()
    per_node = {n.get("id"): n.get("sandboxCount") for n in nodes}
    node_util = {n.get("id"): {"cpu_percent": (n.get("metrics") or {}).get("cpuPercent"),
                               "mem_used_gb": round(((n.get("metrics") or {}).get("memoryUsedBytes") or 0) / 2**30, 1),
                               "mem_total_gb": round(((n.get("metrics") or {}).get("memoryTotalBytes") or 0) / 2**30, 1)} for n in nodes}
except Exception as e:                          # noqa: BLE001
    per_node = {"error": str(e)[:100]}; node_util = {}
kill_t0 = time.monotonic()
for sid in ids: api("DELETE", f"/sandboxes/{sid}")
kill_s = round(time.monotonic() - kill_t0, 2)
for r in results: print(json.dumps(r), flush=True)
ok = [r for r in results if r.get("status") == "pass"]
summ = {"summary": True, "n": N, "label": LABEL, "pass": len(ok), "fail": N - len(ok),
        "cpu": CPU, "mem_mb": MEM, "per_node_running_at_peak": per_node, "node_util_at_peak": node_util, "kill_all_s": kill_s}
summ["mode"] = MODE
if setup: summ["template_setup"] = {k: v for k, v in setup.items() if k != "sources"}; summ["template_sources"] = setup["sources"]
for k in ("t_post", "t_running", "t_first_cmd", "cmd_s") + (("pause_s", "resume_call_s", "resume_running_s", "resume_first_cmd_s", "resume_cmd_s") if MODE == "resume" else ()):
    v = [r[k] for r in ok if k in r]
    summ[k] = {"p50": pct(v, .5), "p90": pct(v, .9), "max": pct(v, 1.0), "min": pct(v, 0.0)}
bad = [r for r in results if r.get("status") != "pass"]
summ["failures"] = [{k: r.get(k) for k in ("instance", "status", "http", "pause_http", "resume_http", "error", "state", "body")} for r in bad][:20]
print(json.dumps(summ), flush=True)
