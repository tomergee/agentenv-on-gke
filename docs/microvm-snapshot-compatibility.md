# MicroVMs and snapshots on GKE: hardware and storage

I ran microVM sandbox orchestration for large RL datasets (SWE-Eval: 500 SWE-bench Verified
images) on GKE using AgentENV, Substrate and Agent Sandbox. This page covers the node and
storage requirements that fell out of it.

> **TL;DR**
>
> **What microVM RL needs:** every rollout runs in its own Firecracker VM, which is paused, resumed and forked from snapshots. So each node needs **KVM** (nested virtualization or bare metal), **the same CPU model across the pool** (a snapshot only restores on the same CPU), and **fast local NVMe** (about 1 TB per node for image caches, paused VMs and template memory). On top of that, a shared GCS or Filestore repository holds templates, and images are pre-converted to overlaybd in a same-region Artifact Registry.
>
> **Very few GCP families qualify:** of about 37 machine series, only **5 have KVM, GKE support and local SSD**: **C4 `-lssd` (recommended), C3 `-lssd`, Z3**, and the older N2 and C2. E2, every AMD series except N4D, and all Arm VMs have no KVM. The bare-metal shapes with the best storage (C4 and Z3 metal) aren't supported on GKE. The only GKE bare metal on x86, C3 metal, has no local SSD.

## Instance types

✅ = yes, ⚠️ = partly or with caveats, ❌ = no. "Good storage" means local NVMe SSD on the
shape.

| Instance type | CPU | KVM | GKE | Good storage | Verdict |
|---|---|---|---|---|---|
| `c4-*-lssd` VMs | Intel Granite / Emerald Rapids | ✅ nested | ✅ | ✅ up to 18 TiB | **Recommended** |
| `c3-*-lssd` VMs | Intel Sapphire Rapids | ✅ nested | ✅ | ✅ up to 12 TiB | Good |
| `z3-highmem-*-lssd` VMs | Intel Sapphire Rapids | ✅ nested | ✅ | ✅ up to 36 TiB | Good; SSD may be unavailable during maintenance |
| `n2-*` VMs | Intel Cascade / Ice Lake | ✅ nested | ✅ | ✅ up to 9 TiB | OK; older CPUs, pin the CPU platform |
| `c2-*` VMs | Intel Cascade Lake | ✅ nested | ✅ | ⚠️ up to 3 TiB | OK; **our prototype** (`c2-standard-8`) |
| `c3-*-192-metal` | Intel Sapphire Rapids | ✅ native | ✅ GA | ❌ Hyperdisk only | OK; no nested overhead, but benchmark the disk |
| `c4-*` VMs (no `-lssd`) | Intel Granite / Emerald Rapids | ✅ nested | ✅ | ❌ Hyperdisk only | OK; **our `kvm-pool-c4`** |
| `n4-*`, `c4n-*`, `h3-*` VMs | Intel | ✅ nested | ✅ | ❌ no local SSD on GKE | OK for low paused density |
| `n4d-*` VMs | AMD Turin | ✅ nested (only AMD) | ✅ | ❌ | OK; separate pool from Intel |
| `m4-*` VMs | Intel Emerald Rapids | ⚠️ docs conflict | ✅ | ❌ | Test first |
| `c4-*-288-lssd-metal` | Intel Granite Rapids | ✅ native | ❌ | ✅ 18 TiB | Not on GKE |
| `z3-*-highlssd-metal` | Intel Sapphire Rapids | ✅ native | ❌ | ✅ 72 TiB | Not on GKE |
| `c4a-*-metal` | Google Axion (Arm) | ✅ native | ✅ GA | ❌ | Arm unverified in AgentENV |
| `c4d-*-metal`, `z4d-*-metal`, `x4-*` | AMD / Intel | ✅ native | ❌ | ❌ mostly none | Not on GKE |
| E2, N2D, C2D, C3D, C4D, T2D, H4D, Z4D, G4 VMs | Intel (E2) / AMD | ❌ | ✅ | varies | Incompatible |
| C4A, N4A, T2A VMs | Arm | ❌ | ✅ | varies | Incompatible |
| M1, M2, M3, X5, A3, A4, A4X | Intel / Arm | ❌ | varies | varies | Incompatible |

Full per-family details and sources: [gcp-instance-compatibility.md](gcp-instance-compatibility.md).

## Why

| Requirement | Reason |
|---|---|
| KVM | Each sandbox is a Firecracker VM. GCE exposes KVM only through nested virtualization (Intel, plus AMD N4D) or bare metal. |
| One CPU model per pool | Snapshots carry CPU state, so they only restore on the same CPU and virtualization mode. |
| `ublk_drv` + io_uring | Lazy image boot via overlaybd. COS on GKE 1.35 has both, so Ubuntu isn't needed. |
| Fast local disk | Paused VMs, template memory files and image caches are node-local. Resume speed depends on this disk. |

## Storage

| Data | Where |
|---|---|
| Caches, writable layers, paused VMs | Local NVMe (raw block) at `/var/lib/aenv`. Lost with the node. |
| Templates and committed snapshots | Shared GCS or Filestore, in the same region |
| Images | Artifact Registry, pre-converted to overlaybd |

## What we measured

- Pre-converted images start in **4.6–5.0 s** on any node. Unconverted images take ~52 s per node.
- A template start uses ~50 MB per guest because guests share the template's memory file.
- About **10 concurrent boots per 8 vCPUs** saturates a node.
- GCS ignores S3 conditional writes, so AgentENV's catalog becomes last-writer-wins. Use a single writer or Filestore.
- 100 GB boot disks work for a prototype but not in production.
