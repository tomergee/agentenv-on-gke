# Testing guide: smoke test and whole-set sweep

This explains what the two test tools in `tests/` do, how to run them, how to read their
output, and what today's runs measured. The acceptance criteria they implement are in
[`plans/acceptance-criteria.md`](../plans/acceptance-criteria.md); recorded runs are in
[`tests/RESULTS.md`](../tests/RESULTS.md).

## What is under test

AgentENV v0.2.2 deployed on the `barkland-test` cluster (project `gke-ai-eco-dev`,
`us-central1-a`): a gateway and scheduler on the default pool and one privileged runtime pod
per node on the `kvm-pool-c2` nested-virtualization pool. Clients reach the gateway through
`kubectl port-forward`; every request carries the shared API key in `X-API-Key`. Commands
inside sandboxes go through the gateway to `envd`, the in-VM daemon, using the
`e2b-sandbox-id` and `e2b-sandbox-port: 49983` headers.

## Prerequisites (once per machine)

```bash
# cluster access and the deployment
kubectl config get-contexts gke_gke-ai-eco-dev_us-central1-a_barkland-test
./scripts/deploy.sh                      # idempotent; reuses the cluster's Secrets

# tools: curl, python3, bc, and the E2B SDK in a venv for in-sandbox commands
uv venv /tmp/aenv-test-venv --python 3.12
uv pip install --python /tmp/aenv-test-venv/bin/python e2b
```

Both tools fetch the API key themselves with `scripts/get-api-key.sh` and start a
port-forward if the gateway URL does not answer. They kill every sandbox they create on
exit, including on failure or Ctrl-C.

## The smoke test: `tests/smoke.sh`

One end-to-end pass through the sandbox lifecycle against a single image. It prints one
`AC-n PASS|FAIL: <evidence>` line per criterion, a timing table, and exits non-zero if
anything failed.

| Step | What it does | Pass rule |
|---|---|---|
| AC-1 | Lists pods in `agentenv-system` | Every pod Running with all containers ready; the runtime pods are on the expected pool |
| AC-2 | `GET /health`, then `GET /nodes` until the first runtime pod appears (up to `NODES_WAIT`, default 300 s, because node records lag after a scheduler restart) | Health 204; the node is listed with status ready |
| AC-3 | `POST /sandboxes-cold` with `$IMAGE` (1 CPU, 512 MB), polls `GET /sandboxes/{id}` | 201, the returned id matches the response header, state reaches running within 600 s |
| AC-4 | Runs a command via the E2B SDK (`tests/e2b_commands.py run`), writes a marker file, reads it back through envd's `/files` endpoint | Command exit 0 with expected output; marker readable |
| AC-5 | `POST /sandboxes/{id}/pause` | 204; the sandbox is listed as paused, not running |
| AC-6 | `POST /sandboxes/{id}/resume` (JSON body), reads the marker, runs a command | 201 with the same id; marker intact; command works |
| AC-7 | `POST /sandboxes/{id}/fork` with `count: 2` | Both children answer; marker inherited; a write in one child is not visible in the other; the parent keeps running |
| AC-8 | Deletes the parent and both children | 204 each; none listed; `GET` on the parent returns 404 |
| AC-10 | Creates the same image again, and a third while the second runs | Both reach running (measures the warm path) |
| AC-9 | Timing table | Every row recorded |

AC-11 to AC-13 (repeatable redeploy, teardown, and the "nothing outside the namespace
changed" check) are manual procedures in `plans/test-plan.md`; their evidence is in
`tests/RESULTS.md`.

### Run it

```bash
# default image, ubuntu:22.04, pulled from Docker Hub and converted on the node
tests/smoke.sh

# a pre-converted SWE-bench Verified image (lazy-loaded, no conversion)
IMAGE=us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified:sweb.eval.x86_64.django__django-11099 tests/smoke.sh

# a private standard OCI image (pulled with the runtime's Workload Identity credentials, converted on the node)
IMAGE=us-docker.pkg.dev/gke-ai-eco-dev/swebench-mirror/swebench-verified:sweb.eval.x86_64.astropy__astropy-12907 tests/smoke.sh
```

Knobs: `IMAGE`, `GW` (default `http://127.0.0.1:8080`), `KEY`, `PY` (venv python),
`SBX_TIMEOUT` (sandbox TTL, default 900 s; the v0.2.2 default is only 15 s, so the test
always sets it), `NODES_WAIT`, `POOL` (default `kvm-pool-c2`).

### Reading the timing table

- **create**: from the `POST` to state running. For a standard OCI image the first create
  on a node includes the pull and the overlaybd conversion (40 to 50 s for a 1.3 GB image);
  later creates on that node take about 2.3 s. For a pre-converted image every node is
  about 3.5 to 5 s.
- **rtt**: one `echo` round trip through the SDK, about 0.3 to 0.5 s.
- **pause / resume**: sub-second to about 1.6 s; resume preserves memory and disk.
- **fork**: about 1.5 s until both children answer.
- **warm**: the second create; on a multi-node cluster round-robin can send it to a node
  that has not converted a standard image yet, so it can be as slow as the first create.
  Pre-converted images do not have this effect.

## The whole-set sweep: `tests/sweep.sh`

Runs every converted SWE-bench Verified image once, in parallel, and produces a per-image
CSV and a summary. Per image (`tests/sweep-one.sh <instance>`): cold create from
`$IMG_REPO:<instance>` with `CPU`/`MEM` (default 2 / 4096), wait for running, run
`test -d /testbed; python --version` through the SDK, kill. Only instances whose converted
tag exists are run; instances already present in the CSV are skipped (`RESUME=1`), so a
re-run fills gaps. On exit it kills anything still running or paused.

```bash
tests/sweep.sh                                   # all 500, 8 in parallel
PAR=4 tests/sweep.sh                             # gentler
LIST=/tmp/mine.txt SKIP_TAG_CHECK=1 tests/sweep.sh   # a custom instance list, skip the tag check
grep -v ',pass,' tests/sweep-results.csv         # anything that did not pass
```

Outputs: `tests/sweep-results.csv` (`instance,status,http,create_s,cmd_s,total_s,note`;
statuses `pass`, `create_failed`, `not_running`, `cmd_failed`) and `tests/sweep-summary.md`
(counts, p50/p90/max, failures). To retry failures, delete their rows and re-run.

## Results recorded on 2026-09-23

| Run | Result |
|---|---|
| Smoke, `ubuntu:22.04`, 1 node | 13/13 criteria; cold create 5.4 s, warm 2.4 s, pause 0.4 s, resume 0.85 s, fork 1.3 s |
| Smoke, SWE-rebench image from the private registry, 4 nodes | 10/10; first create 51 s (pull + conversion), warm 2.3 s once a node has converted it |
| Sweep, all 500 SWE-bench Verified images, pre-converted, 4 nodes, 8 parallel | **500/500 pass**; create p50 3.6 s, p90 4.0 s, max 9.0 s; first command p50 1.1 s; about 8 minutes total; about 125 creates per node, 0 failures |

## Troubleshooting

- **401 on every call** although the key is right: the gateway injects its own copy of the
  key and reads it only at startup. If the Secret was rotated, restart the gateway
  (`kubectl -n agentenv-system rollout restart deployment/agentenv-gateway`). `deploy.sh`
  now does this automatically when it changes a Secret.
- **AC-2 waits then fails, everything else works**: node records are rebuilt from
  heartbeats for up to a few minutes after a scheduler or runtime restart.
- **Resume returns 415**: send `Content-Type: application/json` (the scripts do).
- **Create of a private image fails to pull**: check the `registry-creds` sidecar log in the
  runtime pod and that the pod's service account has `roles/artifactregistry.reader` on
  that repository (`plans/decisions.md` lists the grants).
- **Lazy loading fails with "relative URL without a base"**: the runtime image is stock
  v0.2.2; the overlay pins a patched build (`build/runtime/`).
- **Something left running**: `curl -H "X-API-Key: $KEY" $GW/v2/sandboxes?state=running`
  and delete by id; `scripts/teardown.sh` also kills everything first.
- **Node logs**: `kubectl -n agentenv-system logs <agentenv-node-pod> -c agentenv`.
