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

## O-1 root cause: runtime shutdown waits on a vanished scheduler (2026-09-23, developer round 2)

Measured by deleting the runtime pod (the DaemonSet recreates it) and streaming its log:

| Scenario | Pod gone after | Where the time went |
|---|---|---|
| Scheduler up, no prior sandbox activity | 2 s | SIGTERM to "shutting down p2p transport" in 0.22 s |
| Scheduler scaled to 0 first, after a create/pause/kill cycle | 132 s | 126 s inside "stopping observability reporter": the in-flight heartbeat RPC to the scheduler Service (no endpoints) only fails after about two minutes; then three unregister attempts fail within 0.6 s and the rest of shutdown takes 1.3 s |

A namespace delete removes the scheduler Deployment within seconds while the runtime pod is
still in its preStop drain, so the runtime always hits the slow path; the tester's 172 s and
301 s teardowns are this wait (one or two heartbeat timeouts). It is upstream behaviour in
the reporter's shutdown, not the preStop hook, ublk or Firecracker. Fix applied: the new
`scripts/teardown.sh` deletes the DaemonSet while the scheduler is still serving, then the
namespace. `terminationGracePeriodSeconds` stays at upstream's 3600 s; it never bounded this
wait, and lowering it would only shorten the drain that protects running sandboxes.
Upstream-worthy: bound the heartbeat RPC (or skip it) once shutdown has begun.

## O-8: the gateway's node list lags a few minutes after a scheduler restart (2026-09-23, developer round 2)

`GET /nodes` on the gateway is served from the scheduler's heartbeat records (`ListObservedNodes`),
not from EndpointSlice discovery. After `kubectl rollout restart deploy/agentenv-scheduler`
(new pod Ready in 14 s) the list stayed empty for **159 s**; the runtime's log shows
`observability heartbeat failed ... retry_after_secs=5` during that window, then recovery.
The same lag followed the round-2 deploy, where the scheduler and runtime pods restarted
together, and it made the first AC-2 attempt fail while AC-3..AC-10 passed: `Schedule`
uses discovered nodes and treats a node without a heartbeat snapshot as eligible, so
creates, commands, pause, resume and fork were unaffected. Likely cause: the runtime's
long-lived gRPC connection to the scheduler's ClusterIP keeps pointing at the old pod until
TCP retransmission gives up (about two minutes); a client keepalive or reconnect-on-error
would fix it upstream. Prototype handling: `tests/smoke.sh` waits up to 300 s
(`NODES_WAIT`) for the node to be listed and records the wait; AC-2's pass rule says so.

## H1 verified: teardown with a running sandbox takes 28 s (2026-09-23, developer round 2)

First attempt of the new script found no sandboxes because `GET /v2/sandboxes?state=running,paused`
returns **400** in v0.2.2 (one state per query works); the running sandbox then held the
runtime pod in its preStop drain and the namespace stayed Terminating past the 600 s wait.
Fixed by querying `state=running` and `state=paused` separately and by waiting for the
runtime pod to be deleted (not just the DaemonSet object). Re-run with one running sandbox:
kill 204, DaemonSet and pod gone, namespace gone, **28 s wall clock**; `scripts/deploy.sh`
afterwards took 29 s and reused the API key. For comparison the tester measured 172 s and
301 s with the old namespace-only teardown (O-1).

## Orchestrator: scaled the runtime pool to 4 nodes (2026-09-23, at Tomer's request)

`gcloud container clusters resize barkland-test --node-pool kvm-pool-c2 --num-nodes 4`. The
DaemonSet placed a runtime pod on each new node; the init container loaded `ublk_drv` at
4096 on the fresh hosts; the scheduler discovered all four through the headless Service.
Eight cold creates landed two per node. Two new runtime pods restarted once or twice before
becoming Ready: their startup dependency download from GitHub failed with a DNS error before
node DNS was up (see proposal section 9, finding 1). Caveats for multi-node testing: no
shared snapshot repository, so templates and committed snapshots are per node; pause,
resume and fork stay on the owning node; cold creates work everywhere. The system is left
running for manual testing. To return to one node:
`gcloud container clusters resize barkland-test --node-pool kvm-pool-c2 --num-nodes 1 --zone us-central1-a --project gke-ai-eco-dev`.



## Orchestrator: private Artifact Registry pulls for the SWE task images (2026-09-23)

Tomer wants to test with the task images in `us-docker.pkg.dev/gke-ai-eco-dev/hicard`
(R2E-Gym per-repository images, thousands of tags, and the SWE-rebench `sweb.eval.*`
images). AgentENV pulls with `regctl`, not through the kubelet, so it needs registry
credentials of its own. The runtime pool runs Workload Identity (`GKE_METADATA`), so the
pod's identity is its Kubernetes ServiceAccount, `agentenv-system/default`.

- Project-level change (recorded per AC-13): granted `roles/artifactregistry.reader` on
  repository `hicard` to
  `principal://iam.googleapis.com/projects/142966328212/locations/global/workloadIdentityPools/gke-ai-eco-dev.svc.id.goog/subject/ns/agentenv-system/sa/default`.
- A `registry-creds` sidecar in the runtime pod fetches the Workload Identity access token
  from the metadata server every 15 minutes and writes `~/.docker/config.json` (basic auth
  `oauth2accesstoken:<token>`) into a memory-backed emptyDir shared with the runtime
  container. `regctl` reads that file on every call, which sidesteps AgentENV's
  startup-only credential loading (proposal gap 5) for standard OCI pulls. Lazy overlaybd
  reads would still need the startup-time config; not relevant for these images.
- Not done: overlaybd conversion pipeline; the images are pulled and converted on the node
  on first use (about 1.3 GB compressed each), so expect tens of seconds for a first create
  and cache eviction pressure on the 100 GB node disk with many distinct images.


## Orchestrator: API key rotation breaks the gateway until it restarts (2026-09-23)

Running `scripts/deploy.sh` from a second checkout (which had its own `.secrets/`) replaced
`Secret/agentenv-auth` with a different key. The runtime pods restarted (the DaemonSet spec
had changed) and picked up the new key; the gateway Deployment did not change, kept the old
key from its environment, and, because the gateway injects its own key when proxying to the
nodes, every authenticated request returned 401 even though clients sent the key from the
Secret. Fix applied: `deploy.sh` now treats the cluster's Secrets as the source of truth
(pulls them into `.secrets/`, never overwrites a live key unless `ROTATE_SECRETS=1`) and
restarts the gateway and runtime pods whenever it changes a Secret. Operational rule for
any deployment: rotating the API key means restarting the gateway and every runtime pod;
there is no hot reload and no dual-key window. `tests/smoke.sh` AC-1 now accepts pods with
more than one container (the credential sidecar) and any number of runtime nodes.
\n

## Orchestrator: SWE task image results and the per-node conversion effect (2026-09-23)

The private `hicard` SWE-rebench image ran end to end (tests/RESULTS.md, last section): cold
create 52.5 s for a 1.3 GB image, then commands, pause, resume, fork and kill all normal. The
second and third creates took about 60 s each because the scheduler's round-robin placed
them on nodes that had not converted the image yet. Conversion is per node and synchronous
inside the create call. Decision: accepted for the prototype; recorded as a design input for
the proposal (image-aware placement, or an overlaybd conversion pipeline so nodes lazy-load
instead of converting).

## Orchestrator: SWE-bench Verified access and first run (2026-09-23)

- Project-level change (AC-13): granted `roles/artifactregistry.reader` on repository
  `swebench-mirror` to the same Workload Identity principal as for `hicard`. The Verified set
  is `us-docker.pkg.dev/gke-ai-eco-dev/swebench-mirror/swebench-verified:sweb.eval.x86_64.<instance>`
  (500 instances, 1,500 tags including the two hash aliases per image, about 1.2 GB
  compressed each, 16 layers).
- First run, `astropy__astropy-12907`, requested `cpuCount: 2, memoryMB: 4096`: create POST
  42.3 s (pull + conversion), running at 42.7 s; inside the guest `nproc` = 2, memory 3.9 GB,
  root disk 63 GB, `/testbed` present, Python 3.9.21. Killed afterwards.
- Converted footprint: about 3.5 to 4.7 GB of overlaybd commits per SWE image per node (base
  layers are shared between images from the same family). 500 images would need roughly
  2 TB per node; the nodes have 100 GB disks and a 15 GB image cache, so the whole set
  cannot be held converted on the nodes as configured. Options recorded in the report to
  Tomer: bigger cache or disks, or the overlaybd pre-conversion pipeline (lazy loading).

Sizing facts (from the v0.2.2 spec and config): cold creates take `cpuCount`, `memoryMB`
and `diskSizeMB` in the request body; unset values come from the node's `[machine]` config
(`vcpu_count = 2`, `mem_size_mib = 1024`); the root disk can grow but not shrink
(`allow_shrink = false`). Template-based starts inherit the template's sizes, set at build
time (`aenv template create --cpu --memory`), and cannot be overridden per start.

