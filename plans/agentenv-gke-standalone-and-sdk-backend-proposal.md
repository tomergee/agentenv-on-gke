# DRAFT: AgentENV on GKE (standalone) and an AgentENV backend for the agent-sandbox SDKs

**Status:** draft for discussion, 2026-09-22. Not reviewed.
**Scope:** (1) run AgentENV standalone on GKE Standard; (2) let existing agent-sandbox
Python SDK and RL SDK users target AgentENV through a pluggable client-side backend.
**Out of scope:** backing the agent-sandbox *controller* (Sandbox/SandboxClaim CRs) with
AgentENV, Go/TypeScript backends (sketched only), multi-tenant AgentENV.

## Gaps at a glance

Severity: **Blocker** must be solved before production; **High** needs a design decision
or workaround before scale; **Medium** is worth addressing, with a known workaround.

| # | Area | Gap | Severity | Mitigation | Section |
|---|---|---|---|---|---|
| 1 | AgentENV | No TLS anywhere: the gateway and node APIs are plain HTTP | Blocker | Internal HTTPS load balancer in front of the gateway; NetworkPolicy for in-cluster flows | 4.5 |
| 2 | AgentENV | One shared API key, checked only on nodes; no users, tenancy or quotas | Blocker | One AgentENV cluster per trust domain; an authenticating proxy later | 4.6 |
| 3 | AgentENV | Paused sandboxes live on node-local disk and are lost when a node is replaced; no migration | High | Maintenance exclusions, autoscaled blue-green upgrades, a pre-drain commit step (not upstream) | 4.9 |
| 4 | AgentENV + GKE | No autoscaling integration; the cluster autoscaler may remove nodes running only microVMs | High | Fixed-size pool; scale-down-disabled annotation; a custom scaler driven by `GET /nodes` | 4.10 |
| 5 | AgentENV | Registry credentials: the lazy reader is wired to the Docker credential file only if it exists at startup; `regctl` (standard OCI pulls) re-reads it per call | High | **Prototype:** a Workload Identity token sidecar works for both paths once it is a native sidecar that writes the file before the runtime starts **[V-probe]**; the token in the lazy path is then whatever the file held at startup, so a restart is needed after it expires unless upstream re-reads it | 4.6, 4.12, 9 |
| 6 | AgentENV | Standard images are fully downloaded and converted on every node on first use | High | Batch pipeline that publishes overlaybd-native images | 4.7 |
| 7 | AgentENV | Single scheduler replica; sandbox-to-node bindings in memory by default. Measured: after a scheduler restart `GET /nodes` is empty for up to ~160 s while sandbox operations keep working | High | Redis binding store (Memorystore) plus query-only scheduler replicas; health checks must tolerate the rebuild window | 4.4, 9 |
| 8 | AgentENV | Placement ignores load and image locality by default (no resource limits; the create's `images` hint is unused). Measured: with 4 nodes, a second create of a 1.3 GB image took 60 s again on a fresh node | High | Configure `node_resource_limit`; image-aware placement or pre-converted images for many distinct task images | 4.4, 9 |
| 9 | AgentENV | Create is not idempotent; retries can leak sandboxes | Medium | Tag every sandbox with run metadata; reap by metadata | 5.3 |
| 10 | AgentENV | Fork keeps all children on the source's node and rejects sources with volumes | Medium | Size fork groups to one node; avoid volumes on fork sources | 3 |
| 11 | AgentENV | Template-based creates take no per-sandbox CPU or memory | Medium | One template per shape, or cold creates from an image | 5.4 |
| 12 | AgentENV | Sandboxes can't reach any private range, including cluster services and internal model endpoints | Medium | Public or allowlisted endpoints; a reviewed carve-out in `always_denied_cidrs` | 4.5 |
| 13 | AgentENV + GKE | Internal address pools `10.11.0.0/16` and `10.12.0.0/16` can collide with GKE ranges | Medium | Choose non-overlapping GKE ranges or move the pools (configurable) | 4.5 |
| 14 | AgentENV | Host prep is manual (ublk device limit, sysctls); the DaemonSet targets every Linux node | Medium | **Done in the prototype:** init container reloads `ublk_drv` at 4096 (kernel default measured at 64) and applies sysctls; node selector pins the pool | 4.3, 4.4, 9 |
| 15 | AgentENV | Privileged DaemonSet with host `/dev`; unauthenticated metrics; no tracing | Medium | Security review; break-glass exec; NetworkPolicy on metrics | 4.8, 4.11 |
| 16 | GKE | Nested virtualization costs 10% or more CPU (more for I/O), limits machine series, and rules out node auto-provisioning | High | Prefer bare metal (section 4.2); benchmark against nested | 4.2 |
| 17 | GKE | Bare metal on GKE: only C3 and C4A are confirmed, and neither has local SSD; C4 bare metal with local SSD is unconfirmed; no live migration; KVM, ublk and io_uring untested on bare-metal nodes | High | Test GKE acceptance of `c4-standard-288-lssd-metal`; else C3 metal with a Hyperdisk cache, or nested VMs with local SSD | 4.2, 7 |
| 18 | GKE | Local SSD data is lost on upgrade or repair; pool storage config is immutable | Medium | Treat node disks as caches; keep durable state in the snapshot repository | 4.2, 4.9 |
| 19 | GKE | Surge upgrades, auto-repair and scale-down cap graceful drain at one hour. Measured: runtime shutdown blocks ~126 s if the scheduler is already gone | Medium | Autoscaled blue-green (up to 24 hours) and maintenance windows; drain runtime pods before the control plane | 4.9, 9 |
| 20 | Artifact Registry | No lazy-loading format (nodes convert per image, 42 to 52 s first create, about 4.5 GB per image per node **[V-probe]**); bytes flow through its own front end; quota of 60,000 requests/min per region; short-lived tokens (worked around with a Workload Identity token sidecar **[V-probe]**); download URLs act as capabilities; relative redirect `Location` breaks stock v0.2.2's lazy reader (gap 33); Referrers API unverified. GKE Image Streaming and Nydus do not apply | High | **Done in the prototype:** conversion pipeline into a regional repository; converted images start in about 5 s on any node **[V-probe]**. Next: Dragonfly peers in front of the registry (needs gap 32); in-region load test | 4.12 |
| 21 | Cloud Storage | S3-compatible API lacks request preconditions and multipart MD5s; needs HMAC keys | Medium | Verify AgentENV's OpenDAL usage; HMAC key in Secret Manager; or native GCS support upstream | 4.6, 4.7 |
| 22 | SDKs | No backend abstraction; creation is hard-wired to SandboxClaims; the RL SDK executes through pod exec | High | Backend protocol in the Python and RL SDKs, Kubernetes as default | 5.1, 5.2, 5.3 |
| 23 | SDKs | Warm pools, pod identity, pod-level parameters and Kubernetes-only adapters don't map | Medium | Documented as unsupported or no-ops on the AgentENV backend | 5.4 |
| 24 | SDKs | The E2B SDK has no fork call | Medium | Raw HTTP call for fork in the backend | 3, 5.2 |
| 25 | Project | A non-Kubernetes backend may not be accepted in a Kubernetes SIG SDK | High | Propose the abstraction upstream; ship the AgentENV backend out of tree | 5.6 |
| 26 | AgentENV | No RBAC: one key grants every operation; no per-user identity or audit. Measured: the key alone also reaches envd in cold-created sandboxes without `secure` | Blocker | Kubernetes RBAC around the deployment; an authenticating proxy with roles and metadata ownership, or one cluster per team | 4.14 |
| 27 | AgentENV | No central metadata store: sandbox lists fan out to every node and fail if one node fails; no history or change stream | High | Metadata tagging, gateway access logs, an external inventory and an orphan reconciler | 4.13 |
| 28 | AgentENV + Cloud Storage | **Confirmed:** Cloud Storage's S3-compatible API silently ignores `If-Match` / `If-None-Match` on PUT **[V-probe]**, so AgentENV's create-if-absent and optimistic-update guards on snapshot and volume records are no-ops there (last writer wins, no error); alias bindings are best-effort by design | Blocker for concurrent writers | Native GCS backend upstream (`x-goog-if-generation-match` works), or Filestore `posix_fs`, or serialize catalog writers | 4.13 |
| 29 | AgentENV | Runtime downloads Firecracker, kernel, tools and overlaybd binaries from the internet at every pod start, with no retry; fresh nodes crash-loop until DNS is up **[V-probe]** | Medium | Private mirror of the dependency manifest, or bake dependencies into the runtime image; egress to GitHub and ghcr required otherwise | 9 |
| 31 | AgentENV | API key rotation: the gateway injects its own copy of the key toward nodes and reads it only at startup; rotating the Secret without restarting the gateway breaks every call; no dual-key window **[V-probe]** | Medium | Restart gateway and runtime pods on rotation (the repo's deploy script does); upstream: reload on change or accept two keys during rotation | 4.6, 9 |
| 32 | AgentENV | No configurable P2P or CDN cache address: the lazy reader's Dragonfly-compatible "accelerate" hook is set only by AgentENV's experimental built-in transport, and the storage config is regenerated at each start **[V-code]** | Medium | Upstream a `p2p_config.address` setting (or startup patch); then deploy Dragonfly peers per node and preheat the converted images | 4.12 |
| 33 | AgentENV + Artifact Registry | The lazy block reader stores a redirect `Location` verbatim; Artifact Registry sends a relative one, so lazy loading from Artifact Registry fails on stock v0.2.2 ("relative URL without a base") **[V-probe]** | Blocker for lazy loading on Artifact Registry | Six-line patch (resolve against the request URL) built into the prototype's runtime image; upstream PR needed | 4.12, 9 |
| 34 | AgentENV | Under a start burst (about 25 simultaneous per node) 1 to 3 % of creates fail with "set machine configuration: connection refused" on the Firecracker API socket; no retry in the runtime **[V-probe]** | Medium | Retry the configuration call upstream; size `[pool.firecracker]` for the expected burst; stagger client bursts; treat create 500 as retriable | 9 |
| 30 | AgentENV | API skew between releases and `main`: v0.2.2 lacks `/v2/sandboxes/{id}/connect` (breaks the E2B SDK's connect), `/proxy` prefix returns 404, `?state=a,b` returns 400 **[V-probe]** | Medium | Pin the API version in the SDK backend; feature-detect; track upstream releases | 5.2, 9 |

---

Evidence tags used below: **[V-code]** seen in source, **[V-docs]** official docs,
**[V-probe]** measured on our GKE test node, **[A]** assumption or inference to test.

---

## 1. Summary

AgentENV (kvcache-ai/AgentENV) runs agent environments as Firecracker microVMs managed by
one privileged runtime pod per host. It gets its density and start latency from things a
pod-per-sandbox design cannot do: no Kubernetes object per sandbox, pause/resume from
incremental memory+disk snapshots, fork of a running sandbox into up to 100 children, and
lazy block-level image loading into a bounded node cache.

We propose to adopt it in two steps that keep those properties intact:

1. **Standalone on GKE.** Deploy AgentENV's own gateway, scheduler and runtime DaemonSet on
   a dedicated GKE Standard node pool, preferably **bare metal** for native KVM: C4 bare
   metal with local SSD if GKE accepts it, otherwise C3 bare metal (GA on GKE since
   2026-09-01, but no local SSD), with nested virtualization on local-SSD VMs as the fallback. Harden what the upstream
   manifests leave out: TLS, HA, a persistent binding store, host preparation, storage,
   upgrades and scaling.
2. **SDK backend.** Introduce a backend abstraction in the agent-sandbox Python SDK and the
   RL SDK, keep Kubernetes as the default backend, and add an `agentenv` backend that talks
   AgentENV's E2B-compatible API. Users switch backends by configuration, not by rewriting
   code.

We deliberately do **not** put the agent-sandbox controller in front of AgentENV: a CR per
sandbox would bring back the API-server load and reconcile latency that AgentENV avoids.

## 2. Motivation

- **Density.** Pods are capped per node (110 by default, 512 max on Standard **[V-docs]**),
  idle sandboxes keep their full reservation, and guest memory is never shared. AgentENV
  pauses idle sandboxes to snapshots, shares page cache across sandboxes from the same
  snapshot, reclaims guest memory, and supports up to 32,768 network slots per node
  **[V-code]**.
- **Start latency.** Resume from a snapshot is claimed at under 50 ms and pause under 100 ms
  (upstream README, not measured by us). Pod starts go through scheduling, kubelet, CNI and
  image pulls; on one production cluster we measured image pulls queuing a median 17 s.
- **Grouped RL rollouts.** `POST /sandboxes/{id}/fork` boots N children from one captured
  state **[V-code]**, which maps directly onto "N generations from the same task state".

## 3. AgentENV integration surface (what we build against)

| Area | Facts |
|---|---|
| Control API | E2B-compatible: `POST/GET /v2/sandboxes`, `GET/DELETE /sandboxes/{id}`, `POST .../pause`, `POST /v2/.../connect` (resumes; 201 if resumed), `POST .../timeout`, templates `/v3/templates`, `/v2/templates/{id}/builds/...` **[V-code]** `src/api/openapi.yml` |
| Extensions | `POST /sandboxes-cold` (create from an OCI image with cpu/memory/disk), `POST /sandboxes/{id}/fork` (`count` up to 100), `GET /nodes` **[V-code]** |
| Create inputs | v2 takes `templateID`, `timeout` (default 300 s), `autoPause` (default true), `autoResume`, `metadata` (string map), `envVars`, network allow/deny, volume mounts. **No cpu/memory**: sizing comes from the template **[V-code]** |
| In-sandbox API | Upstream E2B **envd** 0.5.15 on port 49983: Connect-RPC Process (streaming start, stdin, signals, PTY) and Filesystem services, plus `/files` HTTP **[V-code]** |
| Routing | Headers `e2b-sandbox-id` + `e2b-sandbox-port` (or `x-agentenv-*`), or host `{port}-{sandboxID}.{domain}`; WebSocket/SSE supported; IDs are UUIDv7 **[V-code]** `src/api/proxy.rs` |
| E2B SDKs | Official E2B Python/JS SDKs work by setting `E2B_API_URL`, `E2B_SANDBOX_URL`, `E2B_API_KEY` **[V-docs]** `docs/src/integration/e2b.md` (not run by us). No fork call in the E2B SDK **[A]** |
| Auth | One shared `X-API-Key`, enforced on nodes only; the gateway does not authenticate. Per-sandbox `envdAccessToken` and `trafficAccessToken` derived from `AENV_SANDBOX_ACCESS_TOKEN_HASH_SEED`. **No teams, tenancy or quotas** **[V-code]** |
| Lifecycle | Expiry pauses (if `autoPause`) or kills; auto-resume on proxy traffic. **Paused state is node-local** under the hostPath; no migration. **Create is not idempotent** (server-generated ID, no idempotency key) **[V-code]** |
| Fork | Pauses the source briefly, captures once, boots N children **on the same node**; rejected if the source has volume mounts **[V-code]** |
| Images | Standard OCI is converted locally on first use (tens of seconds on a miss); overlaybd-native images load lazily **[V-code]** |
| Snapshots | Repository backend `posix_fs` (shared filesystem) or `oss` (S3-compatible via OpenDAL); cross-node start needs a shared repository **[V-code]** |
| Networking | Per-sandbox network namespace; RFC1918, CGNAT, link-local and loopback are always denied, so sandboxes **cannot reach other sandboxes, cluster services or the GCE metadata server**; domain allowlists apply to HTTP/HTTPS only **[V-code]** `docs/src/internals/networking.md` |
| Control plane | Gateway (stateless proxy, fans out list calls), scheduler (single replica upstream; `round_robin`/`random`; optional heartbeat-based `node_resource_limit`; optional Redis binding store and query-only replicas; Kubernetes EndpointSlice discovery) **[V-code]** |
| Observability | Prometheus `/metrics` on nodes (:8000, unauthenticated), ublk daemon (:9103), gateway and scheduler; `GET /nodes` reports allocated/used CPU and memory and sandbox counts; no OpenTelemetry found **[V-code]** / **[A]** |
| Gaps upstream | No TLS, no Ingress/HPA/PDB, single replicas, no Redis in manifests, host prep is manual, the DaemonSet has no node selector for KVM hosts **[V-code]** |

### 3.1 Routing compared with agent-sandbox's sandbox-router

AgentENV's equivalent of `sandbox-router` is its gateway plus a proxy built into each node
(`services/gateway/`, `src/api/proxy.rs`). The contract is similar (a header names the
sandbox and target port), but the scope, hops and security model differ.

| | agent-sandbox `sandbox-router` | AgentENV gateway and node proxy |
|---|---|---|
| Scope | Data plane only; creation goes through the Kubernetes API **[V-code]** `sandbox-router/README.md` | Data and control plane: the gateway also proxies create, pause and kill, and fans out list calls to all nodes **[V-code]** |
| Hops | One: dials the sandbox pod directly | Two: the gateway asks the scheduler which node owns the sandbox, then that node's proxy forwards into the sandbox's network namespace **[V-code]** |
| Target resolution | Pod IP from an informer cache, then cluster DNS as a fallback | Scheduler sandbox-to-node map, then the node's local sandbox table |
| Request contract | `X-Sandbox-ID`, `X-Sandbox-Namespace`, `X-Sandbox-Port`, optional `X-Sandbox-UID` / `X-Sandbox-Pod-IP` | `e2b-sandbox-id` + `e2b-sandbox-port` (or `x-agentenv-*`), host `{port}-{sandboxID}.{domain}`, or a `/proxy` path prefix |
| Authentication | Optional Kubernetes TokenReview; allow-all by default | API key for the control API; per-sandbox `X-Access-Token` for envd and `e2b-traffic-access-token` for app ports; enforced on nodes, not the gateway |
| TLS | TLS and mTLS with certificate hot-reload | None; needs a TLS terminator in front |
| Paused sandboxes | Not applicable | Proxy traffic can auto-resume a paused sandbox |
| Protocols | HTTP and gRPC | HTTP, WebSocket, SSE and streaming |
| Observability | Prometheus metrics and OpenTelemetry tracing | Prometheus metrics; no tracing found |
| Input hardening | Header validation; blocks loopback, link-local and metadata targets | UUIDv7 sandbox IDs; sandboxes firewalled from private and metadata ranges |

Implications for this proposal:
- In the SDK backend (section 5), AgentENV's gateway replaces `sandbox-router`: the backend
  sends `e2b-sandbox-id` / `e2b-sandbox-port` and the per-sandbox access token instead of the
  `X-Sandbox-*` headers.
- The missing TLS is why section 4.5 puts an internal HTTPS load balancer in front of the
  gateway; `sandbox-router` terminates TLS itself.
- The two-hop path adds a scheduler lookup per request, which is why section 4.4 adds
  query-only scheduler replicas.

## 4. Part 1: standalone deployment on GKE

### 4.1 Topology

```
clients (SDKs, RL workers)  --HTTPS-->  internal Gateway (gke-l7-rilb, wildcard host)
                                              |
                                  agentenv-gateway (Deployment, >=2)
                                     |                     |
                        agentenv-scheduler (1 + query-only replicas) -- Memorystore Redis
                                     |
                agentenv-node DaemonSet (privileged, one per host, dedicated pool)
                   |              |                  |
   node cache (local NVMe or Hyperdisk)   OCI registry   snapshot repository (GCS or Filestore)
```

### 4.2 Node pool

AgentENV needs KVM on the host. Regular Compute Engine VMs expose it only through nested
virtualization; bare-metal machine types expose it natively. The deciding second factor
is **local SSD**, which AgentENV uses for its block caches and sandbox writable layers
(section 4.7): most bare-metal types have none.

**Candidates at a glance:**

| Instance type | CPU | KVM | Local SSD | On GKE | Fit for AgentENV |
|---|---|---|---|---|---|
| `c4-standard-288-lssd-metal`, `c4-highmem-288-lssd-metal` | Intel Granite Rapids | Native | 18 TiB | Not confirmed | **Preferred**, if GKE accepts it |
| `c3-highcpu/standard/highmem-192-metal` | Intel Sapphire Rapids | Native | None (Hyperdisk only) | Yes, GA | **Supported fallback**; benchmark the Hyperdisk cache |
| `c4-standard-*-lssd` / `c4-highmem-*-lssd` VMs | Intel Granite Rapids | Nested | Up to 18 TiB | Yes | **Nested fallback** with local NVMe |
| `c3-standard-*-lssd` / `c3-highmem-*-lssd` VMs | Intel Sapphire Rapids | Nested | Up to 12 TiB | Yes | **Nested fallback** with local NVMe |
| `z3-highmem-*-standardlssd` / `z3-highmem-*-highlssd` VMs | Intel Sapphire Rapids | Nested | 200 to 438 GiB per vCPU, up to about 35 TiB | Yes; SSD preconfigured | **Nested fallback** with the most local NVMe; high memory per vCPU suits density |
| `n2-standard-*` / `n2-highmem-*` VMs | Intel Cascade Lake or Ice Lake | Nested | Up to 9 TiB | Yes | **Nested fallback**, older CPUs |
| `c2-standard-*` VMs | Intel Cascade Lake | Nested | Up to 3 TiB | Yes | **Prototype**: verified on our test node (`c2-standard-8`) **[V-probe]** |
| `z3-highmem-192-highlssd-metal` | Intel Sapphire Rapids | Native | 72 TiB | Not confirmed | Not recommended: storage-sized, unconfirmed |
| `c4d-*-384-metal` | AMD Turin | Native | None | Not confirmed | Not recommended: no local SSD, unconfirmed |
| `c4a-*-96-metal` | Google Axion (Arm) | Native | None | Yes, GA | Not recommended: Arm support in AgentENV unverified **[A]** |
| `x4-*-metal` | Intel Sapphire Rapids | Native | None | Not confirmed | Not recommended: slow boots, limited images |
| AMD VMs (N2D, C3D, C4D), E2, Arm VMs | | None | | | Excluded: no nested virtualization **[V-docs]** |

Sources: bare-metal and local SSD figures from the Compute Engine machine docs, nested
support from the machine-series comparison, GKE support from the GKE machine-support page
and release notes **[V-docs]**. N2 CPU generations vary by zone **[A]**.

**Bare-metal machine types** **[V-docs]** (Compute Engine bare-metal list; GKE support per
the GKE machine-support page and release notes):

| Series | CPU | Bare-metal shapes | Local SSD | GKE nodes |
|---|---|---|---|---|
| C4 | Intel Xeon 6th gen (Granite Rapids) | `c4-standard-288-metal`, `c4-highmem-288-metal`; 288 vCPUs, 1,080 or 2,232 GB | 18 TiB Titanium SSD with the `-lssd` variants | Not confirmed **[A]** |
| C3 | Intel Xeon 4th gen (Sapphire Rapids) | `c3-highcpu/standard/highmem-192-metal`; 192 vCPUs, 512 to 1,536 GB | **None**; Hyperdisk Balanced or Extreme only | Yes, GA since 2026-09-01 |
| Z3 | Intel Xeon 4th gen (Sapphire Rapids) | `z3-highmem-192-highlssd-metal`; 192 vCPUs, 1,536 GB | 72 TiB Titanium SSD | Not confirmed **[A]** |
| C4D | AMD EPYC 5th gen (Turin) | `c4d-highcpu/standard/highmem-384-metal`; 384 vCPUs, 768 to 3,072 GB | None | Not confirmed (C4D VMs are supported) **[A]** |
| C4A | Google Axion (Arm) | `c4a-standard/highmem-96-metal`; 96 vCPUs, 384 or 768 GB | None | Yes, GA; no live migration |
| X4 | Intel Xeon 4th gen (Sapphire Rapids) | 480 to 1,920 vCPUs, 6 to 32 TB | None | Not confirmed; slow boots and limited images make it a poor fit |

All bare-metal types: host maintenance must be TERMINATE (no live migration, except A4X Max
and C4A with local SSD), a single network interface, and only OS images with the IDPF
network driver **[V-docs]**; whether Container-Optimized OS node images qualify on every
type is untested **[A]**.

**Options, in order of preference:**

| Option | Pros | Cons |
|---|---|---|
| **A. C4 bare metal with local SSD** (`c4-standard-288-lssd-metal`, `c4-highmem-288-lssd-metal`) | Native KVM and 18 TiB of local NVMe on the same host; newest Intel generation | GKE support unconfirmed; 288-vCPU minimum; no live migration; C4 bare metal can't simulate host maintenance events **[V-docs]** |
| **B. C3 bare metal** (`c3-*-192-metal`) | Native KVM; GA on GKE Standard **[V-docs]** | **No local SSD**: caches and writable layers go on Hyperdisk (network-attached), so cache-miss reads and snapshot I/O are slower **[A: benchmark]**; 192-vCPU minimum; no live migration |
| **C. Nested virtualization** on VMs with local SSD: Z3 `-standardlssd` / `-highlssd` (up to about 35 TiB), C4 `-lssd` (up to 18 TiB), C3 `-lssd` (up to 12 TiB), N2 (up to 9 TiB), C2 (up to 3 TiB) **[V-docs]** | Local NVMe; any shape size; verified working on our test node **[V-probe]** | 10% or more CPU overhead, more for I/O **[V-docs]**; no node auto-provisioning; not on N2D, C3D, C4D, E2 or Arm. Z3: VMs with more than 18 TiB of SSD are stopped and restarted in place during maintenance instead of live-migrated, and Google warns local SSD data on Z3 may be unavailable during maintenance **[V-docs]** |

Not recommended: Z3 bare metal (plenty of SSD but unconfirmed on GKE and sized for storage,
not compute), C4D bare metal (no local SSD, unconfirmed), C4A bare metal (Arm; AgentENV's
Arm server support is unverified **[A]**), X4.

**Recommendation:**
1. Prototype on option C, which already works on the test cluster.
2. Check whether GKE accepts a `c4-standard-288-lssd-metal` node pool; an unsupported type
   is rejected at node-pool creation.
3. Production: option A if GKE accepts it and the host checks pass (section 7). Otherwise
   option B if the Hyperdisk cache benchmark is acceptable, else option C.

Common settings:
- Image type Container-Optimized OS. On GKE 1.35 it runs kernel 6.12.94 with `/dev/kvm`,
  `kernel.io_uring_disabled=0`, `CONFIG_BLK_DEV_UBLK=m`, and a loadable `ublk_drv`
  **[V-probe]** (on a nested-virtualization node; bare metal is untested).
- Node cache storage: with local SSD (options A and C), raw block mode
  (`--local-nvme-ssd-block`), assembled and mounted by the DaemonSet at `/var/lib/aenv`
  **[V-docs]**; the pool setting is immutable, and data is lost on node delete, repair or
  upgrade. On Z3, Google recommends ephemeral storage over raw block because local SSD
  data may be unavailable during maintenance; AgentENV's caches are rebuildable, but paused
  sandboxes on Z3 carry that extra risk **[V-docs]**. Without local SSD (option B), a large Hyperdisk Balanced or Extreme disk for
  `/var/lib/aenv`, as the boot disk or an attached volume **[A: provisioning path to
  confirm]**.
- Taint `agentenv=true:NoSchedule`, label `workload=agentenv`, one pool per virtualization
  mode (paused state restores only in the same mode **[V-code]**).
- Keep one CPU model per pool, and don't mix bare metal with nested pools or C4 with C3:
  snapshot portability depends on a cluster-wide CPU template intersection **[V-code]**.

### 4.3 Host preparation (DaemonSet init container, privileged)

1. Mount the node cache at `/var/lib/aenv`: assemble the local NVMe devices (mdadm + mkfs
   if unformatted) on pools with local SSD, or format and mount the Hyperdisk volume on C3
   bare metal.
2. `modprobe ublk_drv ublks_max=4096`. Upstream host setup uses 4096 **[V-code]**
   `scripts/docker-setup.sh`; the kernel default is much lower and each sandbox needs
   several ublk devices, so the default would cap density **[A: exact default to confirm]**.
3. Apply the sysctls from `scripts/docker-setup.sh`.
4. Fail fast if `/dev/kvm` is missing.

### 4.4 Manifest changes against `deploy/k8s/base`

- DaemonSet: node selector and toleration for the dedicated pool; the init container above;
  CPU and memory requests close to the node allocatable, so nothing else lands there and the
  kube scheduler's view matches reality; keep `terminationGracePeriodSeconds: 3600` (fits the
  GKE one-hour drain cap, see 4.9).
- Set `AENV_SANDBOX_ACCESS_TOKEN_HASH_SEED` from a shared Secret (required for cross-node
  recovery **[V-code]**), and the API key from Secret Manager.
- Gateway: at least 2 replicas, a PodDisruptionBudget, anti-affinity.
- Scheduler: Redis binding store (`redis_addr`), plus 2 `--query-only` replicas for lookups;
  set `node_resource_limit`, for example:

```json
"node_resource_limit": {
  "max_cpu_allocated_percent": 400,
  "max_memory_allocated_percent": 300,
  "max_memory_used_percent": 85,
  "max_sandbox_starting_count": 64
}
```

  Values are placeholders to calibrate in the benchmark. Without a limit, placement ignores
  load entirely **[V-code]**.

### 4.5 Networking

**Sandbox networks inside each node.**
- Each sandbox gets its own network namespace with a veth pair and a TAP device. AgentENV
  draws addresses from two internal pools, `10.11.0.0/16` for host interaction (32,768
  addresses) and `10.12.0.0/16` for veths (65,536), plus a fixed TAP link at
  `169.254.0.20/30` **[V-code]** `config/default.toml [network.internal]`.
- The runtime pod does not use host networking, so these namespaces sit inside the pod's
  own network namespace **[V-code]** `deploy/k8s/base/agentenv-daemonset.yaml`.
- **Requirement:** pick GKE node, pod, service, proxy-only-subnet and Memorystore ranges that
  don't overlap `10.11.0.0/16` or `10.12.0.0/16`, or move AgentENV's pools, which are
  configurable **[V-code]**. An overlap would make routing between the node proxy and its
  sandboxes ambiguous **[A]**.
- Up to 32,768 network slots per node, and no pod IP per sandbox **[V-code]**. The dedicated
  pool runs one pod per node, so it can use a small max-pods-per-node and a small per-node
  pod range **[V-docs]** flexible pod CIDR.

**Sandbox egress.**
- Path: sandbox, then NAT in the node pod, then the pod IP, then the node, then out. Private
  nodes need Cloud NAT for internet egress, and Private Google Access for registry and
  bucket traffic **[A]**.
- Always denied, and not overridable per sandbox: RFC1918, CGNAT, loopback, link-local, and
  the internal pools **[V-code]**. So sandboxes can't reach cluster services, Memorystore,
  internal model endpoints, other sandboxes, or the GCE metadata server. Blocking metadata
  is what keeps node and workload credentials out of sandboxes.
- Per-sandbox policy is set at create time (`network.allowOut`, `denyOut`,
  `allowPublicTraffic`) and replaceable with `PUT /sandboxes/{id}/network`. Domain rules go
  through a transparent egress proxy, match on SNI or Host, apply to HTTP and HTTPS only,
  and fail closed; `denyOut` takes IPv4 CIDRs only **[V-code]**.
- If sandboxes must call a private endpoint, for example an internal model server, the
  platform-wide `network.egress.always_denied_cidrs` list has to carve out exactly that
  range **[V-code]**. Treat any carve-out as a security review item.

**Client ingress.**
- Clients reach an internal Application Load Balancer (`gke-l7-rilb`) over HTTPS, which
  forwards to the gateway Service, then to node pods, then to the sandbox **[V-docs]**.
- A Cloud DNS private zone maps `*.sbx.<internal-domain>` to the load balancer's address, so
  sandbox ports resolve as `{port}-{id}.sbx.<internal-domain>`. Set `sandbox_proxy_domains`
  on both the gateway and the nodes.
- Certificates: a self-managed wildcard certificate or Certificate Authority Service, held
  in Certificate Manager (a public CA can't issue for a private zone) **[A]**. The load
  balancer needs a proxy-only subnet and a VPC-native cluster **[V-docs]**.
- The gateway's request timeout (90 s in the k8s config) exempts streams **[V-code]**;
  set the load balancer's backend timeout for long exec and WebSocket sessions **[A: test]**.
- Clients in other VPCs or projects: publish the load balancer through Private Service
  Connect **[A]**.

**Control-plane traffic inside the cluster.**
- Flows: gateway to scheduler (gRPC 9090), gateway to nodes (HTTP 8000), nodes to scheduler
  (heartbeats), scheduler to Redis (6379). All are plaintext upstream **[V-code]**.
- Restrict them with NetworkPolicy (GKE Dataplane V2) to exactly these flows. Node metrics
  on 8000 and 9103 are unauthenticated, so allow only the Prometheus collectors. Consider a
  service mesh or mTLS sidecars if plaintext inside the cluster is unacceptable **[A]**.

### 4.6 Identity and access (IAM)

**Principals and what they need:**

| Principal | Needs | Mechanism |
|---|---|---|
| Node pool service account | Write logs and metrics; pull the AgentENV runtime images | A minimal custom service account with log writer, metric writer, and Artifact Registry reader on the runtime-image repository only |
| `agentenv-node` Kubernetes service account | Read image layers, read and write snapshots, read its secrets | Registry credentials via a Docker config; HMAC key for the snapshot bucket; secrets from Secret Manager |
| `agentenv-scheduler` Kubernetes service account | Watch EndpointSlices and read Pods in its namespace | The existing namespaced Role **[V-code]** |
| `agentenv-gateway` | Nothing on Google Cloud | None |
| Image conversion pipeline | Read source images, write converted images | Artifact Registry writer on the target repository only |
| Operators | Deploy, upgrade, rotate secrets | Group-based IAM. Exec access to the runtime pods is root on the host, so treat it as break-glass |
| Clients (SDK users) | Call the AgentENV API | The shared API key. There is no per-user identity **[V-code]** |

**Registry credentials.** AgentENV reads registry credentials from a Docker config file at
startup and bakes them into its generated storage config, regenerating it only on the next
startup **[V-docs]** `docs/src/configuration/reference.md`. Artifact Registry's usual OAuth
access tokens expire after about an hour **[A]**, so a token written at startup goes stale.
Options:
1. A service-account JSON key through `_json_key` basic auth. Long-lived and discouraged;
   keep it in Secret Manager and rotate it.
2. A self-hosted registry reachable only inside the VPC, with basic auth or network-only
   access control. This fits if the registry is self-hosted anyway (section 4.7).
3. An upstream change so AgentENV refreshes registry credentials, for example through a
   credential helper or Workload Identity.

A sidecar that refreshes the Docker config doesn't help without option 3, because AgentENV
doesn't reload it. Recommendation: option 2 for the prototype; decide between 1 and 3 for
production.

**Snapshot bucket credentials.** The S3-compatible backend takes static keys or a
`credential_process` command **[V-code]**. Use a dedicated Google service account with
object admin on the snapshot bucket only. Its HMAC key (at most 10 per service account,
up to 60 s to become active **[V-docs]**) lives in Secret Manager, and a small argv-style
`credential_process` binary reads it from a mounted secret. OpenDAL's native GCS service
with Workload Identity would remove the HMAC key, but needs AgentENV support **[A]**.

**Secrets.** The API key, the sandbox access-token hash seed, the HMAC key and any registry
key live in Secret Manager, synced into Kubernetes Secrets by the Secret Manager add-on or
External Secrets **[A: pick one]**. Rotating the API key means updating the gateway, every
node and every client together; we saw no support for two keys at once, so plan a
maintenance window **[A]**.

**Kubernetes access control.**
- Run everything in a dedicated namespace labeled for the privileged Pod Security level.
- Restrict `exec`, `attach` and `port-forward` in that namespace to break-glass operators:
  a shell in the runtime pod is root on the host with access to `/dev`.
- Optionally enforce Binary Authorization for the runtime and control-plane images.

**API access control.** With one shared key and no tenancy **[V-code]**, network reachability
is the main control: the internal load balancer, firewall rules and NetworkPolicy. For
per-user identity later, put an authenticating proxy in front of the gateway that validates
Google identity tokens and tags sandboxes with the caller in `metadata` **[A]**.

**Audit.** Cloud Audit Logs cover the Google Cloud side (bucket, registry, GKE), not
AgentENV API calls. Send gateway and node access logs to Cloud Logging. With a shared key,
attribution is limited to "someone holding the key" until a per-user proxy exists.

**Credentials inside sandboxes.** Sandboxes can't reach the metadata server **[V-code]**, so
they never inherit node or workload credentials. If a task needs Google Cloud access,
inject a short-lived, narrowly scoped token through `envVars` at create time **[A]**.

**Org policy.** For the nested-virtualization option, the "Disable VM nested virtualization"
constraint must not be enforced **[V-docs]**.

### 4.7 Storage

**Where each kind of data lives:**

| Data | Location | Size and limits | Durability |
|---|---|---|---|
| Converted image layers (image cache) | Node local NVMe, `/var/lib/aenv` | 100 GB default; eviction from 95% down to 70%, least recently used, images idle at least 10 minutes **[V-code]** | Node-local, rebuildable |
| Remote block cache | Node local NVMe | 100 GB default; least recently used per layer **[V-code]** | Rebuildable |
| Snapshot artifact cache | Node local NVMe | 10 GB default **[V-code]** | Rebuildable |
| Running sandboxes' writable layers | Node local NVMe | Whatever the sandbox writes | Lost with the node |
| Paused sandboxes | Node local, `$AENV_HOME/persisted-sandboxes` **[V-code]** | Memory and disk deltas | Survive a runtime restart; lost when the node is replaced |
| Templates and committed snapshots | Snapshot repository: Cloud Storage or Filestore | Memory and disk layers, optionally lz4 or zstd compressed **[V-code]** | Durable |
| Persistent volumes (beta) | Committed on sandbox stop so another sandbox can mount them **[V-docs]**; presumably in the snapshot repository **[A]** | 64 GiB default, 256 GiB max, 4 per sandbox **[V-docs]** | Durable once committed |
| Images | OCI registry | The whole catalog | Durable |

**Node disk sizing.** Local NVMe must hold the caches (about 210 GB at defaults), running
sandboxes' writes, and paused sandboxes' deltas. Illustrative: 200 running sandboxes at 1 GB
plus 1,000 paused at 0.3 GB is about 0.5 TB on top of the caches, so about 1 TB per node
**[A]**. Local SSD tops out at 12 TiB on C3 VM shapes, 18 TiB on C4 VM and C4 bare-metal
`-lssd` shapes, about 35 TiB on Z3 VM shapes, and 72 TiB on Z3 bare metal; C3 bare metal
has none **[V-docs]**. Use raw
block mode and assemble the devices in the DaemonSet (section 4.3).

**Images.**
- Convert images to overlaybd-native once, in a batch pipeline (Cloud Build or Batch running
  the accelerated-container-image converter). Otherwise every node converts every standard
  image on first use, which takes tens of seconds per image on a miss **[V-code]**.

| Registry | Notes |
|---|---|
| Artifact Registry, same region | Range reads work; blob GETs redirect to Artifact Registry's own download endpoint, not Cloud Storage **[V-probe]**; quota 60,000 requests/min per project per region **[V-docs]**; short-lived tokens conflict with AgentENV's startup-only credential loading. See section 4.12 |
| Self-hosted CNCF distribution on GKE with the GCS driver and redirects | Blob reads go straight to Cloud Storage via signed URLs **[V-docs: distribution]**; network-only access control is possible; we operate it |

- Optional: AgentENV can publish a snapshot's root filesystem back to the source registry as
  an overlaybd image, which needs push credentials **[V-docs]**.

**Snapshot repository.**
- **Cloud Storage** through the S3-compatible XML API: multipart uploads are S3-compatible,
  but requests don't support preconditions and multipart objects have no MD5 **[V-docs]**,
  and S3-style conditional PUTs are silently ignored **[V-probe]** (section 4.13), which
  breaks AgentENV's catalog concurrency guards. Keep the bucket in the same region
  as the nodes, use uniform bucket-level access, add a lifecycle rule for abandoned
  multipart uploads, and don't add age-based deletion for live snapshots (AgentENV deletes
  through its API) **[A]**. Customer-managed encryption keys are optional.
- **Filestore** with `posix_fs`: simpler file semantics, but per-tier throughput limits and
  higher cost **[A]**.

**Bandwidth.** Origin reads scale with start rate times the bytes each start touches. Keep
nodes, registry and bucket in one region. Peer-to-peer sharing between nodes exists but is
marked experimental **[V-code]**.

**Lifecycle and backup.**
- Node caches evict themselves. Snapshots, templates and volumes are deleted through the
  API; add a periodic sweep for snapshots nobody references **[A]**.
- Templates can be rebuilt from images. Volumes hold user data, so they need an explicit
  backup policy, for example dual-region buckets or scheduled copies **[A]**.

### 4.8 Observability

Scrape node, ublk-daemon, gateway and scheduler metrics with Managed Service for Prometheus
(PodMonitoring). The node `/metrics` endpoint is unauthenticated, so restrict it with a
NetworkPolicy. Ship JSON logs to Cloud Logging. No tracing is available upstream.

### 4.9 Upgrades, repair and paused state

- Surge upgrades, auto-repair and autoscaler scale-down all wait at most one hour for drain;
  only autoscaled blue-green waits up to 24 hours **[V-docs]**.
- The preStop hook waits only for running sandboxes. **Paused sandboxes live on node-local
  storage, and local SSD data is lost when the node is replaced**, so an upgrade or repair
  loses every paused sandbox on that node **[V-code]** + **[V-docs]**.
- Mitigations: maintenance windows and "no minor or node upgrades" exclusions (they do not
  block auto-repair or host maintenance **[V-docs]**); autoscaled blue-green upgrades; and a
  pre-drain step that commits paused sandboxes worth keeping to the snapshot repository. The
  last one does not exist upstream **[A]**.
- On bare metal, host maintenance terminates the node; on nested virtualization, whether
  live migration preserves running microVMs is untested **[A]**.

### 4.10 Scaling

- **Phase 0:** a fixed-size pool, with cluster autoscaling disabled on it.
- **Hazard:** the cluster autoscaler ignores DaemonSet pods when deciding a node is empty
  (open-source autoscaler FAQ), so a node running only microVMs can look idle and be removed
  **[A: not in GKE docs; test]**. If autoscaling is ever enabled, annotate nodes with
  `cluster-autoscaler.kubernetes.io/scale-down-disabled=true` and drain deliberately.
- **Later:** a small controller that reads `GET /nodes` (allocated CPU and memory, sandbox
  counts) and resizes the pool through the GKE API, draining a chosen node before deleting
  it (manual resize removes nodes at random and must not be mixed with the autoscaler
  **[V-docs]**). Alternatives to evaluate: CapacityBuffer (Preview, scales existing pools
  without auto-provisioning) or low-priority placeholder pods **[V-docs]**.

### 4.11 Security review items

Privileged DaemonSet with host `/dev`; plain-HTTP node API behind the TLS gateway; shared API
key; per-sandbox tokens derived from one seed; KVM isolation boundary versus gVisor's model;
unauthenticated metrics endpoints.

### 4.12 Artifact Registry gaps

AgentENV loads image blocks lazily with HTTP range reads against the registry, and caches
blob redirect URLs until they expire **[V-code]** `storage/overlaybd/src/backend/registryfs_v2.rs`.
Artifact Registry works as that origin, but it has gaps compared with what AgentENV is built
for, which is Azure Container Registry's artifact streaming or a self-hosted registry.

**What we measured** (one blob in a `us` multi-region Docker repository, probed from a
laptop, 2026-09-22) **[V-probe]**:

| Question | Result |
|---|---|
| Does a blob GET redirect? | Yes, a 302, but to Artifact Registry's own download endpoint on the same host (`/artifacts-downloads/...`), not to a Cloud Storage signed URL |
| Do range reads work? | Yes: 206 with `Accept-Ranges: bytes`, at arbitrary offsets including mid-blob |
| Does the download URL need auth? | No. The URL itself grants read access |
| Is the download URL single-use? | No. The same URL served several ranged reads |
| Latency per 1 MiB range | 0.35 to 0.6 s over the internet; not representative of in-region reads |

**Gaps:**

| # | Gap | Impact on AgentENV | Workaround |
|---|---|---|---|
| 1 | No lazy-loading format. Azure generates overlaybd referrers ("artifact streaming"); Artifact Registry doesn't. AgentENV recognizes only Azure's and the open-source converter's referrer types **[V-code]**. GKE Image Streaming is a separate node-level mechanism AgentENV can't use **[A]** | Standard images are downloaded in full and converted on every node on first use | A batch conversion pipeline that pushes overlaybd images (section 4.7) |
| 2 | OCI Referrers API support is unverified **[A]** | Decides whether converted images can be attached as referrers of the original or must be separate tags | Test it; fall back to separate tags plus `try_referrers_overlaybd_prefixes` off |
| 3 | Bytes are served through Artifact Registry's own download endpoint, not Cloud Storage **[V-probe]** | Every lazy read goes through the registry front end; its throughput limits and egress cost at fleet scale are unknown **[A]** | Load-test in-region; compare with a self-hosted registry that redirects to Cloud Storage |
| 4 | Request quota: 60,000 requests/min per project per region, charged per HTTP request **[V-docs]**. Whether download-endpoint range reads count is unknown **[A]** | Lazy loading issues many small ranged reads; about 1,000 requests/s per region, shared by the whole project, can run out at high start rates | Request a quota increase; dedicate a project to the image origin; measure the burn rate |
| 5 | Short-lived OAuth tokens (about an hour **[A]**) vs AgentENV loading registry credentials only at startup **[V-docs]** | Once the startup token expires, requests for blobs without a cached redirect fail | Partial mitigation: download URLs work without auth and are reusable **[V-probe]**, and AgentENV caches them until they expire **[V-code]**. Their lifetime is unknown **[A]**. Otherwise a JSON-key basic-auth credential, or an upstream credential refresh (section 4.6) |
| 6 | Download URLs are capabilities: anyone holding one can read the blob while it's valid **[V-probe]** | Leaked URLs in logs or metrics expose private image content | Keep them out of logs; confirm their expiry |
| 7 | Location choice. The repositories we checked are multi-region (`us`) **[V-probe]** | A multi-region repository adds latency for a fleet in one region **[A]** | Use a regional repository in the fleet's region |
| 8 | No node-level or peer caching. Remote repositories proxy upstream registries but don't cache on nodes **[A]** | Every node fetches from the origin; AgentENV's peer-to-peer layer is experimental | Rely on AgentENV's bounded node cache; evaluate its peer-to-peer layer later |

**Update from the prototype (2026-09-23) [V-probe]:**

- **Private repositories work with a Workload Identity token sidecar.** The runtime pod's
  Kubernetes ServiceAccount was granted `roles/artifactregistry.reader` per repository, and
  a sidecar refreshes `~/.docker/config.json` with the access token every 15 minutes.
  AgentENV's standard-OCI puller (`regctl`) reads that file on every call, so the
  startup-only credential loading (gap 5) does not affect this path. Task images of 1.2 to
  1.3 GB from two private repositories pulled and ran.
- **Per-node conversion is the real cost, not the registry.** A standard OCI task image
  takes 42 to 52 s on its first create on a node (pull plus overlaybd conversion,
  synchronous in the create call) and 2.3 s on a node that has converted it; each node
  converts and stores its own copy (about 4.5 GB per image). Hence the conversion
  pipeline: a one-time job converting the SWE-bench Verified set into a new regional
  repository, `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images`, so nodes
  lazy-load blocks instead of converting (in progress at the time of writing).
- **GKE Image Streaming does not apply.** It accelerates images containerd pulls for pods;
  AgentENV pulls sandbox images itself and never goes through containerd. Enabling it would
  speed up only the runtime pod's own image pull on a fresh node.
- **Nydus does not apply either.** Nydus is a file-and-chunk lazy filesystem served by a
  daemon; AgentENV needs block-level overlaybd layers exposed through ublk and has no Nydus
  reader. The two are alternatives for the same job; AgentENV chose overlaybd.
- **Dragonfly is compatible at the protocol level.** AgentENV's lazy-block reader has an
  "accelerate address" hook that rewrites each blob range read to
  `http://<address>/<original blob URL>` with a Range header, the same convention upstream
  overlaybd uses with a Dragonfly peer daemon **[V-code]** `registryfs_v2.rs`. Against
  Artifact Registry specifically:

  | Aspect | Status | Notes |
  |---|---|---|
  | Registry compatibility | Works | Dragonfly proxies any OCI registry or HTTP origin **[V-docs]** |
  | Authentication | Works, one caveat | Dragonfly holds no pull credentials; the client's `Authorization` header passes through, so short-lived Artifact Registry tokens work if the client refreshes them. Peers serve cached pieces without re-authorizing: one trust domain per Dragonfly deployment **[V-docs]** / **[A]** |
  | Blob redirects | Untested | Artifact Registry answers blob GETs with a 302 to its own download endpoint whose path carries an unauthenticated token **[V-probe]**. Dragonfly follows redirects and is built for redirected storage URLs, but caching behaviour for this redirect shape needs a test **[A]** |
  | Range requests | Works | Served from cached pieces; required by the lazy reader **[V-docs]** |
  | Preheating | Works | The Dragonfly manager can pre-seed images from a private registry across peers **[V-docs]**: warm every node once after conversion and origin reads become rare |
  | Request quota | Helps | Each blob range is fetched from the origin once per cluster instead of once per node |

- **Lazy loading from Artifact Registry verified end to end, after two fixes [V-probe].**
  A converter image (containerd `convertor` v1.4.5 plus the AgentENV fork's overlaybd
  tools) converts a SWE image in about 40 s in Cloud Build into
  `us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified:<instance>`
  (Docker v2 manifest, 16 overlaybd layers, 1.7 GB, each layer annotated with
  `containerd.io/snapshot/overlaybd/blob-digest`, which is what AgentENV keys on). Results:

  | Create from a converted image | Measured |
  |---|---|
  | Image never seen by any node, on each of 4 nodes | 4.6 to 5.0 s to running |
  | Remote-block cache growth per node per image | 16 to 85 MB (versus about 4.5 GB converted per node before) |
  | First command in a fresh lazy sandbox | 15.7 s wall, including SDK connect and first-touch block reads |

  The two fixes: (a) the lazy reader is wired to the Docker credential file only if it
  exists **at startup**, so the token sidecar had to become a native sidecar (init
  container with `restartPolicy: Always` and a startup probe on the file); (b) Artifact
  Registry answers blob GETs with a **relative** `Location` (`/artifacts-downloads/...`)
  and v0.2.2's lazy reader stores it verbatim and fails with "relative URL without a base".
  A six-line patch (resolve the redirect against the request URL) is built into a local
  runtime image and pinned in the prototype; upstream `main` has the same code and no
  issue yet, so this needs an upstream PR (gap 33).

- **Full conversion run:** 500 images in ten parallel Cloud Build shards took about
  70 minutes; 499 succeeded on the first pass. The one failure was a transient 502 from
  Artifact Registry's token endpoint during a layer upload, which the converter does not
  retry; a re-run fixed it. Any bulk pipeline against Artifact Registry needs retries on
  5xx for both blob and token requests **[V-probe]**.

  What is missing on the AgentENV side: in v0.2.2 the accelerate address is set only by
  AgentENV's own experimental peer-to-peer transport, and the generated storage config is
  rewritten at every startup, so pointing it at a Dragonfly peer needs a small upstream
  change or a startup patch (gap 32). Dragonfly only helps the lazy path; the standard-OCI
  path could use it as a registry mirror, but pre-conversion removes that path anyway.

**Asks for the Artifact Registry team**, if we pursue this with them:
1. A lazy-loading export, like Azure's artifact streaming: generate overlaybd, or another
   seekable format, as OCI referrers at push time.
2. Document the download endpoint's redirect, range and lifetime behavior, and whether its
   requests count toward quota.
3. A quota class suited to high-rate ranged blob reads, or a higher default.
4. A pull credential that suits long-running daemons, such as documented credential-helper
   support that refreshes tokens without restarts.

**How to re-run the probe** (read-only; needs `gcloud` auth and read access to a repository):

```bash
REG=us-docker.pkg.dev; NAME=PROJECT/REPO/IMAGE; DIGEST=sha256:LAYER_DIGEST
TOKEN=$(gcloud auth print-access-token)
# 1. Expect a 302 to /artifacts-downloads/...
curl -s -o /dev/null -D - -H "Authorization: Bearer $TOKEN" \
  "https://$REG/v2/$NAME/blobs/$DIGEST" | grep -i -E '^HTTP|^location'
# 2. Follow it with a range; expect 206 and a Content-Range header
curl -s -o /dev/null -D - -H "Range: bytes=0-1048575" "https://$REG<location-path>" \
  | grep -i -E '^HTTP|^content-range'
```

Run it from a node in the fleet's region to get representative latency, and repeat it after
an hour to learn the download URL's lifetime.

### 4.13 Metadata, consistency and queryability

AgentENV has **no central database or shared key-value store** for management data. The
durable shared record is a set of JSON objects in the snapshot repository; everything else
is in process memory or in embedded RocksDB instances on each node.

**Where management data lives:**

| Data | Store | Scope | Survives |
|---|---|---|---|
| Templates, snapshots, aliases | Snapshot repository: `catalog/records/{id}.json`, `catalog/aliases/{alias}.json`, beside each snapshot's manifests and layers **[V-code]** `src/snapshot/repository/backends/oss/layout.rs` | Shared | Durable; the source of truth for the template and snapshot APIs |
| Persistent volume catalog | Snapshot repository (shared volume catalog) **[V-code]** `src/snapshot/repository/interfaces.rs` | Shared | Durable |
| Running sandboxes | Node process memory | Per node | Nothing; running sandboxes are paused on shutdown **[V-code]** |
| Paused sandboxes | Embedded RocksDB `records.db` plus artifacts under `$AENV_HOME/persisted-sandboxes` **[V-code]** `src/orchestrator/persistence/file_backed.rs` | Per node | A runtime restart; lost with the node's disk |
| Image cache graph, conversion index | Embedded RocksDB **[V-code]** `src/image/cache/graph.rs` | Per node | Rebuildable |
| Template build state | Embedded RocksDB **[V-code]** `src/api/impls/image_build.rs` | Per node | Per node only |
| Peer-to-peer artifact catalog | Embedded RocksDB **[V-code]** `src/p2p/iroh/catalog.rs` | Per node | Per node only |
| Sandbox-to-node bindings | Scheduler memory, or Redis if configured **[V-code]** | Shared, routing only | With Redis, a scheduler restart; otherwise rebuilt from heartbeats |
| Node load snapshots | Scheduler memory, from heartbeats **[V-code]** | Shared | Rebuilt from heartbeats |
| Gateway | Stateless | | |

**Consistency model:**
- **Snapshot and volume records** are written conditionally: `If-Match` on the inspected
  ETag to update, `If-None-Match: *` to create **[V-code]** `src/snapshot/repository/backends/oss/client.rs`.
- **Alias bindings are best-effort, not atomic:** read, write unconditionally, then read
  back to detect a lost race. The code says Alibaba Cloud OSS lacks conditional writes and
  that this is acceptable while concurrent publishes to the same alias are rare **[V-code]**.
- **Publish ordering:** aliases become visible only after the snapshot record and its
  artifacts are durable **[V-code]** `interfaces.rs`.
- **Routing versus truth:** each node's heartbeat carries its full sandbox roster, which
  the scheduler treats as authoritative; bindings missing from the latest roster are
  dropped, and `binding_ttl` expires stale ones **[V-code]**. Right after a scheduler
  restart without Redis, routing to existing sandboxes can miss until heartbeats arrive.
- **Create is not idempotent** (server-generated IDs, no idempotency key), so a retried
  create can leave an orphan **[V-code]**.
- **No cross-store transactions.** A node that dies mid-operation can leave repository
  objects without a matching node record, or the reverse; there is no reconciler beyond
  heartbeats and cache GC **[A]**.
- **GCP finding (probed 2026-09-23 on a test bucket, OAuth bearer auth) [V-probe]:**
  Cloud Storage's S3-compatible XML API **ignores** S3-style conditional headers on PUT.
  `If-None-Match: *` on an existing object returned 200 and overwrote it; `If-Match` with
  a stale ETag returned 200 and overwrote it; only the GCS-native
  `x-goog-if-generation-match: 0` returned 412. AgentENV's OpenDAL S3 client sends exactly
  those S3 headers (`client.rs`), so on Cloud Storage its create-if-absent and
  optimistic-update guards for snapshot and volume records are silent no-ops: concurrent
  writers overwrite each other with no error. Caveat: probed with a bearer token rather
  than HMAC SigV4; the server-side header handling should not differ, but re-run with HMAC
  before closing this. Fixes: an OpenDAL native-GCS backend in AgentENV (generation
  preconditions), Filestore with `posix_fs` (file locks), or serializing catalog writers
  (one publisher, no concurrent volume updates).

**Queryability:**

| Question | How to answer it | Limits |
|---|---|---|
| Which sandboxes exist? | `GET /v2/sandboxes` through the gateway, which fans out to every node and merges | Fails as a whole if any node fails to answer **[V-code]**; cost grows with node count |
| Filter sandboxes | `state` filter, `metadata` key=value query, pagination **[V-code]** | Exact-match metadata only; no free-text or range queries |
| Templates and snapshots | List and get by ID, alias or alias prefix **[V-code]** | Served from the repository catalog; listing scans `catalog/records/` **[V-code]** |
| Node capacity and load | `GET /nodes`, `GET /nodes/{id}` **[V-code]** | Point-in-time snapshots |
| History (who created, paused or deleted what, when) | Not available | Deleted sandboxes leave no record; needs gateway access logs **[A]** |
| Change notifications | No watch or event stream found **[A]** | Clients must poll |
| Aggregates and trends | Prometheus metrics **[V-code]** | Counts and latencies, not per-sandbox inventory |

Compared with agent-sandbox, which stores every object in the Kubernetes API (label
selectors, watches, `kubectl`, audit logs), AgentENV trades that queryability for keeping
per-sandbox state off the control plane.

**Recommendations:**
1. Treat the snapshot bucket as the only durable management store; back it up and restrict
   write access to AgentENV's service account.
2. Tag every sandbox with `metadata` for owner, run and purpose at create time; it's the only
   server-side filter.
3. Keep an external inventory if you need history: ship gateway access logs to Cloud
   Logging, or have the SDK backend record creates and deletes.
4. Run a periodic reconciler that lists by metadata and kills orphans (the RL SDK reaper in
   section 5.3 is one instance).
5. Verify conditional writes on Cloud Storage before relying on concurrent template or
   volume updates (hands-on check in section 7).

### 4.14 RBAC and authorization

**AgentENV has no RBAC.** One shared API key grants every control-plane operation,
including node inspection. The OpenAPI spec declares E2B's team and bearer schemes for
compatibility, but the server checks only the key; its claims type carries no identity
**[V-code]** `src/api/impls/auth.rs`. On the data plane, per-sandbox tokens act as
capabilities: whoever holds a sandbox's envd token can run commands in it **[V-code]**.

**Comparison:**

| | agent-sandbox | AgentENV |
|---|---|---|
| Identity | Kubernetes users, groups and service accounts | None; whoever holds the API key |
| Authorization | Kubernetes RBAC on Sandbox, SandboxClaim, SandboxTemplate and SandboxWarmPool, per namespace; router TokenReview | All-or-nothing API key; per-sandbox capability tokens |
| Isolation unit | Namespace | The whole AgentENV cluster |
| Audit | Kubernetes audit logs | None built in |

**Kubernetes RBAC for the deployment itself:**
- `agentenv-scheduler`: the existing namespaced Role (get, list and watch EndpointSlices
  and Pods) **[V-code]**. The gateway and node service accounts need no Kubernetes API access.
- `agentenv-operator` (group-bound): manage the Deployments and DaemonSet in
  `agentenv-system`. Grant `pods/exec`, `pods/attach` and `pods/portforward` only through
  break-glass, since a shell in a runtime pod is root on the host.
- `agentenv-viewer`: get and list Pods, read logs, no Secrets.
- **Secrets:** reading `agentenv-auth` equals full AgentENV API access, and reading the
  token seed lets someone derive every sandbox's tokens. Restrict `get` on Secrets in
  `agentenv-system` to the operator role and the workloads.

**Proposed RBAC for the AgentENV API (future work):** an authenticating proxy in front of
the gateway.

| Role | Allowed |
|---|---|
| `viewer` | List and get own sandboxes; list templates |
| `user` | Viewer, plus create, pause, resume, fork and kill own sandboxes from allowed templates |
| `template-admin` | Build, publish and delete templates and snapshots; manage volumes |
| `operator` | Everything, including `GET /nodes` and other users' sandboxes |

How it would work:
- The proxy authenticates callers with Google identity tokens and maps groups to roles
  **[A]**.
- On create, it injects `metadata.owner=<principal>` and `metadata.team=<group>`. On list,
  it adds a metadata filter. On per-sandbox calls, it checks ownership with a `GET` before
  forwarding.
- It returns per-sandbox tokens only to the owner, and covers the host-based data-plane
  routes (`{port}-{id}.{domain}`), not only the API paths.

Limits:
- Ownership lives only in client-writable metadata, so the proxy must be the only path to
  the gateway (NetworkPolicy).
- Templates and snapshots have no owner field, so template permissions are per role, not
  per object **[A]**.
- Every per-sandbox call gains an extra lookup.

The alternative is one AgentENV cluster per team, which gives hard isolation at the cost of
more clusters to operate.

## 5. Part 2: an AgentENV backend for the SDKs

### 5.1 What exists today

- **No SDK has a backend abstraction.** The Python `SandboxClient` always builds a
  `K8sHelper` in its constructor, and `Sandbox` identity is `(namespace, claim_name)`
  **[V-code]** `clients/python/agentic-sandbox-client/k8s_agent_sandbox/sandbox_client.py`,
  `sandbox.py`.
- The only seam is transport: `ConnectionStrategy` in the sync connector (`connector.py`),
  and inline branches in the async connector, which has no strategy class **[V-code]**.
- Commands are unary (`CommandExecutor.run`), although sandboxd's proto supports streaming
  **[V-code]**.
- The RL SDK runs commands through the **Kubernetes pod exec API** in `SandboxHandle.exec`
  and `SandboxSession`, not through the SDK's command API **[V-code]**
  `examples/agent-sandbox-rl/agent_sandbox_rl/handles.py`.
- The Go SDK already has a backend-neutral `Handle` interface (`clients/go/sandbox/types.go`);
  the TypeScript SDK has no command or file API yet **[V-code]**.

### 5.2 Python SDK design

Add `k8s_agent_sandbox/backends/` with a `SandboxBackend` protocol and an async twin
(the repo requires sync/async parity):

| Operation | AgentENV call | Current SDK callers |
|---|---|---|
| `create(template, metadata, env, timeout_s) -> SandboxRef` | `POST /v2/sandboxes` | `SandboxClient.create_sandbox` (replaces claim create + wait) |
| `get(id)` / `status(id)` | `GET /sandboxes/{id}` | `get_sandbox`, `Sandbox.status`, `is_suspended` |
| `run(id, cmd, timeout, env, cwd) -> ExecutionResult`; `start(...)` streaming | envd Process | `CommandExecutor.run` and async twin |
| `read/read_stream/write/list/exists/delete` | envd Filesystem, `/files` | `Filesystem.*` and async twin; add `FileEntry.from_envd` |
| `port_url(id, port)` | `{port}-{id}.{domain}` | new; used by computer-use and RL `endpoint()` |
| `pause(id)` / `resume(id)` | `POST .../pause`, `POST /v2/.../connect` | `SandboxWithSnapshotSupport.suspend/resume` |
| `fork(id, count) -> [SandboxRef]` | `POST /sandboxes/{id}/fork` | new |
| `set_timeout(id, s)` | `POST .../timeout` | replaces `shutdown_after_seconds` |
| `kill(id)` | `DELETE /sandboxes/{id}` | `terminate`, `delete_sandbox`, `delete_all` |
| `list(metadata)` | `GET /v2/sandboxes?metadata=...` | `list_all_sandboxes`, reaping |

- `KubernetesBackend` wraps today's code paths unchanged; it stays the default, so existing
  users see no change (additive API, no breaking change).
- `AgentEnvBackend` ships behind a new optional extra `agentenv`, following the repo's
  extras pattern. Configuration is a pydantic model in `models.py`:
  `AgentEnvBackendConfig(api_url, api_key, sandbox_domain, template_map, default_timeout_s)`.
- `SandboxClient(backend=...)` and `AsyncSandboxClient(backend=...)` accept the backend;
  `Sandbox` gains a backend-neutral `sandbox_id` and keeps `claim_name`/`namespace` as
  optional Kubernetes-only fields.
- The `warmpool` argument maps to a template ID through `template_map`.
- Implementation choice **[open]**: depend on the official `e2b` SDK inside the extra (fast,
  documented to work, fork needs a raw call) or write a thin client for the REST API and
  envd's Connect-RPC (more work, fewer dependencies). Start with the `e2b` SDK for the
  prototype.
- Path handling: envd uses absolute paths, while the SDK's `_safe_upload_path` forces
  relative ones; define the mapping explicitly.
- Tracing: carry the OTel context and run identity in sandbox `metadata`.

### 5.3 RL SDK design

- `ClusterConfig.backend = "kubernetes" | "agentenv"`, with an `AgentEnvCluster` that
  satisfies the duck-typed `Cluster` interface (`tests/conftest.py`'s `FakeCluster` already
  shows it is an interface in practice).
- `SandboxHandle.exec` and `SandboxSession` dispatch on the backend: envd process start for
  one-shot commands, envd PTY for sessions. `endpoint(port)` returns the proxy URL.
- Warm-pool operations become template checks: `ensure_template` verifies the AgentENV
  template exists, while `create_warmpool`, `set_pool_replicas` and `wait_for_pool_ready` do
  nothing. AgentENV's own node pools and snapshot resume replace them.
- Reaper, teardown and the overcommit breaker list sandboxes by `metadata.run_id` and kill
  them. Because create isn't idempotent, a retried create can leak a sandbox; the reaper by
  metadata is the safety net.
- Preflight becomes: gateway reachable, API key valid, template exists.
- New: `SandboxFleet.fork_group(task, n)` using the fork endpoint (children share the source's
  node), and a reset tier in `recycle.py` that resumes from a snapshot instead of
  `git restore`.
- `async_fleet.py` wraps the sync fleet in threads, so it inherits the backend for free.

### 5.4 What doesn't carry over

Warm-pool sizing and adoption; Kubernetes identity (`claim_name`, `pod_name`, `pod_ip`,
in-cluster hostnames); pod-level parameters (`pod_labels`, `pod_annotations`,
`volume_claim_templates`, `runtime_class`, `node_selector`, pull secrets, `extra_pod_spec`);
per-sandbox CPU and memory on template creates (use `/sandboxes-cold` or a template per
shape); the r2egym kubectl binding and OpenHands `pod_ip` URL templating; run-isolation
namespaces. `labels` become `metadata`.

### 5.5 Go and TypeScript

Go: implement the existing `Handle` interface in a new `agentenv` type. TypeScript: a new
client using `fetch`, once the SDK grows command and file APIs. Both are later phases.

### 5.6 Upstream fit

agent-sandbox is a Kubernetes SIG Apps project. A non-Kubernetes backend inside its SDKs may
not be accepted upstream. Options: propose the backend abstraction upstream (useful on its
own for testing) and ship the AgentENV backend as an out-of-tree package registered through
Python entry points; or keep the whole thing in a separate package. Raise this in an issue
before writing code.

### 5.7 Testing

Unit tests with fakes mirroring `test_sandboxd.py` (Python SDK) and `FakeCluster` (RL SDK);
contract tests against a real AgentENV on a GKE test pool (KVM is required, so kind in CI
won't do); an RL end-to-end run comparing both backends.

## 6. Phased plan

| Phase | Deliverable | Exit criteria |
|---|---|---|
| 0. Prototype | AgentENV on one nested-virt node (existing test pool), fixed size; registry and GCS checks | Sandboxes create, pause, resume and fork; hands-on checks in section 7 answered |
| 1. Benchmark | Same workload on nested virt vs bare metal (C4 with local SSD, or C3 with Hyperdisk) vs agent-sandbox with gVisor | Density and latency targets met (section 7) |
| 2. Harden | TLS gateway, HA, Redis, host prep, storage pipeline, observability, upgrade policy | Survives a node drain and a gateway restart without losing running sandboxes |
| 3. Python SDK | Backend protocol plus `agentenv` extra, sync and async | Existing SDK tests pass unchanged; new backend tests pass |
| 4. RL SDK | `AgentEnvCluster`, exec and session dispatch, `fork_group`, reaper by metadata | An RL run completes on AgentENV with the same task code |
| 5. Scale | Pool autoscaler from `GET /nodes`; Go backend | Scales up and down without killing busy nodes |

## 7. Benchmarks and hands-on checks

| Measure | Target to set | Notes |
|---|---|---|
| Sandboxes per node, idle and active | vs pods/node for gVisor on the same machine | The density claim |
| Resume from snapshot, p50/p99 | vs claimed under 50 ms | Most exposed to nesting overhead |
| Cold start from overlaybd image, p50/p99 | vs warm-pool claim today | Cache miss and cache hit separately |
| Creates per second per node | | Start throughput |
| Fork of N children | time and memory for N = 8, 32, 100 | RL grouped rollouts |
| Build-heavy task duration | vs gVisor | Nested I/O overhead |

Hands-on checks before committing:
1. Artifact Registry, from a node in the fleet's region: range-read latency and throughput, the download URL's lifetime, whether download-endpoint reads count toward quota, and OCI Referrers API support. Redirect and range behavior are already confirmed (section 4.12).
2. Bare metal on GKE 1.35: whether a `c4-standard-288-lssd-metal` node pool is accepted; on the chosen bare-metal type, `/dev/kvm`, ublk, io_uring and IDPF support in the node image; host-maintenance behaviour; for C3 bare metal, cache and snapshot I/O on Hyperdisk.
3. OpenDAL against GCS: S3 service over the XML API (multipart, conditional writes) vs OpenDAL's native GCS service with Workload Identity.
4. Whether the autoscaler removes nodes whose only load is the DaemonSet.
5. Whether nested-virt nodes live-migrate with running microVMs, and whether guests survive.
6. Gateway timeouts for long exec and WebSocket streams.
7. ~~The actual `ublks_max` default~~ **Done:** the kernel default on COS 6.12 is 64; the init container sets 4096. Devices per sandbox not yet counted.
8. Registry authentication: AgentENV with Artifact Registry credentials over a multi-hour run, and with a self-hosted registry.
9. ~~No routing breakage with the chosen GKE ranges next to AgentENV's internal pools.~~ **Done:** one and four runtime nodes, sandboxes reachable and placed round-robin.
10. ~~Cloud Storage through the S3-compatible API honors `If-Match` and `If-None-Match` on ordinary writes~~ **Done, negative result:** it ignores them (section 4.13). Remaining: repeat with HMAC SigV4 auth, and decide between a native-GCS backend, Filestore, or serialized writers.
11. Dragonfly in front of Artifact Registry: deploy peers on the KVM pool, point one node's accelerate address at its local peer, confirm the 302-to-download-endpoint blob shape is cached correctly and ranges are served from pieces, then compare Artifact Registry request counts and cold starts with and without it, after the converted images exist.

## 8. Risks and open questions

1. **Paused sandboxes are lost when a node is replaced** (upgrade, repair, host maintenance). Is committing them to the repository before drain feasible, and worth it?
2. **Artifact Registry at lazy-load request rates** may hit quota or add latency, since bytes flow through its own front end rather than Cloud Storage; self-hosting the registry may be required (section 4.12).
3. **Single shared API key, no tenancy.** Acceptable for one team; multi-team use needs an auth proxy.
4. **Create is not idempotent.** Client retries can leak sandboxes; reaping by metadata must be reliable.
5. **Fork is same-node only.** Large groups concentrate on one host; is `count` up to 100 on one node acceptable for our shapes?
6. **Upstream acceptance** of a backend abstraction in a Kubernetes SIG SDK (section 5.6).
7. **Operational ownership.** Someone must own the AgentENV fleet: upgrades, image pipeline, registry, capacity.
8. **Registry credentials are loaded only at startup**, which conflicts with short-lived Artifact Registry tokens (section 4.6).
9. **Project maturity.** AgentENV is young (P2P is marked experimental; docs lag the code, for example on the Redis binding store). Pin a version and track upstream.

## 9. Prototype results (barkland-test, 2026-09-23)

A working deployment now exists; see the repository `tomergee/agentenv-on-gke`
(`deploy/`, `scripts/`, `tests/RESULTS.md`, `review/findings.md`, `plans/decisions.md`).
Everything in this section is **[V-probe]** unless marked otherwise.

**What was built.** AgentENV v0.2.2 on GKE 1.35.8: upstream `aenv-server:v0.2.2-amd64` as
the runtime image on a privileged DaemonSet, gateway and scheduler images built with Cloud
Build into Artifact Registry (upstream publishes neither; `--build-arg TARGETARCH=amd64` is
required), a kustomize overlay with a host-prep init container, Secrets created by a deploy
script, control plane pinned to the default pool, runtime on a nested-virtualization pool
of `c2-standard-8` nodes (Container-Optimized OS, kernel 6.12, 100 GB pd-balanced boot
disk, no local SSD). Scaled from one to four runtime nodes at the end; new nodes joined
through the DaemonSet and EndpointSlice discovery with no configuration change.

**All 13 acceptance criteria pass** (create, command via the E2B SDK, pause, resume with
state preserved, fork into two, kill, redeploy, teardown, blast radius). Timings on nested
virtualization, from the client through the gateway:

| Operation | Measured |
|---|---|
| Cold create, image never seen on the node (pull + overlaybd conversion) | 5.4 s (7.3 s on a brand-new node) |
| Create, image already converted | 2.4 s |
| Command round trip (E2B SDK, envd process API) | 0.3 s |
| Pause | 0.4 s |
| Resume | 0.85 s |
| Fork into 2 children, both answering | 1.3 s |
| Kill | 0.4 s |
| Placement of 8 creates across 4 nodes | 2 per node (round-robin) |

These are cold-create and in-node pause/resume paths; upstream's sub-50 ms figure is for
resume from a committed snapshot template, which the prototype did not exercise.

**Confirmed on GKE.** COS nodes work: `/dev/kvm`, io_uring, `ublk_drv` (kernel default
`ublks_max` was 64; the init container reloads it at 4096 when no devices are in use),
iptables and network namespaces inside the privileged pod, image pulls from public
registries, envd reachable through the gateway with `e2b-sandbox-id` / `e2b-sandbox-port`
headers. Requests without the API key get 401; `/health` is unauthenticated by design and
returns 204. Node disk after all tests: about 11 GB used, about 530 MB of persistent state
under the hostPath.

**New findings (added to the gaps table as rows 29-30, and to existing rows):**
1. **Startup downloads from the internet.** On each fresh node the runtime downloads
   Firecracker, the guest kernel, the tools drive and overlaybd tools from GitHub and ghcr
   at pod start. On two of three new nodes DNS was not ready yet, the download failed, the
   container exited and Kubernetes restarted it; it succeeded on the retry. No retry inside
   the runtime; a private mirror or baked-in dependencies would remove the dependency on
   internet egress at boot.
2. **Shutdown ordering.** With the scheduler already gone, runtime shutdown blocks about
   126 s on an in-flight heartbeat RPC before continuing; with the scheduler up it takes
   2 s. A namespace delete hits this every time. Relevant to node drains during upgrades
   (gap 19): drain runtime pods before the control plane, or fix the timeout upstream.
3. **Node visibility after a scheduler restart.** `GET /nodes` returns an empty list for up
   to about 160 s after the scheduler restarts while creates and commands keep working,
   because heartbeat records are rebuilt. Health checks that read `/nodes` must tolerate it.
4. **API version skew.** v0.2.2 has `/sandboxes/{id}/resume` and `/connect` but not the
   `/v2/sandboxes/{id}/connect` that upstream `main` and the E2B SDK's `Sandbox.connect`
   use; the `/proxy` path prefix returns 404 (header routing works); `?state=a,b` returns
   400 (one state per query). The SDK backend (section 5) must target a pinned API version
   or feature-detect.
5. **envd reachable with the API key alone** for cold creates that don't set `secure`;
   the per-sandbox access token is not required then. Anyone holding the shared key can run
   commands in any such sandbox. Strengthens gaps 2 and 26.
6. **Teardown must kill sandboxes first.** The DaemonSet's preStop waits for running
   sandboxes to drain for up to 3600 s; a plain namespace delete stalled for minutes. The
   repo's teardown script kills sandboxes, removes the runtime, then the namespace (28 s).

**Task images from a private registry (added later on 2026-09-23).** The runtime pod's
Kubernetes ServiceAccount was granted `roles/artifactregistry.reader` on the task-image
repository, and a sidecar refreshes a Docker config with the Workload Identity access token
every 15 minutes; `regctl`, which AgentENV uses for standard OCI pulls, reads that file on
every call, so the startup-only credential loading (gap 5) does not bite for this path. A
1.3 GB, 16-layer SWE-rebench image then ran end to end:

| Operation, SWE-rebench image | Measured |
|---|---|
| Cold create, first time on a node (pull + conversion, synchronous in the POST) | 52.5 s |
| Create on another node that had not converted it (round-robin) | 58 to 62 s |
| Command round trip | 0.5 s |
| Pause / resume / fork of 2 | 1.6 s / 0.9 s / 1.5 s |

7. **Per-node conversion multiplies cold starts.** Placement is round-robin and conversion
   is per node, so with N runtime nodes each distinct image is pulled and converted up to N
   times and occupies N caches; "warm" only holds on a node that has already seen the
   image. For thousands of task images this is the dominant cost. Fixes: image-aware
   placement (the scheduler receives an `images` hint but ignores it, gap 8) or a
   pre-conversion pipeline publishing overlaybd images so nodes lazy-load blocks instead of
   converting (gap 6).
8. **API key rotation requires restarting the gateway and every runtime pod.** The gateway
   injects its own copy of the key toward nodes and reads it only at startup; when the
   Secret changed and only the runtime pods restarted, every request failed with 401. There
   is no hot reload and no dual-key window. Gap 31.

9. **Lazy loading needs the credential file at startup.** The overlaybd reader picks up
   `~/.docker/config.json` only when it exists when the runtime starts; a plain sidecar
   raced it. A native sidecar with a startup probe fixed it. The lazy reader then keeps the
   startup token, so long-running nodes need a restart or an upstream re-read once the
   token expires (gap 5).
10. **Artifact Registry's relative redirect breaks stock lazy loading.** Fixed with a local
    patch; see section 4.12 and gap 33.

**Pre-converted images (2026-09-23).** With the SWE-bench Verified set converted to
overlaybd in a regional repository, a create of an image no node has seen takes 4.6 to
5.0 s on any node, versus 42 to 52 s per node with on-the-fly conversion, and the per-node
footprint drops from about 4.5 GB to tens of megabytes of cached blocks. Conversion costs
about 40 s per image once, in Cloud Build.

**Whole-set sweep (2026-09-23) [V-probe].** After conversion, every one of the 500 SWE-bench
Verified images was created once (2 CPU / 4 GB), given one command, and killed, 8 at a time
across 4 nested-virtualization nodes: **500 of 500 passed**; create to running p50 3.6 s,
p90 4.0 s, max 9.0 s; first command p50 1.1 s; the whole set took about 8 minutes. This is
the density-and-latency claim tested against the real task-image catalog rather than a
sample.

**Burst concurrency (2026-09-23) [V-probe].** 1, 10 and 100 sandboxes started at the same
instant from distinct converted images, 2 CPU / 2 GB each, across the 4 nested-virt nodes:
1 and 10 behave the same (about 2.6 s to running, 3.2 s to first command); 100 serializes on
per-node CPU at 25 per node (median 8 to 9 s to running, max 10.9 s, first command done for
all within 11.6 s). 1 to 3 of 100 creates fail with a refused connection on the Firecracker
API socket during a burst; the runtime has no retry there (gap 34). Details in the prototype
repository's `docs/concurrency-report.md`.

**Still unverified after the prototype:** bare-metal nodes, a shared snapshot repository on
Cloud Storage or Filestore (and the conditional-write gap 28), templates and snapshot
resume across nodes, HMAC auth, autoscaler behavior, live migration with running microVMs,
gateway timeouts for long streams, registry authentication over a multi-hour run.

## 10. Sources

AgentENV (commit `2f48c9c`): `src/api/openapi.yml`, `src/api/proxy.rs`, `src/api/impls/auth.rs`,
`src/sandbox/access.rs`, `src/orchestrator/service.rs`, `services/shared/config/config.go`,
`services/scheduler/internal/filter.go`, `deploy/k8s/base/`, `config/default.toml`,
`scripts/docker-setup.sh`, `docs/src/integration/e2b.md`, `docs/src/internals/architecture.md`,
`docs/src/internals/networking.md`.

agent-sandbox: `clients/python/agentic-sandbox-client/k8s_agent_sandbox/{sandbox_client.py,sandbox.py,connector.py,async_connector.py,commands/,files/,models.py,gke_extensions/snapshots/}`,
`examples/agent-sandbox-rl/agent_sandbox_rl/{fleet.py,cluster.py,handles.py,resources.py,recycle.py,reaper.py}`,
`clients/go/sandbox/types.go`.

Google Cloud documentation:
- [Nested virtualization on GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization)
- [Nested virtualization overview](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview)
- [Machine series comparison](https://docs.cloud.google.com/compute/docs/machine-resource)
- [GKE release notes (C3 bare metal GA)](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes)
- [Bare metal instances](https://docs.cloud.google.com/compute/docs/instances/bare-metal-instances)
- [Storage-optimized machine family (Z3)](https://docs.cloud.google.com/compute/docs/storage-optimized-machines)
- [About machine support with GKE clusters](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/machine-support)
- [GKE release notes, new features (C3 and C4A bare metal)](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-new-features)
- [C4 on Intel Granite Rapids GA (blog)](https://cloud.google.com/blog/products/compute/c4-vms-based-on-intel-6th-gen-xeon-granite-rapids-now-ga)
- [Local SSD raw block on GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/local-ssd-raw)
- [Local SSD concepts](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/local-ssd)
- [Artifact Registry quotas](https://docs.cloud.google.com/artifact-registry/quotas)
- [Cloud Storage interoperability](https://docs.cloud.google.com/storage/docs/interoperability)
- [XML API multipart uploads](https://docs.cloud.google.com/storage/docs/multipart-uploads)
- [HMAC keys](https://docs.cloud.google.com/storage/docs/authentication/hmackeys)
- [Memorystore for Redis networking](https://docs.cloud.google.com/memorystore/docs/redis/networking)
- [Deploying Gateways](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways)
- [GatewayClass capabilities](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/gatewayclass-capabilities)
- [Securing a Gateway](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/secure-gateway)
- [Node pool upgrade strategies](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-pool-upgrade-strategies)
- [Node auto-repair](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-auto-repair)
- [Maintenance windows and exclusions](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/maintenance-windows-and-exclusions)
- [Resizing a cluster](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/resizing-a-cluster)
- [Cluster autoscaler](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler)
- [Capacity buffer](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/capacity-buffer)
- [Flexible pod CIDR](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/flexible-pod-cidr)
- [CNCF distribution GCS driver](https://distribution.github.io/distribution/storage-drivers/gcs/)
