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
