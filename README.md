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
- `docs/testing-guide.md` — what the smoke test and the whole-set sweep check, how to run
  them, how to read the timings, and the results recorded so far.

Prototype target: cluster `barkland-test` (project `gke-ai-eco-dev`, `us-central1-a`),
node pool `kvm-pool-c2` (nested virtualization, COS, kernel 6.12).

## Run it

```bash
scripts/build-images.sh      # once: gateway + scheduler via Cloud Build into Artifact Registry
scripts/deploy.sh            # creates the Secrets, applies deploy/overlays/barkland-test, waits
KEY=$(scripts/get-api-key.sh)
scripts/port-forward.sh &    # gateway on http://127.0.0.1:8080 (no TLS or ingress by design)
curl -s -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $KEY" http://127.0.0.1:8080/health   # 204
tests/smoke.sh               # AC-1..AC-10 against the live system (see tests/README.md)
scripts/teardown.sh          # kills sandboxes, removes the namespace (node state stays)
scripts/clear-node-state.sh  # optional: wipe /var/lib/aenv and unload ublk_drv on the node
```

- Accepted limitations and the acceptance criteria: `plans/execution-plan.md`,
  `plans/acceptance-criteria.md`; the test procedure: `plans/test-plan.md`; results:
  `tests/RESULTS.md`; review: `review/findings.md`; deviations: `plans/decisions.md`.
- `kubectl kustomize deploy/overlays/barkland-test` renders without secrets; the two
  Secrets are created by `scripts/deploy.sh` from the gitignored `.secrets/` directory.
