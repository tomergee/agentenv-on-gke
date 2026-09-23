# Decisions and deviations log

Append-only. Each entry: date, who, what, why.

- 2026-09-23, developer: runtime image is the public `ghcr.io/kvcache-ai/aenv-server:v0.2.2-amd64`
  (built upstream from the same `Dockerfile.agentenv` the Kubernetes runtime uses) instead of a
  local build; gateway and scheduler are built with Cloud Build into
  `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv` from a trimmed context (`services/`,
  `deploy/docker/`) with `TARGETARCH=amd64`, which plain `docker build` leaves unset.
- 2026-09-23, developer: image caches lowered to 15 GB each (image cache, remote blocks) in the
  overlay's `agentenv.toml`; the runtime node has a 100 GB boot disk and no local SSD.
- 2026-09-23, developer: host preparation runs as a privileged `busybox` init container with
  `hostPID`, entering the host namespaces to load `ublk_drv` (reloading with `ublks_max=4096`
  only when no ublk devices are in use) and apply upstream's sysctls; COS has a read-only root,
  so nothing is persisted under `/etc` (re-applied on every pod start).
- 2026-09-23, developer: the runtime pod keeps upstream's hostPath `/var/lib/aenv` mounted at
  `/workspace`, so Firecracker, the guest kernel, the tools drive and overlaybd tools are
  downloaded to the node on first start rather than served from the image's pre-baked copy.
- 2026-09-23, developer: first deploy verified. All three pods Ready in about 20 s; the runtime
  downloaded Firecracker, the guest kernel, regctl and overlaybd tools (about 100 MB) in 3 s;
  `ublk_drv` was reloaded from `ublks_max=64` to 4096. Sanity check through the gateway:
  `POST /sandboxes-cold` with `ubuntu:22.04` (1 vCPU, 512 MB) returned 201 in 6.5 s including
  the image pull and overlaybd conversion, the sandbox was `running` at 7.3 s, envd `/health`
  via the proxy returned 204, `DELETE` took 0.4 s. Node disk after: 11 % of 95 GB.
- 2026-09-23, developer: known cosmetic warning at startup: the runtime reports
  `net.ipv4.neigh.default.gc_thresh*: unable to read` because those sysctls are not visible in
  the pod's network namespace; the init container sets them on the host, which is what matters.
  Two `heartbeat rpc failed` warnings appear before the scheduler is reachable, then clear.

## Orchestrator: Artifact Registry repository created (2026-09-23)

The orchestrator created the Docker repository `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv` to hold the gateway and scheduler images. This is the one project-level change outside namespace `agentenv-system`; AC-13 allows it because it is recorded here. Teardown of the prototype does not delete it.

## Orchestrator: API paths corrected for v0.2.2

The proposal was written against upstream `main` (2f48c9c), which has `POST /v2/sandboxes/{id}/connect`. Tag v0.2.2 only has `/sandboxes/{id}/resume` and `/sandboxes/{id}/connect`, and its cold-create `timeout` defaults to 15 s. The acceptance criteria and test plan use the v0.2.2 paths and pass `timeout` explicitly.

## Tester: node state left behind by teardown, and how to clear it (2026-09-23)

`scripts/teardown.sh` deletes namespace `agentenv-system` only. Inspected with a temporary
`kubectl debug node/gke-barkland-test-kvm-pool-c2-6b3ad0c5-axvc --profile=sysadmin` pod
(deleted afterwards) right after a teardown:

| Leftover | Size / state | Clear with |
|---|---|---|
| `/var/lib/aenv/env` (runtime deps: Firecracker, guest kernel, tools drive, overlaybd tools, regctl; image cache with the converted `ubuntu:22.04` and `debian:12`; snapshot store; persisted-sandboxes; the auto-generated access-token seed) | 530 MB after two images | `kubectl debug node/<node> --profile=sysadmin --image=busybox -- rm -rf /host/var/lib/aenv` (then delete the debug pod). Recreating the node pool also clears it. |
| `/var/lib/aenv/config` (rendered runtime config) | 4 KB | same |
| `ublk_drv` kernel module, loaded with `ublks_max=4096` by the init container; `/dev/ublk-control` | loaded, no devices in use | `modprobe -r ublk_drv` from a sysadmin debug pod via `chroot /host`; a node reboot also clears it |
| Host sysctls applied by the init container | not persisted on COS (read-only `/etc`); lost on reboot | nothing to do |

Node disk after teardown: 10.4 GB of 94 GB used (the pre-prototype baseline was about 10 GB).

Observation: the runtime pod takes 2 to 5 minutes to leave `Terminating` with zero
sandboxes (172 s and 301 s measured; gateway and scheduler pods are gone within 10 s). No
`FailedPreStopHook` event was recorded. Reported to the developer in `tests/RESULTS.md`.
