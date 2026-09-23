# Cold start vs snapshot resume: P50 / P90 at 1, 10 and 100 concurrent sandboxes

2026-09-23, AgentENV v0.2.2 on GKE `barkland-test`: 4 runtime nodes (8 vCPU, 32 GB, nested
virtualization), pre-converted SWE-bench Verified images, 2 CPU / 2 GB per sandbox, load
generated inside the cluster. All numbers are P50 / P90 in seconds, measured from the
instant the N requests were issued. Full tables, run 1 comparison and methodology:
[`concurrency-p50-p90-report-detailed.md`](concurrency-p50-p90-report-detailed.md).

## Cold start (create from image and boot)

| Sandboxes started at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 1.6 / 1.6 | 2.0 / 2.0 | 1/1 |
| 10 | 1.6 / 2.5 | 2.0 / 3.2 | 10/10 |
| 100 | 7.5 / 9.5 | 9.6 / 10.5 | 100/100 |

## Snapshot resume (pause all, then resume all)

| Sandboxes resumed at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 0.1 / 0.1 | 0.4 / 0.4 | 1/1 |
| 10 | 0.1 / 0.2 | 0.7 / 0.8 | 10/10 |
| 100 | 2.6 / 5.0 | 6.7 / 7.3 | 98/100 |

Pause itself: 0.15 s at 1 and 10, 0.7 / 2.2 s at 100.

## Start from a template (snapshot once, then create N from it)

Setup, once per run and per node: cold-start one sandbox from the image, run a command in
it, snapshot it under a name (2.6 to 2.9 s for a 2 GB guest), kill it. Then N
`POST /sandboxes {"templateID": name}` at the same instant.

| Sandboxes started at once | Running (s) | First command done (s) | Passed |
|---|---|---|---|
| 1 | 0.1 / 0.1 | 0.6 / 0.6 | 1/1 |
| 10 | 0.1 / 0.2 | 0.6 / 0.7 | 10/10 |
| 100 | 0.9 / 1.5 | 5.7 / 6.3 | 100/100 (two runs) |

## Takeaways

1. **1 and 10 cost the same.** Ten simultaneous starts across four nodes behave like one.
2. **Resume is the fast path.** 0.1 to 0.15 s to running against 1.7 s for a cold boot, and
   the first command answers in under a second. That meets a sub-second pause/resume target.
3. **100 at once saturates the nodes.** Booting 25 guests per 8-vCPU node pinned the CPU at
   100 % for 8 s (measured with a one-second sampler inside a runtime pod), which is why the
   medians jump to 7.5 s cold and 2.6 s resume. About 10 simultaneous starts per 8 vCPUs is the
   limit before this happens.
4. **Failures are the same saturation.** 0 to 5 creates per 100 failed with a refused
   connection to a Firecracker process that had not started listening yet; AgentENV does not
   retry that call. No resume ever failed, and no sandbox was left behind.
5. **Running 100 is easy; starting 100 at once is not.** Idle sandboxes cost about
   60 millicores and 140 MB each, so 25 per node used a few percent CPU and 5 to 10 GB.
   Declared sizes (2 CPU / 2 GB) are not reserved anywhere, which is fine while sandboxes
   are mostly idle and dangerous if they all get busy: set the scheduler's allocation limits
   from measured working sets.
6. **A template makes every start a resume, and it is the dense path.** To running: 0.14 s
   at 1 and 10 (cold 1.6 s) and 0.9 s median at 100 (cold 7.5 s); 211 template starts, no
   failures. Host memory barely moved: 25 starts per node from one 2 GB template lowered the
   node's available memory by 1.2 GB in total, about 50 MB per sandbox, because the guests
   map the same memory file and only the pages they write become private copies (a cold-booted
   idle sandbox holds about 140 MB). The burst still pins the CPU, 100 % for 6 s at 25 per node
   against 8 s cold, which is why the first command at 100 waits until 5.7 s: the boot is gone,
   the page faults of 25 restored guests under nested virtualization are not.

## What would improve it

- Templates for the task images (measured above): they remove the boot and the start
  failures, but a 25-per-node burst is still CPU-bound, so size or stagger bursts as well.
  In v0.2.2 the template must exist on every node (node-local snapshot store) and an alias
  cannot be re-pointed, so template updates need new names.
- More vCPUs per simultaneous start, or staggered bursts; bare metal removes the
  nested-virtualization tax.
- A pre-spawned Firecracker pool sized for the burst, and an upstream retry on the
  machine-configuration call.
- Scheduler admission limits so oversized bursts queue instead of contending.

Raw data: `tests/concurrency-results/run2-*.jsonl` and `template-*.jsonl`; harness:
`tests/concurrency.py` (`MODE=create|resume|template`).
