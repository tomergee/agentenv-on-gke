# Concurrency report: 1, 10 and 100 sandboxes started at the same moment

**Date:** 2026-09-23. **System:** AgentENV v0.2.2 (with the local Artifact Registry
redirect patch) on `barkland-test`, 4 runtime nodes `c2-standard-8` (8 vCPU, 32 GB, nested
virtualization, Container-Optimized OS), gateway and scheduler on the default pool, images
pre-converted to overlaybd in `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images`.

## Method

`tests/concurrency.py`, run as a Kubernetes Job on the default pool (`tests/concurrency-job.yaml`)
so the load generator talks to the gateway Service directly rather than through a laptop
port-forward. For a burst of N:

1. N threads each pick a distinct SWE-bench Verified image and wait on a barrier.
2. All N issue `POST /sandboxes-cold` at the same instant (2 CPU, 2048 MB, 900 s TTL).
3. Each thread polls `GET /sandboxes/{id}` every 250 ms until `running`.
4. Each thread runs one command through the E2B SDK via the gateway (`echo ready && test -d /testbed`).
5. Every sandbox stays alive until all N have finished their first command; per-node counts
   are read from `GET /nodes` after a 12 s settle; then all N are deleted.

Per sandbox we record: time until the create call returned, time until state `running`, time
until the first command completed (all from the barrier release), and the command's own
duration. Images were 100 distinct instances (`build/convert/verified-instances.txt`
lines 101 to 200), so no two sandboxes in a burst shared an image.

## Results

| Run | Pass | Create call returned (s) p50 / p90 / max | Running (s) p50 / p90 / max | First command done (s) p50 / p90 / max | Command alone (s) p50 / p90 / max | Per node at peak | Kill all (s) |
|---|---|---|---|---|---|---|---|
| N=1 | 1/1 | 2.73 / 2.73 / 2.73 | 2.74 / 2.74 / 2.74 | 3.27 / 3.27 / 3.27 | 0.53 / 0.53 / 0.53 | 0 / 0 / 0 / 0 | 0.04 |
| N=10 | 10/10 | 2.54 / 2.62 / 2.8 | 2.55 / 2.63 / 2.81 | 3.17 / 3.24 / 3.4 | 0.59 / 0.62 / 0.64 | 3 / 2 / 2 / 3 | 0.41 |
| N=100, socket timeout 3 s | 97/100 | 8.05 / 9.8 / 10.72 | 8.06 / 9.8 / 10.72 | 9.91 / 10.94 / 11.56 | 1.56 / 2.25 / 2.77 | 24 / 25 / 25 / 23 | 3.44 |
| N=100, socket timeout 15 s | 99/100 | 8.8 / 9.73 / 10.85 | 8.81 / 9.74 / 10.85 | 10.67 / 11.21 / 11.52 | 1.91 / 2.29 / 2.63 | 25 / 24 / 25 / 25 | 3.45 |

Start-time distribution at N=100 (seconds from the barrier to `running`):

- socket timeout 3 s: 3-4 s: 4, 4-5 s: 9, 5-6 s: 15, 6-7 s: 11, 7-8 s: 7, 8-9 s: 21, 9-10 s: 21, 10-11 s: 9
- socket timeout 15 s: 5-6 s: 13, 6-7 s: 17, 7-8 s: 4, 8-9 s: 25, 9-10 s: 33, 10-11 s: 7

Observations:

- **1 and 10 behave the same.** Ten simultaneous starts across four nodes cost nothing over
  one: about 2.6 s to running and 3.2 s to the first command completing. Placement was
  3 / 2 / 2 / 3 sandboxes per node.
- **100 is CPU-bound per node.** With 25 Firecracker boots per 8-vCPU node, starts serialize:
  the fastest sandbox is running in 3.7 s, the median in 8 to 9 s, the slowest in 10.9 s,
  and the first command completes for everyone within 11.6 s. Placement was an even
  24 to 25 per node. The command itself slows from 0.5 s to about 1.6 to 1.9 s under load.
- **Whole-burst wall clock:** all 100 sandboxes created, commanded and killed in about
  45 s of job time, including the load generator's package install.
- **Deleting 100 sandboxes took 3.4 s** (sequential DELETE calls from one client).

## Failures and root cause

| Run | Instance | Status | HTTP | Error |
|---|---|---|---|---|
| N=100, socket timeout 3 s | django__django-13417 | create_failed | HTTP 500 | Start failed: set machine configuration: connection refused on the Firecracker API socket |
| N=100, socket timeout 3 s | django__django-13670 | create_failed | HTTP 500 | Start failed: set machine configuration: connection refused on the Firecracker API socket |
| N=100, socket timeout 3 s | django__django-14915 | create_failed | HTTP 500 | Start failed: set machine configuration: connection refused on the Firecracker API socket |
| N=100, socket timeout 15 s | django__django-14155 | create_failed | HTTP 500 | Start failed: set machine configuration: connection refused on the Firecracker API socket |

All failed creates returned HTTP 500 immediately; the runtime log line is
`failed to start sandbox error=Failed to set machine configuration: Request failed: client error (Connect): Connection refused (os error 111)`.
AgentENV spawns a Firecracker process per sandbox and then configures it over its API
socket; under a 25-way burst per node the connect occasionally hits the socket before the
process is listening, and there is no retry. Raising `[firecracker] socket_timeout_secs`
from 3 to 15 reduced the failures from 3 to 1 per 100 but did not remove them, because the
error is a refused connection rather than a timeout. The failed sandboxes were cleaned up by
the runtime; no orphans remained after any run.

The pre-spawned Firecracker pool (`[pool.firecracker]`, enabled, low watermark 2, fill
concurrency 4) absorbs only the first couple of starts per node; the rest of a burst spawns
fresh processes.

## Recommendations

1. **Retry the machine-configuration call on connection refused** inside AgentENV (a few
   attempts over a second). Worth an upstream issue alongside the redirect patch.
2. **Size the Firecracker pool for the expected burst**, for example a high watermark of 32
   per node with a higher fill concurrency, so bursts consume pre-spawned processes. This
   trades a little idle memory for start-time predictability.
3. **Rate-limit or stagger bursts on the client side** for now: 10 simultaneous starts per
   node saw no degradation; 25 did.
4. **Admission control:** set the scheduler's `node_resource_limit` so a burst larger than a
   node's capacity queues or fails fast instead of contending.
5. Treat a 500 on create as retriable in the RL SDK backend, with the metadata-based
   reconciler covering any orphan.

## How to rerun

```bash
kubectl -n agentenv-system create configmap agentenv-concurrency \
  --from-file=concurrency.py=tests/concurrency.py --from-file=instances.txt=<100 instance tags> \
  --dry-run=client -o yaml | kubectl -n agentenv-system apply -f -
sed "s/__N__/100/; s/__LABEL__/burst-100/" tests/concurrency-job.yaml | kubectl -n agentenv-system apply -f -
kubectl -n agentenv-system logs job/agentenv-concurrency-100 | grep '^{' > tests/concurrency-results/burst-100.jsonl
```

Raw results: `tests/concurrency-results/*.jsonl` (one JSON line per sandbox, plus a summary line).

## Part 2: snapshot resume, 1, 10 and 100 at the same moment

Same harness with `MODE=resume`: create N (cold, as in part 1), run one command, then **pause
all N at the same instant**, wait 5 s, **resume all N at the same instant**
(`POST /sandboxes/{id}/resume`), poll to `running`, and run one command. Pause and resume are
same-node operations on AgentENV's node-local snapshot (memory pages plus the sealed disk
layer); no registry or image work is involved.

| Run | Pass | Pause call (s) p50 / p90 / max | Resume call returned (s) | Running after resume (s) | First command after resume (s) | Command alone after resume (s) | Per node |
|---|---|---|---|---|---|---|---|
| N=1 | 1/1 | 0.18 / 0.18 / 0.18 | 0.11 / 0.11 / 0.11 | 0.11 / 0.11 / 0.11 | 0.46 / 0.46 / 0.46 | 0.35 / 0.35 / 0.35 | 1 / 0 / 0 / 0 |
| N=10 | 10/10 | 0.18 / 0.19 / 0.19 | 0.17 / 0.21 / 0.23 | 0.17 / 0.22 / 0.24 | 0.67 / 0.75 / 0.76 | 0.51 / 0.56 / 0.56 | 2 / 2 / 3 / 3 |
| N=100 | 100/100 | 1.54 / 3.09 / 3.96 | 3.89 / 5.0 / 5.89 | 3.91 / 5.01 / 5.89 | 6.98 / 7.69 / 8.22 | 3.15 / 4.21 / 6.17 | 25 / 25 / 25 / 25 |

Running-after-resume distribution at N=100 (seconds from the barrier): 1-2 s: 8, 2-3 s: 28, 3-4 s: 24, 4-5 s: 29, 5-6 s: 11.

Observations:

- **1 and 10 resume in well under a second.** Pause 0.18 s; resume returns in 0.11 to 0.17 s
  with the sandbox already `running`; the first command completes 0.46 to 0.67 s after the
  resume was issued. This is the path that fits the "pause/resume under 1 s" requirement.
- **100 at once contends again, but less than cold create.** Median resume 3.9 s (max 5.9 s)
  against 8 to 9 s for cold create; first command after resume median 7.0 s (max 8.2 s). Pause
  also slowed to a median 1.5 s (max 4.0 s) when 25 sandboxes per node paused together, since
  each pause captures dirty memory pages and seals the disk layer. **100 of 100 passed**; no
  start-race failures on this path because no Firecracker process is spawned.
- The post-resume command is slower than the pre-pause one at N=100 (median 3.2 s against
  1.6 s), consistent with first-touch page faults being served from the memory image while 24
  neighbours do the same.

### Where the cold-create seconds go (single sandbox, no contention)

From the node's own timers and a traced single create: the create call returned in 1.97 s;
inside the runtime the create span took 1.3 s, so about 0.7 s is gateway, scheduler
round-trip and HTTP overhead before the node starts. Inside the node: image manifest and
config fetches from the registry average 0.26 s and 0.49 s (the config fetch is skipped once
cached), creating the overlaybd block device averages 0.68 s, and the remainder is spawning
or taking a pooled Firecracker process, booting the guest kernel, pivoting to the image and
waiting for envd. All of it runs under nested virtualization. A resume skips the manifest
fetch, the device creation and the kernel boot, which is why it lands at 0.1 to 0.2 s.

What would move cold creates toward the resume numbers: templates (committed snapshots) for
the task images so that every start is a resume; a larger pre-spawned Firecracker pool; a
warm manifest/config cache; bare-metal nodes to remove the nested-virtualization tax.

## Addendum

Run 2 of both experiments, with P50/P90 tables and the one-second CPU sampling that proves
the 100-burst saturates the node's 8 vCPUs for about 8 s, is in
[`concurrency-p50-p90-report.md`](concurrency-p50-p90-report.md).

