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

## Node state left behind by teardown, and how to clear it (2026-09-23, tester; consolidated by developer round 2)

`scripts/teardown.sh` removes the sandboxes, the runtime DaemonSet and the namespace only.
Left on the runtime node **by design** (it is a hostPath and a host kernel module), measured
right after a teardown that followed two image conversions:

| Leftover | Size / state | Clear with |
|---|---|---|
| `/var/lib/aenv/env` on the node (mounted at `/workspace/env` in the runtime pod): runtime deps (Firecracker, guest kernel, tools drive, overlaybd tools, regctl), image cache with the converted `ubuntu:22.04` and `debian:12`, snapshot store, persisted paused sandboxes, and the generated access-token seed when the seed Secret is absent | 530 MB after two images | `scripts/clear-node-state.sh` (one-shot privileged pod in a temporary `agentenv-cleanup` namespace; refuses to run while `agentenv-system` exists). Recreating the node pool also clears it. |
| `/var/lib/aenv/config` (rendered runtime config) | 4 KB | same |
| `ublk_drv` kernel module loaded with `ublks_max=4096` by the init container; `/dev/ublk-control` | loaded, no devices in use | same script (`modprobe -r ublk_drv`), or a node reboot |
| Host sysctls applied by the init container | not persisted on COS (read-only `/etc`); lost on reboot | nothing to do |

Inspect while the system runs with `kubectl -n agentenv-system exec ds/agentenv-node -c agentenv -- sh -c 'df -h /workspace; du -sh /workspace/env/*'`
(never `kubectl debug node/...`, which creates a privileged pod outside the namespace).
Node disk after teardown: 10.4 GB of 94 GB used (pre-prototype baseline about 10 GB).

Observation: the runtime pod takes 2 to 5 minutes to leave `Terminating` with zero
sandboxes (172 s and 301 s measured; gateway and scheduler pods are gone within 10 s). No
`FailedPreStopHook` event was recorded. Reported to the developer in `tests/RESULTS.md`.

## Developer round 2: review fixes (2026-09-23)

- **H1 teardown order.** `scripts/teardown.sh` kills every running and paused sandbox through
  the gateway, deletes the runtime DaemonSet while the scheduler is still serving, then deletes
  the namespace. The DaemonSet keeps upstream's `terminationGracePeriodSeconds: 3600` and its
  preStop drain; sandboxes still running at pod deletion are what that drain protects.
- **M1 Secrets outside kustomize.** `deploy/overlays/barkland-test` no longer generates Secrets,
  and a `$patch: delete` removes the base's empty `agentenv-auth`; `scripts/deploy.sh` creates
  `agentenv-auth` and `agentenv-runtime-secrets` from the gitignored `.secrets/` files before
  `kubectl apply -k`. `kubectl kustomize` and `kubectl diff -k` now work on a clean checkout.
- **M2 control plane placement.** Gateway and scheduler carry
  `nodeSelector cloud.google.com/gke-nodepool=default-pool`; only the runtime pod runs on the
  kvm node.
- **M3 image digests.** `ghcr.io/kvcache-ai/aenv-server@sha256:7ce67e1f078c461ebe00a88328c190d7cdefd12988d35dbea209a87787e0117b`
  (the `v0.2.2-amd64` tag; an OCI index), `agentenv-gateway@sha256:452e3e4a0667f9d40c50bbf7d7a5b828fcb8245eb817f914da837dfc28e039ed`,
  `agentenv-scheduler@sha256:7d336fbfdc29e18b598f057f53bc9790edb034266105d750b77de84bfeff2464`
  (both `v0.2.2`, built by Cloud Build `85deda9d`).
- **M5 home_path.** The image's `AENV_HOME_PATH=/workspace/env` overrides the config, so the
  overlay now sets `home_path = "/workspace/env"`; the node path is `/var/lib/aenv/env`.
- **O-5 envd reachable with the API key alone (accepted limitation).** Cold creates without
  `secure: true` issue no per-sandbox `envdAccessToken`, so anyone holding the shared key can
  run commands in any such sandbox. Unchanged for the prototype; `secure: true` on create
  would require `X-Access-Token` on envd traffic.
- **L1 hostPID (accepted).** The init container's host preparation needs `hostPID`, which is
  pod-wide; accepted next to `privileged`, since upstream expects the same steps to be run on
  the host by hand.
- **L6 snapshot cache.** The upstream `[snapshot]` section exposes no node-local cache size
  key in v0.2.2 (the commented `cache_max_size_gb` belongs to `[backend.oss]`, unused with
  `posix_fs`), so nothing was changed; the snapshot store itself lives on the same 100 GB disk.
