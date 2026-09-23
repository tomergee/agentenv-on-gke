# PRD: AgentENV prototype on `barkland-test`

**Status:** draft, 2026-09-23. Owner: product manager agent. Companion documents:
[execution-plan.md](execution-plan.md), [acceptance-criteria.md](acceptance-criteria.md),
[test-plan.md](test-plan.md), and the design proposal
[agentenv-gke-standalone-and-sdk-backend-proposal.md](agentenv-gke-standalone-and-sdk-backend-proposal.md).

## Problem

agent-sandbox runs one pod per sandbox. That caps density at the per-node pod limit, keeps
idle sandboxes fully reserved, and pays pod scheduling, image pull and container start on
every create. On the customer cluster we measured, image pulls alone queued for a median of
17 s. AgentENV claims to remove those costs with Firecracker microVMs, snapshot-based
pause/resume in under 100 ms, fork of a running sandbox, and lazy block-level image
loading. None of that has been run on GKE. The proposal lists 28 gaps, several of them
blockers for production. Before anyone invests in the SDK backend or a production
deployment, we need proof that AgentENV runs on a GKE node at all, and first-hand numbers
for start, pause, resume and fork under nested virtualization.

## Users

- **RL and agent platform engineers** (the tunix/deepswe team and the agent-sandbox
  maintainers) deciding whether AgentENV is worth adopting for density and start latency.
- **The orchestrator and its developer, tester and reviewer agents**, who need an
  unambiguous definition of done for this prototype.

## Scope of this prototype

One AgentENV deployment on the existing GKE cluster `barkland-test` (project
`gke-ai-eco-dev`, `us-central1-a`), using the single nested-virtualization node in pool
`kvm-pool-c2`. Everything lives in namespace `agentenv-system`. Clients reach the gateway
only through `kubectl port-forward`.

Deliverables:
1. Images: upstream `aenv-server:v0.2.2-amd64` for the runtime; gateway and scheduler built
   from AgentENV `v0.2.2` and pushed to `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv`.
2. A kustomize overlay, runtime config, host-prep init container, and deploy, teardown and
   port-forward scripts in this repo.
3. A smoke test suite and a results table proving the lifecycle works end to end: cold
   create, command execution through the gateway's envd proxy, pause, resume with state
   preserved, fork into two children, kill.
4. Recorded timings for each lifecycle step on this hardware.
5. A review of the manifests and scripts against the proposal's gaps table, with blocking
   findings fixed.

### Accepted limitations (copied from the execution plan; not fixed here)

- No TLS, single shared API key, no RBAC or tenancy. Access is port-forward only.
- Single runtime node, so no cross-node routing and no shared snapshot repository:
  `posix_fs` under `/var/lib/aenv` on the node.
- Scheduler and gateway at one replica each; bindings in memory (no Redis).
- Node caches on the 100 GB boot disk, so cache sizes are reduced from the defaults
  (image cache and remote blocks to about 15 GB each, snapshot cache 5 GB).
- Standard OCI images are converted on the node on first use; no overlaybd pipeline, no
  Artifact Registry for sandbox images (public `docker.io` and `ghcr.io` pulls).
- Nested virtualization overhead; paused sandboxes lost if the node is replaced; no
  autoscaling.
- Host preparation is done by an init container in the DaemonSet (load `ublk_drv`, apply
  sysctls). The module is already loaded on the node without `ublks_max`; the init
  container reloads it with `ublks_max=4096` only if no ublk devices are in use.

## Non-goals

- Anything in the proposal's Part 2 (SDK backend), and any change to agent-sandbox itself.
- Production hardening: TLS, ingress, Redis, multi-node, autoscaling, bare-metal nodes,
  Artifact Registry for sandbox images, snapshot repository on Cloud Storage or Filestore.
- Performance comparison with agent-sandbox or gVisor. Timings here are recorded, not
  judged, because nested virtualization on a `c2-standard-8` is not representative.
- Templates built with BuildKit, volumes, P2P, custom extensions, host-based sandbox URLs.
- Any change to node pools, cluster settings, IAM, other namespaces, or the existing
  `agent-sandbox-system` workloads.

## Success metrics

The prototype is done when every acceptance criterion in
[acceptance-criteria.md](acceptance-criteria.md) is marked pass with evidence in
`tests/RESULTS.md`, and the reviewer has no open blocking finding. In one sentence: a
sandbox can be created, commanded, paused, resumed and forked through the gateway on
`barkland-test`, and the whole thing can be torn down and redeployed from this repo.

Recorded, not thresholded: cold create to running, warm second create of the same image,
pause, resume, fork of two, command round-trip. These numbers feed the proposal's
benchmark section.

## Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Cloud Build denied for the orchestrator's identity | No gateway or scheduler image | GitHub Actions in this repo pushing public `ghcr.io/tomergee/*` images |
| 100 GB boot disk fills during the first `ubuntu` conversion plus caches | Node disk pressure, evictions | Reduced cache limits; watch `df` on the node; a `teardown` that clears `/var/lib/aenv` |
| COS specifics: `/dev` access, iptables and network namespaces from a pod | Runtime pod starts but sandboxes fail to network | Capture pod logs and the `/nodes` snapshot as evidence; escalate rather than patch COS |
| `ublk_drv` loaded earlier without `ublks_max` | Low device cap, few sandboxes per node | Acceptable for the prototype; documented in decisions |
| Nested virtualization | Slower start and resume than upstream claims | Record, do not judge |
| Upstream first-use downloads (Firecracker, kernel, tools drive, overlaybd tools) from GitHub and ghcr.io | Slow or failed first start if egress is blocked | Verify node egress early; the runtime pod's startup probe allows 4 minutes |
