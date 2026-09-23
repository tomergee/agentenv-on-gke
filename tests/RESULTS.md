# Test results: AgentENV prototype on `barkland-test`

**Date:** 2026-09-23 (06:30 to 07:00 UTC)
**Repo state tested:** branch `prototype` at `d3a81f6` (deploy tree from `34de466`)
**AgentENV:** v0.2.2 (`/nodes` reports `version 0.2.2`)
**Verdict:** AC-1 to AC-13 all **pass**. The system was left **running** (3/3 pods Ready,
zero sandboxes) after the final redeploy.

## Environment

| Item | Value |
|---|---|
| Cluster / context | `barkland-test`, `gke_gke-ai-eco-dev_us-central1-a_barkland-test`, GKE 1.35.8 |
| Runtime node | `gke-barkland-test-kvm-pool-c2-6b3ad0c5-axvc`, `c2-standard-8`, pool `kvm-pool-c2`, COS kernel `6.12.94+`, nested virtualization |
| Guest | kernel `6.1.175`, `ubuntu:22.04` (22.04.5) and `debian:12` (bookworm) images, 1 vCPU, 1024 MB |
| Runtime image | `ghcr.io/kvcache-ai/aenv-server@sha256:7ce67e1f078c461ebe00a88328c190d7cdefd12988d35dbea209a87787e0117b` (tag `v0.2.2-amd64`) |
| Gateway image | `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv/agentenv-gateway@sha256:452e3e4a0667f9d40c50bbf7d7a5b828fcb8245eb817f914da837dfc28e039ed` (`v0.2.2`) |
| Scheduler image | `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv/agentenv-scheduler@sha256:7d336fbfdc29e18b598f057f53bc9790edb034266105d750b77de84bfeff2464` (`v0.2.2`) |
| Init container | `busybox:1.36` (host prep: `ublk_drv ublks_max=4096`, sysctls) |
| Access | `kubectl port-forward svc/agentenv-gateway 8080:8080`; header `X-API-Key` |
| Client for commands | official `e2b` Python SDK (`/tmp/aenv-test-venv`), see "Command path" |

Runs performed with `tests/smoke.sh`:

1. `ubuntu:22.04` (image already converted on the node by the developer's sanity check): all pass.
2. `debian:12` (never used on this node, so a true cold create with pull and conversion): all pass.
3. `ubuntu:22.04` again after the AC-11 teardown and redeploy: all pass.

Plus the manual AC-11, AC-12 and AC-13 steps below.

## Results

| AC | Title | Result | Evidence (short) | Timing |
|---|---|---|---|---|
| AC-1 | All pods Ready | pass | `agentenv-gateway`, `agentenv-scheduler`, `agentenv-node` all `1/1 Running`, 0 restarts, on the `kvm-pool-c2` node; events show image pulls of 1.2 s, 1.6 s and 3.7 s | pods Ready about 20 s after `deploy.sh` starts |
| AC-2 | Gateway health and node discovery | pass | `GET /health` -> **204** (not 200; see O-4); `GET /nodes` -> one node, `id` = node pod name, `status ready`, 8 vCPU, 31.3 GiB; `GET /nodes/<id>` -> `sandboxCount 0`, disk metrics | |
| AC-3 | Cold create reaches running | pass | `POST /sandboxes-cold` -> 201, `x-agentenv-sandbox-id` header equals `sandboxID`, response has `templateID` (`docker.io/library/ubuntu@sha256:281c…`), `envdVersion 0.5.15`; `state: running` | **5.39 s** true cold (`debian:12`, pull + overlaybd conversion; POST alone 5.06 s); 2.38 s when the image was already converted |
| AC-4 | Command through the gateway | pass | E2B SDK: `exit 0`, stdout `hello-from-agentenv`, guest kernel `6.1.175`, `PRETTY_NAME="Ubuntu 22.04.5 LTS"`; marker written with `files.write`, read back through `GET /files` | echo round trip **0.29 s** |
| AC-5 | Pause | pass | `POST /pause` -> 204; `GET /v2/sandboxes?state=paused` lists the ID, `?state=running` does not | **0.43 s** |
| AC-6 | Resume with state preserved | pass | `POST /resume` -> 201, same `sandboxID`; marker content identical; `echo alive-after-resume` ok; `state running` | **0.85 s** from POST to first successful marker read |
| AC-7 | Fork into two children | pass | `POST /fork {"count":2}` -> 201, two `sandbox` entries with distinct new IDs, no `error`; both children serve the parent's marker; a file written in child A is 404 in child B and in the parent; command in child B ok; parent still `running` | fork call **0.53 s**; both children answering **1.34 s** after the POST |
| AC-8 | Kill | pass | three `DELETE` -> 204; `GET /v2/sandboxes` lists none; `GET /sandboxes/<parent>` -> 404 | 0.4 s per delete |
| AC-9 | Timings recorded | pass | table below | |
| AC-10 | Warm second create | pass | fresh `ubuntu:22.04` sandbox `running` in **2.42 s**; a third one created while the second was running in **2.41 s** | |
| AC-11 | Redeploy is repeatable | pass | `teardown.sh` (301 s, see O-1) then `deploy.sh`: all three rollouts succeed, pods Ready in **23 s**; the API key was reused from `deploy/overlays/barkland-test/.secrets/` (identical before and after); full smoke run passes afterwards | |
| AC-12 | Teardown leaves only documented node state | pass | after `teardown.sh` (172 s): `get ns agentenv-system` -> NotFound; `get all,secrets,configmaps,sa,role,rolebinding -n agentenv-system` -> no resources. Node inspected with a temporary sysadmin debug pod (deleted afterwards): `/var/lib/aenv` 530 MB (`env/` deps + image cache, `config/`), `ublk_drv` loaded, `/dev/ublk-control` present, disk 10.4 of 94 GB. Documented with clear commands in `plans/decisions.md` | |
| AC-13 | Nothing outside the namespace modified | pass | diffs against the start-of-test snapshots are empty: `agent-sandbox-system` pods and restart counts (3 pods) unchanged; namespace list unchanged (20, `agentenv-system` present in both); node pools `default-pool kvm-pool-c2 sandbox-pool` unchanged; no cluster-scoped RBAC mentioning agentenv; no debug pods left. The Artifact Registry repo predates this plan and is logged in `plans/decisions.md` | |

## Timings

All wall-clock, measured by `tests/smoke.sh` from the laptop through the port-forward,
so they include one round trip over the port-forward per call. Nested virtualization on a
`c2-standard-8`; upstream figures are not comparable.

| Step | Seconds | Method |
|---|---|---|
| Cold create to running (AC-3), image never seen by the node (`debian:12`) | 5.39 | POST duration (5.06) plus 1 s polling to the first `state: running` |
| Cold create to running (AC-3), image already converted (`ubuntu:22.04`) | 2.38 | same |
| Command round-trip (AC-4) | 0.29 | one `echo` via the E2B SDK (envd process API through the gateway) |
| Pause (AC-5) | 0.43 | POST duration |
| Resume to first read (AC-6) | 0.85 | POST to first successful `GET /files` of the marker, 0.2 s polling |
| Fork of 2 to both answering (AC-7) | 1.34 | POST (call itself 0.53) to both children serving the marker |
| Warm second create (AC-10) | 2.42 | same as AC-3 |
| Create while another runs (AC-10) | 2.41 | same |
| Kill (AC-8) | 0.4 | DELETE duration |
| Redeploy to all pods Ready (AC-11) | 23 | `deploy.sh` wall clock |
| Teardown (AC-11, AC-12) | 301, 172 | `teardown.sh` wall clock; dominated by the runtime pod's termination (O-1) |

Repeatability: the three runs agree within about 0.1 s on every step except the cold
create, which depends on whether the image is already converted on the node.

## Command path and deviations from the test plan

- **Command execution used the E2B Python SDK**, but not `Sandbox.connect`. The SDK's
  connect calls `POST /v2/sandboxes/{id}/connect`, which v0.2.2 does not serve, so it
  raises "Paused sandbox not found" for a running sandbox. `tests/e2b_commands.py` builds
  the `Sandbox` object directly from the ID and routes envd traffic through the gateway with
  `extra_sandbox_headers = {X-API-Key, e2b-sandbox-id, e2b-sandbox-port: 49983}`. With
  that, `commands.run`, `files.write` and `files.read` work; the process API is envd's
  Connect-RPC stream, so this is a real command execution, not the `/files` fallback.
- **Header routing, not the `/proxy` prefix.** `GET /proxy/health` returns 404 on
  v0.2.2; the working form is the original path (`/health`, `/files?path=…`) plus the
  `e2b-sandbox-id` and `e2b-sandbox-port` headers. The test plan's curl examples were
  adjusted accordingly.
- **No `X-Access-Token` needed.** Cold creates without `secure` return no
  `envdAccessToken`, and envd answered with only the API key (see O-5).
- AC-10 was extended with a "create while another is running" measurement, as the
  criterion suggested.
- `tests/smoke.sh` is written for the macOS default bash 3.2 (no associative arrays).

## Defects and observations for the developer and reviewer

None blocks the acceptance criteria. Ordered by impact.

- **O-1 Slow runtime pod termination.** With zero sandboxes, `agentenv-node` stays
  `Terminating` for 2 to 5 minutes (172 s and 301 s measured); gateway and scheduler are
  gone within 10 s. No `FailedPreStopHook` event; `curl` and `jq` exist in the image, so
  the preStop drain loop should exit at once. Suspect the runtime's own shutdown path
  (`terminationGracePeriodSeconds` is 3600). Repro: `scripts/teardown.sh` while polling
  `kubectl -n agentenv-system get pods`. Impact: slow teardown, node drains and upgrades.
- **O-2 E2B SDK `Sandbox.connect` is incompatible with v0.2.2** (uses the v2 connect
  path). Workaround in `tests/e2b_commands.py`. Affects any client relying on the SDK's
  connect or on newer upstream docs.
- **O-3 `/proxy` prefix not served by v0.2.2** (newer upstream docs mention it). Header
  routing works.
- **O-4 `GET /health` returns 204**, while the acceptance criteria say 200. Treated as
  pass (success without a body); the criteria text should say 2xx.
- **O-5 envd is reachable with the API key alone** for cold-created sandboxes (no
  `secure`, so no per-sandbox `envdAccessToken` is issued). Anyone holding the shared API
  key can run commands in any sandbox. Expected for the prototype's single-key model, but
  worth a line in the review; `secure: true` on create should be tried in a follow-up.
- **O-6 First-ever create on a fresh node** (runtime asset download plus the first image
  conversion) was measured by the developer at 7.3 s; the tester's 5.39 s cold figure is
  with assets already present and a new image.
- **O-7 Teardown leaves 530 MB and a loaded kernel module on the node** (documented in
  `plans/decisions.md`, by design of the hostPath approach).

## Cleanup state at handback

- Sandboxes: `GET /v2/sandboxes` -> `[]`.
- Debug pods: none (`kubectl -n default get pods | grep node-debugger` -> none).
- Port-forwards: stopped.
- Deployment: running, 3/3 Ready, disk 10.4 of 94 GB on the node.
- Venv `/tmp/aenv-test-venv` kept for the reviewer and re-runs (contents: `e2b`).
