# Test plan: AgentENV prototype on `barkland-test`

For the tester agent. Execute in order; every step maps to an acceptance criterion in
[acceptance-criteria.md](acceptance-criteria.md). Write results to `tests/RESULTS.md`
as you go, not at the end.

## 0. Prerequisites

```bash
export KCTX=gke_gke-ai-eco-dev_us-central1-a_barkland-test
alias K="kubectl --context $KCTX -n agentenv-system"
kubectl --context $KCTX get ns agentenv-system            # deployed by the developer
```

Snapshot the state you must not disturb (used by AC-13):

```bash
kubectl --context $KCTX -n agent-sandbox-system get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount --no-headers > /tmp/before-agent-sandbox-system.txt
kubectl --context $KCTX get ns -o name | sort > /tmp/before-namespaces.txt
gcloud container node-pools list --cluster barkland-test --zone us-central1-a --project gke-ai-eco-dev --format='value(name)' | sort > /tmp/before-nodepools.txt
```

API key and port-forward (keep the port-forward running in its own shell or background
process; restart it if the gateway pod restarts):

```bash
export KEY=$(kubectl --context $KCTX -n agentenv-system get secret agentenv-auth -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')
kubectl --context $KCTX -n agentenv-system port-forward svc/agentenv-gateway 8080:8080 >/tmp/pf.log 2>&1 &
export GW=http://127.0.0.1:8080
curl -s -o /dev/null -w '%{http_code}\n' $GW/health          # expect 204 (No Content)
```

Command execution inside sandboxes. Preferred: the official E2B Python SDK, which AgentENV
documents as compatible. Install it in a throwaway venv:

```bash
python3 -m venv /tmp/e2b-venv && /tmp/e2b-venv/bin/pip install -q e2b
export E2B_API_URL=$GW E2B_SANDBOX_URL=$GW E2B_API_KEY=$KEY
```

If the SDK fails against the port-forward (for example because of URL or header handling),
fall back to curl against envd's HTTP endpoints through the gateway proxy. envd listens on
port 49983 inside the sandbox; the proxy needs the sandbox ID, the target port and the
sandbox's `envdAccessToken`:

```bash
ENVD=(-H "X-API-Key: $KEY" -H "X-Access-Token: $TOK" -H "e2b-sandbox-id: $ID" -H "e2b-sandbox-port: 49983")
curl -s -o /dev/null -w '%{http_code}\n' "${ENVD[@]}" $GW/health           # 204 from envd
curl -s "${ENVD[@]}" -X POST -H 'Content-Type: application/octet-stream' \
  --data-binary 'hello' "$GW/files?path=/root/marker.txt"                   # write
curl -s "${ENVD[@]}" "$GW/files?path=/root/marker.txt"                       # read back
```

The `/files` endpoints prove the guest is alive and preserve state across pause/resume.
Running an arbitrary command over curl needs envd's Connect-RPC `process.Process/Start`
stream, which is awkward from curl; use the SDK for commands, and if the SDK is unusable,
record AC-4 as passed with the file round-trip plus envd `/health`, and say so. The
`aenv` CLI (`scripts/install-cli.sh` in the AgentENV repo, macOS arm64 supported) is a
third option: `aenv auth` with the port-forward URL and key, then `aenv exec <id> <cmd>`.

Fork has no E2B SDK call; always use curl for it.

Timing helper:

```bash
t() { local s=$(date +%s.%N); "$@"; local e=$(date +%s.%N); echo "elapsed=$(echo "$e - $s" | bc) s" >&2; }
```

## 1. Deployment health (AC-1, AC-2)

1. `K get pods -o wide`; wait until the three pods are Ready (up to 10 minutes after the
   developer's deploy). Capture output and `K get events --sort-by=.lastTimestamp | tail -30`.
2. `curl -s -o /dev/null -w '%{http_code}\n' $GW/health`
3. `curl -s -H "X-API-Key: $KEY" $GW/nodes | python3 -m json.tool`; note the node ID.
4. `curl -s -H "X-API-Key: $KEY" $GW/nodes/<nodeID> | python3 -m json.tool`.
5. Record the runtime pod's first-start duration from the events (image pull, asset
   downloads) as context, not as a criterion.

## 2. Cold create (AC-3)

1. Start the timer, then:
   ```bash
   curl -s -D /tmp/create.h -X POST -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
     -d '{"image":"ubuntu:22.04","timeout":900,"autoPause":false,"cpuCount":1,"memoryMB":1024}' \
     $GW/sandboxes-cold | tee /tmp/create.json
   export ID=$(python3 -c 'import json;print(json.load(open("/tmp/create.json"))["sandboxID"])')
   export TOK=$(python3 -c 'import json;print(json.load(open("/tmp/create.json")).get("envdAccessToken",""))')
   ```
2. Poll every 2 s: `curl -s -H "X-API-Key: $KEY" $GW/sandboxes/$ID | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])'` until `running`; stop the timer.
3. Record: HTTP status from `/tmp/create.h`, the `x-agentenv-sandbox-id` header, the
   response with tokens truncated to 6 characters, elapsed seconds.
4. On failure or a wait over 10 minutes: `K logs ds/agentenv-node --tail=200`,
   `K describe pod -l app.kubernetes.io/name=agentenv-node | tail -40`, and node disk:
   `K exec ds/agentenv-node -c agentenv -- sh -c 'df -h /workspace; du -sh /workspace/env/*'`
   (the runtime pod mounts the node's `/var/lib/aenv` at `/workspace`; never use
   `kubectl debug node/...`, which creates a privileged pod outside `agentenv-system`).

## 3. Command execution (AC-4)

1. SDK path:
   ```bash
   /tmp/e2b-venv/bin/python - <<EOF
   import time
   from e2b import Sandbox
   s = Sandbox.connect("$ID")
   t0 = time.time(); r = s.commands.run("echo hello-from-agentenv"); t1 = time.time()
   print("exit", r.exit_code, "stdout", r.stdout.strip(), "rtt", round(t1 - t0, 3))
   print(s.commands.run("uname -r; head -1 /etc/os-release").stdout)
   s.commands.run("echo marker-$(date +%s) > /root/marker.txt && cat /root/marker.txt")
   EOF
   ```
2. If the SDK path fails, use the curl fallback from section 0 and record which path was
   used and why.
3. Record the round-trip time of the `echo`.

## 4. Pause (AC-5)

1. Confirm the marker exists (read it back).
2. `t curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "X-API-Key: $KEY" $GW/sandboxes/$ID/pause` (expect 204).
3. `curl -s -H "X-API-Key: $KEY" "$GW/v2/sandboxes?state=paused"` contains `$ID`;
   `...?state=running` does not.
4. Record the pause duration.

## 5. Resume (AC-6)

1. `t curl -s -X POST -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d '{"timeout":900}' $GW/sandboxes/$ID/resume` (expect 201, same `sandboxID`). If the
   response carries a new `envdAccessToken`, update `$TOK`.
2. Immediately read the marker back (SDK or curl); loop until it succeeds and record the
   time from the resume POST to the first successful read.
3. Record whether the marker content is identical.

## 6. Fork (AC-7)

1. `t curl -s -X POST -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d '{"count":2,"timeout":900}' $GW/sandboxes/$ID/fork | tee /tmp/fork.json`
2. Extract both child IDs and tokens from the `sandbox` entries; confirm no `error` entry.
3. In child A: read `/root/marker.txt` (must equal the parent's), then write
   `/root/child-a.txt`. In child B: read `/root/marker.txt`, then check that
   `/root/child-a.txt` does not exist.
4. Confirm the parent is still `running` (`GET /sandboxes/$ID`).
5. Record the fork duration and the time until both children answered.

## 7. Kill (AC-8)

1. `DELETE $GW/sandboxes/<id>` for the parent and both children (expect 204 each).
2. `GET $GW/v2/sandboxes` lists none of them; `GET $GW/sandboxes/$ID` returns 404.

## 8. Warm second create (AC-10, AC-9)

1. Repeat section 2 with a fresh sandbox; record the elapsed time to `running`.
2. Kill it.
3. Fill the timing table in `tests/RESULTS.md` (see below).

## 9. Redeploy and teardown (AC-11, AC-12)

1. `scripts/teardown.sh` then `scripts/deploy.sh` from the repo root; repeat section 1.
2. `scripts/teardown.sh` again; verify `kubectl --context $KCTX get ns agentenv-system`
   returns not found, and that `plans/decisions.md` documents the node leftovers.

## 10. Blast-radius check (AC-13)

Compare against the section 0 snapshots:

```bash
kubectl --context $KCTX -n agent-sandbox-system get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount --no-headers | diff /tmp/before-agent-sandbox-system.txt -
kubectl --context $KCTX get ns -o name | sort | diff /tmp/before-namespaces.txt -     # only agentenv-system may differ
gcloud container node-pools list --cluster barkland-test --zone us-central1-a --project gke-ai-eco-dev --format='value(name)' | sort | diff /tmp/before-nodepools.txt -
kubectl --context $KCTX get clusterrole,clusterrolebinding 2>/dev/null | grep -i agentenv || echo none
```

## What to write in `tests/RESULTS.md`

1. Header: date, commit of this repo, AgentENV version, images used (with digests if
   available), node name and machine type, kernel version of node and guest.
2. Results table:

   | AC | Title | Result | Evidence (short) | Timing |
   |---|---|---|---|---|

   One row per AC-1 to AC-13. Result is `pass`, `fail`, or `blocked` (with the blocker).
3. Timing table:

   | Step | Seconds | Method |
   |---|---|---|
   | Cold create to running (AC-3) | | POST to first `state: running`, 2 s polling |
   | Command round-trip (AC-4) | | one `echo` via SDK or curl |
   | Pause (AC-5) | | POST duration |
   | Resume to first command (AC-6) | | POST to first successful marker read |
   | Fork of 2 to both answering (AC-7) | | POST to both children's first read |
   | Warm second create (AC-10) | | POST to first `state: running` |

4. Which command path was used for AC-4 (SDK, curl, or aenv CLI) and any deviation from
   this plan.
5. Failures: the exact command, the response, and the pod log excerpt.

## Failure triage hints

- Runtime pod not Ready: `K logs ds/agentenv-node --tail=200`. Look for asset downloads
  (Firecracker, kernel, tools drive, overlaybd tools from GitHub and ghcr.io), `/dev/kvm`
  errors, `ublk` device errors, or `/var/lib/aenv` permission errors. Check the init
  container: `K logs ds/agentenv-node -c <init-name>`.
- Gateway 502 or 503 on create: `K logs deploy/agentenv-gateway --tail=100` and
  `K logs deploy/agentenv-scheduler --tail=100`; check `GET /nodes` is non-empty (the
  scheduler discovers nodes through the headless Service's EndpointSlices, so the node
  pod must be Ready).
- Create hangs in conversion: node disk pressure (`df -h /workspace` via `kubectl exec` into the runtime
  pod).
- Command execution fails but the sandbox is running: check that you send both
  `X-API-Key` and `X-Access-Token`, and the correct sandbox port (49983 for envd).
- Resume fails with 409: the sandbox was already running or already killed; check state.
- Fork 409: the source has volume mounts (not in this plan) or is not running.

## Cleanup

Kill every sandbox you created (`GET /v2/sandboxes` must be empty), stop the port-forward,
remove `/tmp/e2b-venv` (do not create `kubectl debug` pods at any point), and leave the
deployment up for the reviewer unless the orchestrator asks for teardown.
