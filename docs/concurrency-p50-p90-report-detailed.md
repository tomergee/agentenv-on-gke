# Cold start vs snapshot resume at 1, 10 and 100 concurrent sandboxes: P50 / P90

**Date:** 2026-09-23 (run 2; run 1 from earlier the same day shown for comparison).
**System:** AgentENV v0.2.2 with the local Artifact Registry redirect patch, on GKE cluster
`barkland-test`: 4 runtime nodes `c2-standard-8` (8 vCPU, 32 GB, nested virtualization,
Container-Optimized OS), gateway and scheduler on the default pool. Images: distinct
pre-converted (overlaybd) SWE-bench Verified task images, 2 CPU / 2048 MB per sandbox.
Load generator runs inside the cluster (`tests/concurrency.py` as a Job) so numbers exclude
any laptop port-forward. Placement was round-robin: 25 per node at N=100.

## 1. Cold start (create from image, boot, first command)

All N `POST /sandboxes-cold` calls are issued at the same instant; times are measured from
that instant.

| N | Pass (run 2) | Create returned p50 / p90 (s) | Running p50 / p90 (s) | First command done p50 / p90 (s) | Command alone p50 / p90 (s) | Per node | Run 1 running p50 / p90 (s) |
|---|---|---|---|---|---|---|---|
| 1 | 1/1 | 1.64 / 1.64 | 1.65 / 1.65 | 2.02 / 2.02 | 0.37 / 0.37 | 0 / 1 / 0 / 0 | 2.74 / 2.74 |
| 10 | 10/10 | 1.64 / 2.54 | 1.65 / 2.54 | 2.03 / 3.18 | 0.38 / 0.6 | 2 / 3 / 2 / 3 | 2.55 / 2.63 |
| 100 | 100/100 | 7.49 / 9.46 | 7.5 / 9.47 | 9.57 / 10.48 | 1.95 / 2.46 | 25 / 25 / 25 / 25 | 8.81 / 9.74 |

## 2. Snapshot resume (pause all, then resume all at the same instant)

The same sandboxes are paused together, left 5 s, then resumed together with
`POST /sandboxes/{id}/resume`. Times are measured from the resume instant (pause time from
the pause instant).

| N | Pass (run 2) | Pause p50 / p90 (s) | Resume returned p50 / p90 (s) | Running after resume p50 / p90 (s) | First command after resume p50 / p90 (s) | Command alone after resume p50 / p90 (s) | Run 1 running-after-resume p50 / p90 (s) |
|---|---|---|---|---|---|---|---|
| 1 | 1/1 | 0.15 / 0.15 | 0.1 / 0.1 | 0.1 / 0.1 | 0.44 / 0.44 | 0.34 / 0.34 | 0.11 / 0.11 |
| 10 | 10/10 | 0.18 / 0.19 | 0.15 / 0.16 | 0.15 / 0.16 | 0.72 / 0.75 | 0.54 / 0.59 | 0.17 / 0.22 |
| 100 | 98/100 | 0.7 / 2.16 | 2.64 / 4.98 | 2.64 / 4.99 | 6.72 / 7.33 | 3.75 / 4.69 | 3.91 / 5.01 |

## 2b. Start from a template (snapshot once, then create N from it)

`MODE=template`. Setup, once per run: 12 source sandboxes are cold-started from one image
(`django__django-11099`), primed with a Python command, snapshotted with
`POST /sandboxes/{id}/snapshots {"name": "swe-tpl-django-11099"}` and killed. Twelve, because
the prototype's snapshot repository is node-local and placement is round-robin: the first
snapshot under the name on each node creates the alias (HTTP 201, 2.6 to 2.9 s for a 2 GB
guest), later ones on the same node answer 400 `alias ... already points to ..., cannot rebind`
and are counted as "existing". Setup took 5 to 6 s. Then N `POST /sandboxes
{"templateID": "swe-tpl-django-11099", "timeout": 600}` are issued at the same instant (v0.2.2
accepts `templateID` only on the v1 path; `POST /v2/sandboxes` answers 405). Sandboxes inherit
the template's 2 CPU / 2 GB.

| N | Pass | POST returned p50 / p90 (s) | Running p50 / p90 (s) | First command done p50 / p90 (s) | Command alone p50 / p90 (s) | Node CPU during the burst |
|---|---|---|---|---|---|---|
| 1 | 1/1 | 0.14 / 0.14 | 0.14 / 0.14 | 0.56 / 0.56 | 0.42 / 0.42 | 0 to 1 % |
| 10 | 10/10 | 0.14 / 0.15 | 0.14 / 0.16 | 0.63 / 0.65 | 0.48 / 0.50 | 1 to 4 % |
| 100 | 100/100 | 0.93 / 1.54 | 0.94 / 1.55 | 5.74 / 6.33 | 4.78 / 5.36 | not sampled |
| 100 (repeat, sampled) | 100/100 | 0.87 / 1.46 | 0.88 / 1.46 | 5.70 / 6.30 | 4.78 / 5.41 | 100 % for 6 s, then 10 to 20 % |

The sampled repeat ran the one-second `/proc/stat` sampler of section 4 on one runtime node:
CPU busy per second from the burst instant was 87, 100, 100, 100, 100, 100, 56, 30, 18 %
(cold start in section 4: 8 s at 100 %). `MemAvailable` on that node went from 29.5 GB to a
minimum of 28.3 GB while 25 restored guests started and answered their first command, and was
back at 29.7 GB 30 s later: about 50 MB of private memory per sandbox, against about 140 MB
for a cold-booted idle sandbox (section 6). The 25 guests map the same 2 GB memory file
(v0.2.2 restores with Firecracker's file-backed memory, `load_snapshot_file`), so clean pages
are shared page cache and only written pages are copied.

## 3. Reading the numbers

- **1 and 10 are indistinguishable.** Cold start: about 1.7 s to running, 2.0 s to the first
  command. Resume: 0.10 to 0.15 s to running, 0.44 to 0.72 s to the first command. Ten
  simultaneous starts across four nodes cost nothing over one.
- **Resume is 10 to 15 times faster than cold start at low concurrency** (0.15 s against
  1.7 s to running) and about 2 to 3 times faster at 100 (2.6 s against 7.2 s median).
- **At 100, both paths degrade, cold start more.** Cold start median 7.2 to 7.5 s, P90 9.4 s;
  resume median 2.6 s, P90 5.0 s; pause itself slows to a median 0.7 s, P90 2.2 s. The first
  command after a mass resume takes longer than after a single one (median 6.7 s from the
  resume instant, of which about 4 s is the command itself) because 24 neighbours are
  faulting their memory images in at the same time.
- **Run 1 and run 2 agree** within about 0.1 s at 1 and 10 and within about 1 s at 100.
- **Template starts are the fast and the dense path, with the same knee.** 0.14 s to running
  at 1 and 10 (12 times faster than cold), 0.9 s median at 100 (8 times faster), 211 starts
  without a failure, and about a third of the host memory per sandbox. But 25 restores per
  8-vCPU node still pin the CPU for 6 s, so the first command at 100 lands at 5.7 s instead of
  9.6 s: what remains is not the boot but the work of 25 restored guests faulting their pages in
  and running at once under nested virtualization.

## 4. Why 100 is slow: the node is CPU-saturated during the boot burst

A one-second sampler inside a runtime pod during a 100-burst (run 4) showed the node's 8
vCPUs at **100 % busy for 8 consecutive seconds** while the 25 guests booted, with the
kernel's CPU pressure indicator rising to 52 %, then back to under 1 % once they were running.
Per-node timelines confirm the shape: all 25 requests arrive within 0.5 s, and all 25 take
6 to 9 s inside the node and finish together, which is uniform slowdown, not a queue.

Coarser samplers miss this: `kubectl top` (60 s averages) peaked at 29 % CPU and 35 % memory,
and AgentENV's own node view 12 s after the burst read 17 to 21 % CPU and 5 to 10 GB used:

| Node (run 3, 12 s after all 100 running) | CPU | Memory used |
|---|---|---|
| agentenv-node-hq67j | 17 % | 5.7 / 31.3 GB |
| agentenv-node-5j8pl | 17 % | 5.7 / 31.3 GB |
| agentenv-node-stb8s | 17 % | 5.3 / 31.3 GB |
| agentenv-node-dkvd2 | 21 % | 10.0 / 31.3 GB |

So the answer to "is there enough hardware for 100" is: to **run** 100, comfortably (about
5 to 10 GB of 31 GB per node, a few percent CPU); to **start** 100 at the same instant, no.
Starting more than about 10 VMs per 8-vCPU node at once saturates it for several seconds.
The same saturation causes the intermittent create failures below.

## 5. Failures

Every failure across all runs was the same: an HTTP 500 on create, logged by the runtime as
`Failed to set machine configuration: Request failed: client error (Connect): Connection refused (os error 111)`,
the Firecracker API socket not yet listening when the runtime connects, with no retry. It
happens only under the burst, at a rate that varies run to run with the CPU starvation:

| 100-burst | Passed | Running p50 / p90 (s) | Start-race failures |
|---|---|---|---|
| run 1, socket timeout 3 s | 97/100 | 8.06 / 9.8 | 3 |
| run 1b, timeout 15 s | 99/100 | 8.81 / 9.74 | 1 |
| run 2 | 100/100 | 7.5 / 9.47 | 0 |
| run 2 resume (its create phase) | 98/100 | 7.21 / 9.54 | 2 |
| run 3, instrumented | 99/100 | 7.34 / 9.36 | 1 |
| run 4, CPU-sampled | 95/100 | 7.27 / 8.76 | 5 |

No failure occurred on the resume path in any run. Raising `[firecracker] socket_timeout_secs`
from 3 to 15 did not remove it (the error is a refused connection, not a timeout). Every
failed create was cleaned up by the runtime; no sandbox was left behind after any run.

## 6. How 100 sandboxes ran on 32 vCPUs and 116 GB

On paper the 100-burst declared 200 vCPUs and 200 GB against four nodes with 8 vCPUs and
about 29 GB allocatable each. It ran because declarations are not consumption anywhere in
this stack, and an idle microVM consumes almost nothing:

- **CPU.** A guest vCPU is a host thread scheduled by KVM. An idle guest halts and its thread
  sleeps. Measured: 25 idle sandboxes per node used about 17 to 21 % of the node's CPU,
  roughly 60 millicores each (envd plus guest timer ticks under nested virtualization). The
  declared 50 vCPUs per node only mattered during the boot burst, which is exactly when the
  node hit 100 % for 8 s (section 4).
- **Memory.** Firecracker maps guest RAM as ordinary anonymous memory; pages become real only
  when the guest touches them. A freshly booted guest touches its kernel, init, envd and the
  few files it read. Measured: node memory went from about 2 to 6 GB idle to 5 to 10 GB with
  25 sandboxes, about 140 MB per sandbox against 2 GB declared. Guest kernels boot with
  memory-reclaim tuning and the runtime uses ballooning, so memory a guest stops using
  returns to the host. The root filesystem is a lazily loaded block device, not memory.
- **Nothing enforced the declarations.** Kubernetes never sees the VMs (the runtime pod
  requests 2 CPUs and 8 GB, the microVMs live outside its accounting); the AgentENV scheduler's
  `node_resource_limit` was left unset, so placement stayed round-robin; the runtime does not
  reserve or pin guest memory.

Where it breaks: if all 100 became active at once, CPU contention comes first (each active
guest gets about a sixth of a core), then memory (25 guests touching their full 2 GB want
50 GB on a 32 GB node; the kernel kills Firecracker processes, and the DaemonSet is
configured so the runtime survives while the VMs are the victims), then disk if writable
layers grow. The density claim therefore rests on idleness, which matches the 80 to 90 %
idle assumption for RL rollouts waiting on inference and tool calls; workloads that run tests
or builds inside the sandbox have larger working sets and a lower safe ratio. The practical
rule: set the scheduler's allocation limits from measured working sets, not declared sizes,
so a burst of activity degrades into queuing instead of kills.

## 7. What would change the curve

1. **Templates (committed snapshots) for the task images**, so every start is a resume.
   Measured in section 2b: 0.14 s to running at 1 and 10, 0.9 s median at 100, no failures in
   211 starts, about 50 MB of private host memory per sandbox at start. The 25-per-node burst
   is still CPU-bound for 6 s, so items 2 and 4 still apply. In the prototype the template had
   to be built on every node (node-local snapshot store) and aliases cannot be re-pointed;
   cross-node templates need a shared snapshot repository (Filestore or a native Cloud Storage
   backend; gap 28).
2. **More vCPUs per simultaneous start**: about 10 starts per 8 vCPUs is the knee here.
   Bare metal (no nested-virtualization tax) and bigger machines both help; so does staggering
   bursts on the client side.
3. **A pre-spawned Firecracker pool sized for the burst** and an upstream retry on the
   machine-configuration call (gap 34).
4. **Admission control** in the scheduler so a burst larger than a node's start capacity
   queues instead of contending.

## Method notes

`tests/concurrency.py` (`MODE=create|resume|template`; template mode reads `TEMPLATE`,
`SOURCES` and `PRIME_CMD`) as a Kubernetes Job (`tests/concurrency-job.yaml`); raw per-sandbox
JSON lines in `tests/concurrency-results/run2-*.jsonl` (run 2), `burst-*.jsonl` and
`resume-*.jsonl` (run 1), `run3-create-100-util.jsonl` and `run4-create-100-cpu.jsonl`
(instrumented 100-bursts), `template-{1,10,100}.jsonl` and `template-100-cpu.jsonl` with the
sampler output in `template-100-cpu-sampler.txt` (section 2b). The template
`swe-tpl-django-11099` is left on the four nodes for reuse. A harness bug in run 2's first resume-100 attempt (a failed thread
never reached a barrier, stalling the rest) was fixed before the reported run; the stalled
attempt is not included.
