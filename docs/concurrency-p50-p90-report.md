# AgentENV on GKE: cold start, snapshot resume and template start at 1, 10 and 100 concurrent sandboxes

Measured 2026-09-23. All latencies are P50 / P90 in seconds across the N sandboxes of a
burst, timed from the instant the N requests were issued. The full tables, the run 1
comparison, per-second CPU traces and methodology are in
[`concurrency-p50-p90-report-detailed.md`](concurrency-p50-p90-report-detailed.md).

## What was deployed

- **Software:** AgentENV v0.2.2. Gateway and scheduler built from the upstream tag with Cloud
  Build, one replica each. Runtime is the upstream `aenv-server:v0.2.2` image plus a six-line
  patch for Artifact Registry's relative redirects.
- **Cluster:** GKE `barkland-test`, project `gke-ai-eco-dev`, zone `us-central1-a`, GKE 1.35.8,
  Container-Optimized OS, kernel 6.12.
- **Sandbox nodes:** 4 × c2-standard-8 in node pool `kvm-pool-c2` (Intel Cascade Lake, 8 vCPU,
  32 GB, 100 GB pd-balanced boot disk, no local SSD), nested virtualization. 32 vCPU and about
  125 GB in total for sandboxes.
- **Control plane nodes:** gateway and scheduler on the `default-pool` e2-standard-4 nodes.
- **Images:** the 500 SWE-bench Verified task images, converted once to overlaybd and stored in
  Artifact Registry (`us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified`).
  Nodes lazily load blocks into a 15 GB image cache and a 15 GB remote-block cache.
- **Snapshots:** 5 GB node-local snapshot cache; paused sandboxes and templates stay on the node
  that created them.
- **Sandbox size:** 2 vCPU / 2 GB declared per sandbox, not reserved by AgentENV, so 100
  sandboxes declare 6 times the pool's CPU and 1.6 times its memory.
- **Tuning:** Firecracker API socket timeout raised from 3 s to 15 s.
- **Prototype limits:** no TLS, one shared API key, access by port-forward.

## How it was measured

The load generator is a Kubernetes Job on the default pool, so requests never leave the
cluster. One thread per sandbox, all released together by a barrier; lifecycle calls go to the
gateway's REST API and the in-sandbox command (`echo`, `test -d /testbed`) goes through the
gateway's envd proxy with the E2B Python SDK 2.51.0. Three experiments:

- **Cold start**: N `POST /sandboxes-cold`, each with a different task image, then wait for
  `running` and run the command.
- **Snapshot resume**: the same N sandboxes paused together, left 5 s, resumed together with
  `POST /sandboxes/{id}/resume`, timed from the resume instant.
- **Template start**: one source sandbox per node is cold-started, primed with a Python
  import, snapshotted under one name (2.6 to 2.9 s for a 2 GB guest) and killed; then N
  `POST /sandboxes {"templateID": name}` at once.

Distinct images: the cold and resume bursts use 100 different task images, one per sandbox
(the same 100 in both, all Django instances, so they share most image layers and the node
block caches were warm across them); the template bursts use one image, `django__django-11099`,
through one template (the per-record `instance` field there is only the thread's label). The
separate whole-set sweep in `tests/sweep-summary.md` covered all 500 images once.

Every run kills its sandboxes at the end. During the 100-bursts a one-second `/proc/stat`
sampler ran inside a runtime pod on one node; `kubectl top` averages over a minute and hides
the burst.

## Results

Cold start (create from image and boot):

| Sandboxes started at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 1.6 / 1.6 | 2.0 / 2.0 | 1/1 |
| 10 | 1.6 / 2.5 | 2.0 / 3.2 | 10/10 |
| 100 | 7.5 / 9.5 | 9.6 / 10.5 | 100/100 |

Snapshot resume (pause all, then resume all; pause itself 0.15 s at 1 and 10, 0.7 / 2.2 s at 100):

| Sandboxes resumed at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 0.1 / 0.1 | 0.4 / 0.4 | 1/1 |
| 10 | 0.1 / 0.2 | 0.7 / 0.8 | 10/10 |
| 100 | 2.6 / 5.0 | 6.7 / 7.3 | 98/100 |

Template start (snapshot once per node, then create N from it):

| Sandboxes started at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 0.1 / 0.1 | 0.6 / 0.6 | 1/1 |
| 10 | 0.1 / 0.2 | 0.6 / 0.7 | 10/10 |
| 100 | 0.9 / 1.5 | 5.7 / 6.3 | 100/100 (two runs) |

Node CPU on one runtime node while 25 of the 100 started there: cold start 100 % for 8 s,
template start 100 % for 6 s, then 10 to 20 % while the commands ran, then a few percent.

## Takeaways

1. **1 and 10 cost the same.** Ten simultaneous starts across four nodes behave like one:
   about 1.6 s to running cold, 0.1 s from a snapshot or template.
2. **Resume and template start are the sub-second paths.** 0.1 to 0.15 s to running against
   1.6 s for a cold boot, first command answered in under a second. A template makes every
   start a resume without needing a paused sandbox to exist first.
3. **100 at once saturates the nodes.** Booting or restoring 25 guests per 8-vCPU node pins the
   CPU at 100 % for 6 to 8 s, which is why the medians jump to 7.5 s cold, 2.6 s resume and
   0.9 s template, and why the first command at 100 lands at 5.7 to 9.6 s. About 10
   simultaneous starts per 8 vCPUs is the knee on these nested-virtualization nodes.
4. **Cold-start failures are the same saturation.** 0 to 5 creates per 100 failed with a
   refused connection to a Firecracker process that had not started listening yet; AgentENV
   does not retry that call. Resume never failed on the resume path and 211 template starts
   never failed. No sandbox was left behind by any run.
5. **Running 100 is easy; starting 100 at once is not.** An idle cold-booted sandbox costs
   about 60 millicores and 140 MB, so 25 per node used a few percent CPU and 5 to 10 GB.
   Declared sizes are not reserved anywhere, which is fine while sandboxes are mostly idle and
   dangerous if they all get busy: set the scheduler's allocation limits from measured working
   sets.
6. **Templates are also the dense path.** 25 template starts on one node lowered its available
   memory by 1.2 GB in total, about 50 MB per sandbox, because the guests map the same 2 GB
   memory file and only pages they write become private copies. The boot is gone; the CPU cost
   of 25 restored guests faulting their pages in and running at once under nested
   virtualization is what remains.

## Compared with Agent Substrate on the same hardware (2026-09-24)

The same harness method was run against Agent Substrate (upstream `31a5e0ba`) on **4 ×
c2-standard-8 with nested virtualization, the node shape used here**, with the same 100 Django
images and 2 vCPU / 2 GiB sandboxes, so N=100 is 25 per node on all three. Full tables in
`tomergee/substrate-explorations`, `docs/benchmarks/2026-09-24-concurrency-1-10-100/README-4-nodes.md`
(an earlier 10-node Substrate run is kept in `README.md` there).

| Path (seconds to running, P50 / P90) | N | AgentENV (here) | Substrate gVisor | Substrate microVM (Kata) | agent-sandbox v1.0.3 pods (runc, same nodes) |
|---|---|---|---|---|---|
| Template start, image cached | 1 / 100 | 0.14 / 0.9 | 1.7 / 2.6 | 3.6 / 7.2 | 0.25 / 0.9 (warm pool adoption) |
| Cold boot, image cached | 1 / 100 | 1.6 / 7.5 | 0.23 / 1.17 | 0.92 / 9.7 | 1.5 / 3.2 |
| First command after a cold boot | 100 | 9.6 / 10.5 | 2.4 / 2.5 | 10.1 / 13.6 | 5.7 / 6.4 |
| Pause then resume | 1 / 10 / 100 | 0.10 / 0.15 / 2.6 | 0.20 / 0.25 / 1.61 | 0.28 / 0.35 / 3.0 | 4.2 / 6.7 / 159 (gVisor + Pod Snapshots, 3 nodes; snapshot to GCS 3.0 / 11.5 / 94 s first) |
| Durable snapshot then resume | 1 / 100 | not available | 3.8 / 2.7 | 3.7 / 6.7 | 4.2 / 159 (same path; 91 of 100 within 15 min) |
| Guest command round trip | 1 / 100 | 0.4 / 4.8 | 0.03 / 0.7 | 0.04 / 0.3 | 0.1 / 0.5 (exec via API server; the 3.0 first reported was a client artifact) |
| Failures | all | 0 to 5 per 100 cold | 0 of 1,800 | 0 of 1,800 | 0 of 233 |

The agent-sandbox column ran on these same `kvm-pool-c2` nodes with the AgentENV runtime pods
resident and without image streaming, so its distinct-image modes stop at N=10; the harness is
`tests/asbench/`. Its warm pool is the second-fastest start and needs no snapshot machinery. Its
suspend, resume and golden-snapshot warm pools on GKE Pod Snapshots were measured on a 3-node
gVisor pool: durable and correct (state verified), 4 s single, but snapshots and restores serialize
per node so a 100-wide pause and resume takes minutes; a golden pool of 100 restored members fills
in 172 s against 6 s from a cached image. Fork does not exist.

AgentENV keeps the fastest start by an order of magnitude when a template exists, because its
memory snapshot is a node-local file map; Substrate's gVisor class has the fastest cold start
(a process, not a VM) and the lowest command latency; Substrate's microVM class matches
AgentENV's cold boot at low concurrency and, like AgentENV, becomes CPU-bound at 25 guests per
8 vCPU. Substrate adds a durable snapshot path and showed no memory pressure at 25 restored
2 GiB Kata guests per 32 GB node. Its new gaps at this density are cleanup: 31 of 3,600 actors
stuck in DELETING or CRASHED after bulk deletes.

## How many fit per node (fill run, 1 vCPU / 512 MB sandboxes)

A separate run on 2026-09-24 kept adding sandboxes in batches of 40 across the same 4 nodes
until a batch mostly failed (`tests/concurrency.py`, `MODE=fill`; raw records in
`tests/concurrency-results/fill-1c512m.jsonl`). Sandboxes were declared 1 vCPU / 512 MB, the
smallest a microVM allows, each ran one command and then sat idle.

| Running per node | Create to running p50 / p90 (s) | Node CPU busy | Node memory used | Failed creates in the batch |
|---|---|---|---|---|
| 10 | 2.8 / 3.6 | 57 to 66 % | 10 to 25 % | 0 of 40 |
| 30 | 2.7 / 3.3 | 64 to 83 % | 16 to 30 % | 1 of 40 |
| 60 | 4.0 / 4.3 | 82 to 97 % | 24 to 38 % | 2 of 40 |
| 87 | 5.6 / 6.0 | 84 to 99 % | 32 to 47 % | 3 of 40 |
| 107 | 8.5 / 9.8 | 88 to 99 % | 38 to 53 % | 1 of 40 |
| 117 | 20.4 / 24.2 | 93 to 98 % | 41 to 56 % | 0 of 40 |
| 120 | 14.0 / 62.6 | 94 to 96 % | 41 to 57 % | 27 of 40, run stopped |

480 sandboxes were running at the end (118 to 123 per node); a command in the oldest one
still answered in 0.65 s. The limit is CPU, not memory: idle microVMs cost about 60 to 80
millicores each, so 100 of them saturate 8 vCPUs while memory sits near 40 percent. Shrinking
the declared size from 2 vCPU / 2 GB to 1 vCPU / 512 MB changed neither the idle cost nor the
ceiling. Failures below the ceiling were the same Firecracker start race as in the bursts;
at 120 per node they became `WaitReady` timeouts. Practical ceiling on these nodes: about 100
idle sandboxes per 8 vCPU, with about 10 simultaneous starts per node before latency climbs.

## What would improve it

- Templates for the task images (measured above): they remove the boot, the start failures and
  most of the per-sandbox memory, but a 25-per-node burst is still CPU-bound, so size or
  stagger bursts as well. In v0.2.2 a template must exist on every node and an alias cannot be
  re-pointed, so template updates need new names; cross-node templates need a shared snapshot
  repository.
- More vCPUs per simultaneous start, or staggered bursts; bare metal removes the
  nested-virtualization tax.
- A pre-spawned Firecracker pool sized for the burst, and an upstream retry on the
  machine-configuration call.
- Scheduler admission limits so oversized bursts queue instead of contending.

## Data and code

Raw per-sandbox records: `tests/concurrency-results/run2-*.jsonl` (cold and resume),
`template-*.jsonl`, and the CPU sampler outputs `run4-create-100-cpu.jsonl` and
`template-100-cpu-sampler.txt`. Harness: `tests/concurrency.py` (`MODE=create|resume|template`)
run as the Job in `tests/concurrency-job.yaml`. Deployment: `deploy/overlays/barkland-test/`;
decisions and dates: `plans/decisions.md`.
