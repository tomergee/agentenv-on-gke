# gVisor snapshot clock test (2026-09-23)

**Question:** do a sandbox's clocks stop while it is snapshotted and restored?

**Answer:** no. With GKE Pod Snapshots on gVisor, every clock we measured (wall clock,
`CLOCK_MONOTONIC`, `CLOCK_BOOTTIME` and `/proc/uptime`) jumped forward by the real time that
passed between the checkpoint and the restore. None of them froze. The process itself
survived the restore and carried on from the checkpointed state.

## Setup

- Cluster `barkland-test` (gke-ai-eco-dev, us-central1-a, GKE 1.35.8-gke.1036000).
- Pod Snapshots enabled for this test (`gcloud beta container clusters update --enable-pod-snapshots`).
- A one-node gVisor pool `clock-snap-pool` on n2-standard-4, because whole-pod snapshots
  don't support the E2 machines in the existing sandbox pool.
- Bucket `gke-ai-eco-dev-clocksnap-0923` (us-central1, hierarchical namespace, no soft
  delete), with Workload Identity access for the pod's service account and object access for
  the GKE service agent.
- `PodSnapshotStorageConfig` plus a manual-trigger `PodSnapshotPolicy` grouping by a
  `clock-test` label, `whole-pod` scope, `postCheckpoint: resume`.
- A plain gVisor pod running a Python loop that logs, once per second, a random nonce chosen
  at process start, a counter, `time.time()`, `time.monotonic()`,
  `clock_gettime(CLOCK_BOOTTIME)` and `/proc/uptime`, to stdout and to a file on the root
  filesystem.

## Procedure and host timeline

Seconds relative to the snapshot request:

| Step | Host time |
|---|---|
| Pod `clock-a` running about 60 s, then `PodSnapshotManualTrigger` created | 0.0 |
| Checkpoint done; `PodSnapshot` Ready | about 11 |
| `clock-a` deleted | 11.9 |
| Offline for 3 minutes | |
| Identical pod `clock-b` created | 194.2 |
| `clock-b` Ready; event "Successfully restored the pod from PodSnapshot" | 198.6 |
| Logs collected | 263.4 |

## Results

`clock-b`'s log file (restored with the root filesystem) holds one unbroken run with a
single nonce, `1cda6b37`, the same as `clock-a`. The only discontinuity is between counter
65 (the last line before the checkpoint) and 66 (the first line after the restore):

| Clock | Before (i=65) | After (i=66) | Jump | Verdict |
|---|---|---|---|---|
| Counter | 65 | 66 | 1 | Process resumed where it was checkpointed |
| Wall clock (`time.time()`) | 1790140835.813 | 1790141030.263 | 194.45 s | Jumped by real elapsed time |
| `CLOCK_MONOTONIC` | 68.065 | 262.515 | 194.45 s | Jumped by real elapsed time; not frozen |
| `CLOCK_BOOTTIME` | 68.065 | 262.515 | 194.45 s | Same as monotonic |
| `/proc/uptime` | 68.06 | 262.51 | 194.45 s | Same as monotonic |

The 194.45 s matches the host time from the checkpoint to the restored pod starting.

## Other observations

- **The process survived.** Same nonce, and the counter continued from 65, so the restored
  pod's memory came from the snapshot; nothing restarted.
- **The restore point is the checkpoint, not the deletion.** With
  `postCheckpoint: resume`, `clock-a` kept running and logged counters 66 to 72 before it
  was deleted. `clock-b` restarted from 65, so those later lines exist only in `clock-a`'s
  log. Work done between a checkpoint and pod deletion is lost on restore.
- **Timers fire late, not early.** The 1-second sleep in progress at the checkpoint
  returned right after restore, because monotonic time had already passed its deadline.
- Checkpoint took about 11 s and restore about 4 s from pod creation to Ready, for a small
  Python process.

## What this means for design

- Code in a restored sandbox sees a sudden forward jump in every clock, including
  monotonic time. Timeouts, leases, TTL caches, rate limiters and heartbeats all expire at
  once after a restore. Tokens with short lifetimes (OAuth, signed URLs) are likely expired.
- Nothing goes backwards, so monotonic-based ordering stays safe.
- Any design that treats "paused" time as free should assume the guest can see how long it
  was paused.
- AgentENV (Firecracker) was not tested; its behavior may differ.

## Caveats

One run, one small process, one 3-minute gap, on a single n2 node. Not tested: long gaps,
restore on a different node, NTP or timezone interactions, or other clock types
(`CLOCK_REALTIME_COARSE`, `CLOCK_PROCESS_CPUTIME_ID`).

## Artifacts

Raw logs, events and the scripts were in `/tmp/clocksnap/` on the laptop that ran the test
(`clock-a.log`, `clock-b.log`, `clock-b-file.log`, `events.txt`, `run.sh`, `run.out`). That
directory is temporary.
