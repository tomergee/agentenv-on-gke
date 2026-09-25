# MicroVMs and snapshots on GKE: compatible instance types and storage

One-page summary for running Firecracker microVM sandboxes (AgentENV) with pause/resume, fork
and template snapshots on GKE. Details and sources are in
[the proposal, sections 4.2, 4.3 and 4.7](../plans/agentenv-gke-standalone-and-sdk-backend-proposal.md).
Tags: **[measured]** on barkland-test, **[docs]** Google or upstream documentation,
**[unverified]** not yet checked.

## The four hard requirements, and why

| Requirement | Why it exists | What it rules out |
|---|---|---|
| **1. KVM on the node** (`/dev/kvm`) | Each sandbox is a Firecracker VM with its own kernel. Firecracker needs hardware virtualization. A normal GCE VM only exposes KVM through **nested virtualization**. Bare-metal types expose it natively. | E2, all AMD VMs (N2D, C3D, C4D), and Arm VMs: GCE doesn't offer nested virtualization on them **[docs]**. |
| **2. Same CPU model and virtualization mode within a pool** | A snapshot captures guest CPU state (CPUID, registers, feature flags). It can only be restored on a host that exposes the same CPU features. AgentENV uses a CPU template that intersects features across the cluster. Mixing CPUs shrinks that template, or restores fail. | Mixing C4 with C3, bare metal with nested, or Intel generations in one pool. Paused sandboxes restore only in the same mode **[code]**. |
| **3. Kernel with `ublk_drv` and io_uring enabled** | Image layers are overlaybd block devices exposed through ublk, a userspace block driver built on io_uring. That's how a VM boots from an image that's still downloading (lazy loading). | Node images without the module, or with `io_uring_disabled`. COS on GKE 1.35 (kernel 6.12.94) passes **[measured]**. |
| **4. Fast node-local disk** | Converted image layers, the remote block cache, running VMs' writable layers, **paused VMs' memory and disk deltas**, and **template memory files** (restored by memory-mapping) all live on the node. Resume and template-start speed depends on random-read latency on this disk. | Small or slow boot disks. These work for a prototype but cap image count and paused density. |

**Node OS:** COS works. AgentENV runs Firecracker from a privileged DaemonSet and downloads its
binaries to `/var/lib/aenv`, so it installs nothing on the host filesystem. Kata is different:
`kata-deploy` writes to the host, so it needs **Ubuntu** nodes (see
`agent-sandbox/examples/kata-gke-sandbox`).

## Instance types

| Instance type | KVM | Local SSD | On GKE | Verdict |
|---|---|---|---|---|
| `c4-*-lssd` VMs | Nested | Up to 18 TiB | Yes | **Recommended.** |
| `c3-*-192-metal` | Native | **None** (Hyperdisk only) | GA | Supported. Cache and paused state go on Hyperdisk, so benchmark it first. |
| `c4-standard/highmem-288-lssd-metal` | Native | 18 TiB | **No** (GKE exception list) | Compute Engine only. Not usable as a GKE node. |
| `c3-*-lssd` VMs | Nested | Up to 12 TiB | Yes | Nested option. |
| `z3-highmem-*-lssd` VMs | Nested | Up to ~35 TiB | Yes | Most disk and high memory per vCPU. Local SSD may be unavailable during maintenance, which puts paused VMs at risk. |
| `n2-*`, `c2-*` VMs | Nested | Up to 9 / 3 TiB | Yes | Older CPUs. **c2 is what we prototyped on.** |
| `c4-standard-8` (no `-lssd`) | Nested | None | Yes | **Running now** (`kvm-pool-c4`, 300 GB Hyperdisk Balanced). C4 supports Hyperdisk only, no PD. |
| C4A bare metal | Native | None | GA | Conditional: Arm, and AgentENV's Arm build is unverified. |
| C4D / Z3 / Z4D bare metal, X4 | Native | | **No** (GKE exception list) | Incompatible on GKE. |
| E2 and AMD VMs (except N4D), Arm VMs | None | | | **Incompatible.** Full list in [gcp-instance-compatibility.md](gcp-instance-compatibility.md). |

Nested virtualization costs 10% or more CPU, and more for I/O **[docs]**. It also doesn't
work with node auto-provisioning, so create node pools explicitly with
`--enable-nested-virtualization`. Bare metal has no live migration (host maintenance must be
TERMINATE).

## Storage: what's needed and where

| Data | Needs | Recommended |
|---|---|---|
| Image cache, block cache, snapshot cache (~210 GB at defaults) | Node-local and fast. Rebuildable. | Local NVMe in raw block mode (`--local-nvme-ssd-block`), assembled at `/var/lib/aenv` by the DaemonSet |
| Running VMs' writable layers | Node-local. Lost with the node. | Same disk |
| **Paused sandboxes** (memory and disk deltas) | Node-local. Survive a runtime restart, **lost on node replacement**. Resume must run on the same node. | Same disk. Size it for paused density: 1,000 paused at ~0.3 GB is ~0.3 TB. |
| **Templates and committed snapshots** (fork and fan-out source) | **Shared and durable.** Every node that starts from a template needs it. | GCS bucket in the same region, or Filestore (`posix_fs`) |
| Images | OCI registry, **pre-converted to overlaybd** so starts load lazily | Artifact Registry in the same region |

**Sizing:** about 1 TB of local disk per node covers the caches plus ~200 running and ~1,000
paused sandboxes. Without local SSD, use a large Hyperdisk Balanced or Extreme volume.

## Gotchas we hit on barkland-test

- **GCS silently ignores S3 conditional PUTs** (`If-None-Match`, `If-Match`) **[measured]**.
  AgentENV's snapshot catalog relies on them. With concurrent writers on GCS the last writer
  wins silently. Use a single writer or Filestore until this is fixed.
- **The snapshot store is node-local with `posix_fs` on a local path.** A template start on a
  node that doesn't hold the template fails with "template not found". We worked around it by
  creating the template on every node. Production needs the shared repository.
- **Unconverted images:** without pre-conversion, every node converts every image on first use.
  A 1.3 GB SWE image took ~52 s per node. After conversion, starts took 4.6–5.0 s on any node,
  adding only 16–85 MB of cache per image per node **[measured]**.
- **100 GB boot disks** (c2 prototype): caches had to shrink to 15/15/5 GB. That holds only a
  handful of fully pulled SWE images. Lazy overlaybd makes it workable, but it's not a
  production size.
- **Template starts share memory:** a VM restored from a template maps the template's memory
  file, so 25 guests used ~50 MB each (vs ~140 MB for cold idle) **[measured]**. This is why
  the snapshot cache belongs on fast local disk.
- **CPU saturates during boot bursts:** about 10 concurrent starts per 8 vCPUs is the limit.
  Pick larger shapes for burst-heavy RL rollouts.

## For comparison: GKE Pod Snapshots (gVisor, not microVMs)

GKE Pod Snapshots checkpoint a **gVisor** pod. They don't need KVM, nested virtualization or
local SSD. They need a gVisor node pool, Pod Snapshots enabled on the cluster, and a **GCS
bucket** (`PodSnapshotStorageConfig`) in the same region. Snapshots are durable and restore on
any compatible node. Whole-pod snapshots don't support the E2 pool on barkland-test. For
measured gVisor snapshot restore times next to AgentENV, see the snapshot rows added in commit
`8afe790`.
