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
