# MicroVMs and snapshots on GKE: hardware and storage

I ran microVM sandbox orchestration for large RL datasets (SWE-Eval: 500 SWE-bench Verified
images) on GKE using AgentENV, Substrate and Agent Sandbox. This page covers the node and
storage requirements that fell out of it.

> **TL;DR**
>
> **Hardware:** GKE Standard with Intel x86 nodes that have nested virtualization. Use C4 `-lssd` (C3 or Z3 `-lssd` also work, and C3 bare metal gives native KVM). Keep one CPU model per pool.
>
> **Storage:** about 1 TB of local NVMe per node for caches and paused VMs, a shared GCS or Filestore repository for templates, and images pre-converted to overlaybd in a same-region Artifact Registry.

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

The per-family list is in [gcp-instance-compatibility.md](gcp-instance-compatibility.md).
C4 bare metal is **not** supported on GKE.
