# AgentENV on GKE

Running [AgentENV](https://github.com/kvcache-ai/AgentENV) (Firecracker microVM agent
sandboxes) standalone on GKE Standard, and evaluating it against agent-sandbox for density
and start latency.

- `plans/agentenv-gke-standalone-and-sdk-backend-proposal.md` — the design proposal: gaps
  table first, then integration surface, node pools, networking, IAM, storage, metadata and
  RBAC, SDK backend, phased plan, benchmarks.
- `plans/gvisor-snapshot-clock-test.md` — side result: clocks jump forward (do not stop)
  across a GKE Pod Snapshot restore on gVisor.
- `plans/execution-plan.md` — how the prototype on the `barkland-test` cluster is built,
  tested and reviewed (multi-agent plan).

Prototype target: cluster `barkland-test` (project `gke-ai-eco-dev`, `us-central1-a`),
node pool `kvm-pool-c2` (nested virtualization, COS, kernel 6.12).
