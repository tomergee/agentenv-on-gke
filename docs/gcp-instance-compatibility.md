# GCP machine families: which can run Firecracker microVMs with snapshots on GKE

Checked 2026-09-25 against the Compute Engine machine-series comparison table (nested
virtualization, local SSD and disk rows), the bare-metal instances page, and the GKE
machine-support exceptions list. Sources are at the bottom. Why each requirement exists is
covered in [microvm-snapshot-compatibility.md](microvm-snapshot-compatibility.md).

**A node is compatible if all of these hold:**
1. **KVM:** either nested virtualization is supported on the series, or it's a bare-metal
   shape that **GKE** supports.
2. **x86:** AgentENV's Arm support is unverified. Firecracker itself supports aarch64.
3. **GKE Standard, not Autopilot.** Also: `COS_CONTAINERD` on 1.28.4-gke.1083000 or later (or
   Ubuntu), no node auto-provisioning, privileged pods, and nested virtualization set when the
   pool is created.

Local SSD isn't a hard requirement, but it decides the tier: paused VMs, template memory files
and caches live on node disk.

## ✅ Compatible families

### Tier 1: KVM and local SSD on GKE (recommended)

| Series | CPU | KVM | Max local SSD | Notes |
|---|---|---|---|---|
| **C4** (`-lssd` VM shapes) | Intel Emerald / Granite Rapids | Nested | 18,000 GiB | **Best choice on GKE.** Newest Intel. Hyperdisk only, no PD. |
| **C3** (`-lssd` VM shapes) | Intel Sapphire Rapids | Nested | 12,000 GiB | Solid option. PD and Hyperdisk available. |
| **Z3** (VM shapes) | Intel Sapphire Rapids | Nested | 36,000 GiB | Most disk and high memory per vCPU. Local SSD may be unavailable during maintenance, which puts paused VMs at risk. |
| **N2** | Intel Cascade Lake / Ice Lake | Nested | 9,000 GiB | CPU generation varies by zone. Pin `min-cpu-platform` so snapshots stay portable. |
| **C2** | Intel Cascade Lake | Nested | 3,000 GiB | **Our prototype** (`c2-standard-8`). Max 60 vCPUs. |
| **N1** | Intel Skylake and older | Nested | 9,000 GiB | Legacy CPUs with mixed generations. Avoid for new pools. |

### Tier 2: KVM, but no local SSD on GKE (Hyperdisk or PD for `/var/lib/aenv`)

| Series | CPU | KVM | Why tier 2 |
|---|---|---|---|
| **C4** (non-`-lssd`) | Intel Emerald / Granite Rapids | Nested | No SSD on these shapes. This is our `kvm-pool-c4` (`c4-standard-8`, 300 GB Hyperdisk Balanced). |
| **C3 bare metal** (`c3-*-192-metal`) | Intel Sapphire Rapids | **Native** | GA on GKE. No nested overhead, but no local SSD (Hyperdisk only), 192 vCPU minimum and no live migration. |
| **C4N** | Intel Emerald Rapids | Nested | GKE doesn't support the `c4n-*-lssd` shapes. |
| **N4** | Intel Emerald Rapids | Nested | No local SSD on the series. |
| **N4D** | AMD EPYC Turin | Nested | **The only AMD series with nested virtualization.** No local SSD. Keep it in its own pool, because AMD snapshots don't restore on Intel. |
| **H3** | Intel Sapphire Rapids | Nested | HPC shape (88 vCPUs), no local SSD. |
| **M4, M4N** | Intel Emerald Rapids | Nested (table) | **Conflicting docs:** the comparison table says yes, but the nested-virtualization overview says memory-optimized VMs are unsupported. Test before relying on it. No local SSD. |

### Compatible but not relevant to sandbox fleets (GPU)

**A2, G2, N1+GPU**: nested virtualization is supported and local SSD is available, but GPUs are
wasted on CPU sandboxes.

### Conditional: Arm bare metal

**C4A bare metal** (`c4a-*-96-metal`, Google Axion): native KVM and GA on GKE. Firecracker
supports aarch64, but AgentENV's Arm build is unverified, and every image would need an arm64
variant. No local SSD on the metal shapes.

## ❌ Incompatible families

| Series | Reason |
|---|---|
| **E2** | No nested virtualization. This includes barkland-test's `default-pool` and `sandbox-pool`. |
| **N2D, C2D, C3D, C4D (VM), T2D, H4D, Z4D (VM), G4** | AMD without nested virtualization (only N4D has it). |
| **C4D bare metal, Z4D bare metal** | GKE doesn't support these `-metal` shapes. |
| **C4 bare metal** (`c4-*-288-metal`, `-lssd-metal`) | **GKE doesn't support them** (listed as exceptions). Native KVM on plain Compute Engine only. |
| **Z3 bare metal** (`z3-highmem-192-highlssd-metal`) | GKE doesn't support it. |
| **X4** | GKE doesn't support any X4 shape. No nested virtualization. |
| **X5** | Bare metal only, and no nested virtualization. GKE support isn't documented. |
| **M1, M2, M3** | No nested virtualization. |
| **C4A (VM), N4A, T2A** | Arm, no nested virtualization. |
| **A3, A4, A4X, A4X Max** | No nested virtualization. A4X / A4X Max are Arm. |

## Pool rules for snapshots

- **One series and CPU platform per pool.** Snapshots carry CPU state, so a VM paused on
  Granite Rapids may not resume on Emerald Rapids. For C4 (mixed generations) and N2, set
  `--min-cpu-platform` or keep separate pools.
- **Don't mix nested and bare-metal pools, or Intel and AMD pools**, for the same templates.
- **Enable nested virtualization when you create the pool.** You can't turn it on later.

## Sources

- [Machine families resource and comparison guide](https://docs.cloud.google.com/compute/docs/machine-resource) (nested virtualization, local SSD and disk rows per series)
- [Nested virtualization overview](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview) (E2, memory-optimized, Arm and AMD exclusions; the N4D exception)
- [Bare metal instances](https://docs.cloud.google.com/compute/docs/instances/bare-metal-instances)
- [GKE machine support: exceptions](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/machine-support) (C4, C4D, Z3 and Z4D `-metal`; X4; C4N `-lssd`; M4 hypermem)
- [GKE nested virtualization](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nested-virtualization) (image types, Standard only, no node auto-provisioning)
- [GKE release notes](https://docs.cloud.google.com/kubernetes-engine/docs/release-notes-new-features) (C3 and C4A bare metal GA)
