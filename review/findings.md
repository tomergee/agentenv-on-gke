# Review: AgentENV prototype on barkland-test (`prototype` @ d3a81f6)

**Verdict: approve-with-fixes** for the prototype's stated goal (running and testable on
one nested-virtualization node, accepted limitations from `plans/execution-plan.md`).
Not a production review. One High finding affects the teardown acceptance criteria and
should be fixed before the tester runs AC-11/AC-12; the Medium items are small.

Reviewed read-only on 2026-09-23: the branch diff `e38dd57..d3a81f6`, `kubectl kustomize`
render (with throwaway secrets), `kubectl diff -k` against the live namespace, live pod
specs and logs, the runtime image contents, and the gateway's auth behaviour through a
temporary port-forward. No cluster objects were created or changed.

Counts: Blocker 0 · High 1 · Medium 6 · Low 7 · Nit 4.

## High

**H1. `scripts/teardown.sh` fails or stalls while sandboxes drain** — `scripts/teardown.sh:6`,
`deploy/base/agentenv-daemonset.yaml` (preStop + `terminationGracePeriodSeconds: 3600`).
The runtime pod's preStop hook loops until the node reports zero running sandboxes. A
namespace delete therefore waits for every running sandbox to expire (tests create them
with `timeout: 900`, and auto-pause only happens at expiry). `teardown.sh` runs
`kubectl delete namespace --wait --timeout=600s` under `set -e`, so with one running
sandbox it exits non-zero after 10 minutes while the namespace is still Terminating, and
AC-12's "namespace gone" check fails although deletion is still in flight. Fix: before the
delete, kill all sandboxes through the gateway (port-forward, `GET /v2/sandboxes`, `DELETE
/sandboxes/{id}` for each), then delete the namespace; or lower the DaemonSet's
`terminationGracePeriodSeconds` in the overlay for the prototype (for example 120 s) and
say so in `plans/decisions.md`. Keep the 600 s wait only after the kill step.

## Medium

**M1. The overlay does not render on a clean checkout** — `deploy/overlays/barkland-test/kustomization.yaml:33-41`.
`kubectl kustomize deploy/overlays/barkland-test` fails with "env source files:
[.secrets/agentenv-auth.env] ... no such file" until `scripts/deploy.sh` has generated the
secrets. Reviewers and CI cannot render without side effects, and `kubectl diff` needs the
same workaround. Fix: create the two Secrets outside kustomize in `deploy.sh`
(`kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -`) and drop
the `secretGenerator` entries (the base's empty `agentenv-auth` literal must then be
patched away or left to be overwritten), or add `scripts/render.sh` that writes placeholder
files into a temp copy. Document the chosen approach in the README.

**M2. Gateway and scheduler run on the runtime node** — live: all three pods are on
`gke-barkland-test-kvm-pool-c2-6b3ad0c5-axvc`. Nothing pins the two Deployments elsewhere,
so they share the 8 vCPUs with Firecracker VMs and skew any latency numbers the tester
records. Section 4.2 of the proposal wants the runtime pool dedicated. Fix: in the overlay,
patch both Deployments with `nodeSelector: {cloud.google.com/gke-nodepool: default-pool}`
(or node anti-affinity on `kvm=true`). Low effort, no upstream change.

**M3. Images pinned by mutable tags** — `deploy/overlays/barkland-test/kustomization.yaml:12-21`.
`ghcr.io/kvcache-ai/aenv-server:v0.2.2-amd64` and the two Artifact Registry `v0.2.2` tags
can be re-pushed. Fix: add `digest:` entries (gateway
`sha256:452e3e4a0667f9d40c50bbf7d7a5b828fcb8245eb817f914da837dfc28e039ed`, scheduler
`sha256:7d336fbfdc29e18b598f057f53bc9790edb034266105d750b77de84bfeff2464`; resolve the
aenv-server digest with `gcloud artifacts docker images describe` after mirroring, or
`crane digest`). Record the digests in `plans/decisions.md`.

**M4. Leftover node state is not documented where AC-12 looks for it** — `plans/decisions.md`,
`scripts/teardown.sh:2-3`. AC-12 requires the leftover node state and the command to clear
it in `plans/decisions.md`; today only a comment in `teardown.sh` mentions `/var/lib/aenv`.
Actual leftovers on the node after teardown: hostPath `/var/lib/aenv/env` (runtime deps,
about 421 MB now, plus image cache, snapshot store, persisted paused sandboxes and, when the
seed Secret is absent, the generated access-token seed), the loaded `ublk_drv` module with
`ublks_max=4096`, and the sysctls until the node reboots. Fix: add a decisions entry listing
these with the clearing command (a one-shot privileged pod pinned to the node running
`rm -rf /var/lib/aenv`, or "recreate the node"), and mark them "left in place by design".

**M5. `home_path` in the overlay config is dead and its comment is wrong** —
`deploy/overlays/barkland-test/config/agentenv.toml:10`. The runtime image sets
`AENV_HOME_PATH=/workspace/env`, which overrides `home_path` (`src/cfg.rs:80`), so the
effective state directory is `/workspace/env`, the hostPath `/var/lib/aenv/env` on the
node; `/var/lib/aenv` does not exist inside the container. The comment claims
`home_path` is the hostPath-backed disk. If the env var were ever dropped from the image,
state would land on the container's ephemeral layer. Fix: set `home_path = "/workspace/env"`
explicitly and correct the comment, so config and environment agree.

**M6. The test plan sends the tester to `kubectl debug node/...`** — `plans/test-plan.md:214`
(and the disk-inspection hint). `kubectl debug node/` creates a privileged pod in the
caller's current namespace (`default`), outside the "only `agentenv-system`" rule and
AC-13's spirit unless deleted. Fix: inspect disk with
`kubectl -n agentenv-system exec <node-pod> -c agentenv -- df -h /workspace` and
`du -sh /workspace/env/*` instead; drop the debug-pod mention.

## Low

**L1. `hostPID: true` is pod-wide** — `deploy/overlays/barkland-test/daemonset-patch.yaml:14`.
Only the init container needs it, but the setting also gives the runtime container host PID
visibility (upstream does not set it). Marginal next to `privileged`, but it widens the
blast radius. Alternative: run host prep as a separate one-shot privileged Job or a tiny
DaemonSet, or accept it and record it in `plans/decisions.md`.

**L2. README has no quickstart** — `README.md`. Nothing tells a newcomer to run
`scripts/build-images.sh`, `scripts/deploy.sh`, `scripts/port-forward.sh`,
`scripts/get-api-key.sh`, where the accepted limitations are, or that `plans/test-plan.md`
is the test procedure. Fix: a "Run it" section with those five lines and links.

**L3. `scripts/build-images.sh` needs a pre-existing upstream checkout** — `scripts/build-images.sh:9-11`.
On a clean machine the first run fails (clearly) unless `/tmp/AgentENV-v0.2.2` exists. Fix:
when `AGENTENV_SRC` is unset, `git clone --depth 1 --branch "$TAG"` into the temp context.

**L4. No NetworkPolicy; metrics unauthenticated** — live: node `:8000/metrics` and ublk
`:9103/metrics` return 200 without a key (`/nodes`, `/sandboxes` return 401; `/health` is
open by design). All Services are ClusterIP and this is an accepted limitation. A
namespace-scoped NetworkPolicy allowing only gateway→nodes:8000 and the metrics collectors
would be a cheap hardening if the prototype outlives the test.

**L5. Identity fields left at upstream defaults** — live `GET /nodes`: `clusterID`
all zeros, `serviceInstanceID: service-instance-a`, `commit: unknown`. Cosmetic; set
`[cluster]` and the observability identity in `agentenv.toml` for anything beyond a
prototype.

**L6. Snapshot local cache not reduced** — `deploy/overlays/barkland-test/config/agentenv.toml`.
Only the image cache and remote blocks were lowered to 15 GB; the snapshot artifact cache
keeps the upstream 10 GB default. Worst case 40 GB of caches on a 95 GB disk with 11 GB
used: fine for the prototype, worth a line in `decisions.md`.

**L7. Init container fallbacks are silent** — `daemonset-patch.yaml:32-37`. If
`modprobe -r ublk_drv` succeeds but the reload with `ublks_max=4096` fails, the script
reloads with the default limit and only logs a warning, so a node could silently run with
64 devices. Acceptable for one node; consider failing the init container instead, since the
limit caps sandboxes per node.

## Nit

- **N1.** `deploy/base/config/agentenv.toml` is a byte-identical copy of upstream
  `config/default.toml` that the overlay immediately replaces; add a comment in
  `deploy/base/kustomization.yaml` saying it exists only to satisfy the base generator.
- **N2.** `plans/decisions.md` mixes the developer's bullet entries with the orchestrator's
  heading entries; pick one format.
- **N3.** `scripts/deploy.sh:28` prints the port-forward hint with a literal `\$KEY`; fine,
  but a copy-pasteable two-liner (`KEY=$(scripts/get-api-key.sh)`) would be friendlier.
- **N4.** The overlay kustomization comment says "no TLS or ingress"; also say "single node,
  posix_fs snapshot repository" so the two biggest limitations are visible where the
  manifests live.

## Fine as-is (verified)

- Auth: `/nodes` and `/v2/sandboxes` return 401 without a key and with a wrong key, 200 with
  the real one; `/health` is unauthenticated by upstream design. Key length 64 hex chars.
- Secrets: `.secrets/` is gitignored, nothing secret-shaped is committed in any revision,
  `deploy.sh` prints paths not values, and the API key does not appear in any pod log.
- Deployed objects match the overlay: `kubectl diff -k` shows differences only in the two
  Secrets (expected with throwaway values); the live ConfigMap is byte-identical to the
  overlay file; images match the rendered ones.
- Init container: idempotent guard on `ublk_drv` (`ublks_max` and in-use device check),
  worked on the live node (64 → 4096), sysctls applied on the host; `/dev/kvm` check fails
  fast. busybox `nsenter` into host namespaces is the right tool given the runtime image
  lacks `modprobe`.
- preStop dependencies (`curl`, `jq`) exist in the runtime image; `iptables`, `nsenter`,
  `sysctl`, `uvm-ublk-daemon` present.
- No LoadBalancer/NodePort Services, RBAC is the upstream namespaced Role only, no
  ClusterRoles, no extra host mounts beyond upstream's `/dev` and `/var/lib/aenv`.
- Blast radius: no stray pods or namespaces from this work (the only recent pods outside
  system namespaces are GKE's pod-snapshot agents from an earlier, unrelated change); the
  Cloud Build source bucket pre-existed; the Artifact Registry repo is logged in
  `plans/decisions.md`.
- `build/cloudbuild.yaml`: `TARGETARCH`/`TARGETOS` passed, both images built and pushed,
  build `85deda9d…` succeeded.
- PM docs use only paths, headers and ports that exist in v0.2.2 (`/sandboxes-cold`,
  `/sandboxes/{id}/pause|resume|connect|fork`, `e2b-sandbox-id`/`e2b-sandbox-port`,
  `x-agentenv-sandbox-id`, envd port 49983, `X-API-Key`, `X-Access-Token`).

## Checklist for the tester

1. Run AC-12 with at least one running sandbox first to reproduce H1; then with none.
2. Use `kubectl exec` into the node pod for disk checks (M6), never `kubectl debug node`.
3. Record `df -h /workspace` and `du -sh /workspace/env/*` after the full sequence.
4. For AC-6, write the marker file under a path outside `/tmp` and confirm it after resume;
   also confirm the sandbox ID is unchanged.
5. For AC-7, confirm both children have distinct IDs and that killing one leaves the other
   and the parent running; note that all land on the single node.
6. Capture `GET /nodes` `sandboxCount` and `allocatedCPU` before and after the run; they
   must return to the starting values once everything is killed.
7. Confirm commands over envd need `X-Access-Token` (v2 sandboxes are always secure) and
   that a missing token is rejected.
8. Leave no port-forward running; `GET /v2/sandboxes` must be empty at the end.
9. Note timings knowing gateway and scheduler share the runtime node (M2).
