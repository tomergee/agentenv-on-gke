# Execution plan: AgentENV prototype on `barkland-test`

**Goal:** AgentENV running on GKE and testable through its API, built with the known
limitations from the proposal accepted for a prototype. Stop condition: a sandbox can be
created, commanded, paused, resumed and forked through the gateway on `barkland-test`,
with the smoke tests and review findings committed to this repo.

**Method:** a multi-agent build driven by one orchestrator (Claude) with four roles:
product manager, developer, tester, reviewer. Work happens on the branch `prototype`;
the orchestrator merges to `main` when the tester passes and the reviewer has no blocking
findings.

## Target environment (verified 2026-09-23)

| Item | Value |
|---|---|
| Cluster | `barkland-test`, project `gke-ai-eco-dev`, zone `us-central1-a`, GKE 1.35.8 |
| Kube context | `gke_gke-ai-eco-dev_us-central1-a_barkland-test` |
| Runtime node pool | `kvm-pool-c2`: 1 x `c2-standard-8` (8 vCPU, 32 GB), COS kernel 6.12.94, nested virtualization, label `kvm=true`, no taint, 100 GB pd-balanced boot disk, **no local SSD** |
| Verified on that node | `/dev/kvm` present, `kernel.io_uring_disabled=0`, privileged pods run without seccomp, `ublk_drv` module loadable (currently loaded from an earlier probe, without `ublks_max`) |
| Cluster ranges | pods `10.38.128.0/17`, services `34.118.224.0/20`, subnet `10.128.0.0/20`; no overlap with AgentENV's `10.11.0.0/16` and `10.12.0.0/16` pools |
| Images | Artifact Registry repo `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv` (created); Cloud Build API enabled; no local Docker daemon |
| Access | no TLS or ingress in the prototype; clients use `kubectl port-forward` to the gateway Service |

## Pinned upstream

- AgentENV source: tag `v0.2.2` (fallback: `main` at `2f48c9c`, the commit analyzed in the proposal).
- Runtime image: `ghcr.io/kvcache-ai/aenv-server:v0.2.2-amd64`, which the release workflow builds from `deploy/docker/Dockerfile.agentenv`, the same Dockerfile the Kubernetes runtime uses.
- Gateway and scheduler images: not published upstream; built with Cloud Build from `deploy/docker/Dockerfile.gateway` and `Dockerfile.scheduler` at the pinned source, pushed to the `agentenv` repo. Fallback if Cloud Build is blocked: a GitHub Actions workflow in this repo pushing to `ghcr.io/tomergee/*` as public packages.
- Tools drive `ghcr.io/kvcache-ai/agentenv-tools:0.1.1`, Firecracker, kernel and overlaybd tools are downloaded by the runtime at startup from the upstream dependency manifest.

## Accepted limitations for the prototype

From the proposal's gaps table; none of these are being fixed here:

- No TLS, single shared API key, no RBAC or tenancy. Access is port-forward only.
- Single runtime node, so no cross-node routing, no shared snapshot repository: `posix_fs` under `/var/lib/aenv` on the node.
- Scheduler and gateway at one replica each; bindings in memory (no Redis).
- Node caches on the 100 GB boot disk, so cache sizes are reduced from the defaults (image cache and remote blocks to about 15 GB each, snapshot cache 5 GB).
- Standard OCI images are converted on the node on first use; no overlaybd pipeline, no Artifact Registry for sandbox images (public `docker.io` and `ghcr.io` pulls).
- Nested virtualization overhead; paused sandboxes lost if the node is replaced; no autoscaling.
- Host preparation is done by an init container in the DaemonSet (load `ublk_drv`, apply sysctls). The module is already loaded on the node without `ublks_max`; the init container reloads it with `ublks_max=4096` only if no ublk devices are in use.

## Repository layout (to be produced)

```
plans/                     proposal, clock test, this plan, PRD and acceptance criteria
deploy/                    kustomize overlay for barkland-test, agentenv.toml, secrets helper
build/                     cloudbuild.yaml and image build script
scripts/                   deploy.sh, teardown.sh, port-forward.sh, get-api-key.sh
tests/                     smoke tests (bash + python), results
review/                    reviewer findings and their resolution
```

## Roles and handoffs

| Phase | Role | Produces | Done when |
|---|---|---|---|
| 1 | Product manager | `plans/prd.md`, `plans/acceptance-criteria.md`, `plans/test-plan.md` | Criteria are measurable and map to the stop condition |
| 2 | Developer | images in Artifact Registry, `deploy/`, `build/`, `scripts/`; system deployed on the cluster | gateway, scheduler and node pods Ready; `/health` answers through port-forward |
| 3a | Tester (after 2) | `tests/`, `tests/RESULTS.md` | Every acceptance criterion has a pass/fail with evidence and timings |
| 3b | Reviewer (parallel with 3a) | `review/findings.md` | Findings ranked; blocking ones listed explicitly |
| 4 | Developer | fixes for failed tests and blocking findings | Tester re-run passes; reviewer clears blockers |
| 5 | Orchestrator | merge `prototype` into `main`; final report | Stop condition met |

Rules for all roles:
- Only touch namespace `agentenv-system` and the resources this repo creates. Never modify
  node pools, cluster settings, other namespaces, or the `agent-sandbox-system` workloads.
- Project-level Google Cloud changes (IAM, buckets, node pools) are out of scope; if one
  is needed, stop and report instead of working around a permission denial.
- Commit to the `prototype` branch with the noreply author identity and no co-author
  trailers. Small, described commits.
- Record every deviation from this plan in `plans/decisions.md`.

## Acceptance criteria (summary; the PM refines these)

1. `kubectl -n agentenv-system get pods` shows gateway, scheduler and one node pod Ready.
2. `GET /health` on the node and gateway return OK through port-forward; `GET /nodes` lists the node.
3. `POST /sandboxes-cold` with `ubuntu:22.04` (or a pulled template) creates a sandbox that reaches running; a command runs through the gateway's envd proxy and returns output.
4. Pause then resume (`/pause`, `/v2/.../connect`) succeeds; a file written before the pause exists after resume.
5. `POST /sandboxes/{id}/fork` with `count: 2` produces two children that run commands independently.
6. Kill deletes the sandbox; `GET /v2/sandboxes` no longer lists it.
7. Timings recorded: cold create to ready, second create of the same image, pause, resume, fork.
8. Teardown script removes everything in `agentenv-system`; the node's `/var/lib/aenv` is documented as leftover state.

## Known risks going in

- Cloud Build permission may be denied for the orchestrator's identity; fallback above.
- The node's 100 GB disk: the first `ubuntu` conversion plus caches must fit; watch disk pressure.
- Nested virtualization: Firecracker start times will be slower than upstream numbers.
- AgentENV expects to write `/var/lib/aenv` on COS: the hostPath is writable, but `/dev` access, `iptables` and network namespaces inside a COS node pod are unverified beyond the kernel checks.
- `ublk_drv` was loaded earlier without `ublks_max`; if devices are in use the init container keeps the default limit, which caps sandboxes per node.
