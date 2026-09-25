# Artifact Registry and overlaybd: the gap, who owns it, and the patches

Written 2026-09-25 from the AgentENV-on-GKE prototype (`barkland-test`, AgentENV v0.2.2, 500
SWE-bench Verified images converted to overlaybd in Artifact Registry). It records what breaks
when a block-level lazy-loading runtime (AgentENV's Firecracker sandboxes over overlaybd) pulls
from Artifact Registry, which product each piece belongs to, and the exact change that closes it.
Everything marked *verified* was reproduced with `curl` against the repository
`us-central1-docker.pkg.dev/gke-ai-eco-dev/agentenv-images/swebench-verified` on 2026-09-25.

## Summary

| # | Gap | Owner | Fix needed | Status today |
|---|---|---|---|---|
| 1 | AR answers blob GETs with a **relative** `Location`; AgentENV's lazy loader stores it verbatim and every block read fails | AgentENV (upstream `kvcache-ai/AgentENV`, `registryfs_v2.rs`) | 7-line patch: resolve `Location` against the request URL | Patched in our runtime image; not upstreamed |
| 2 | AR accepts only **short-lived OAuth tokens** as the registry password; AgentENV reads credentials once at startup | AgentENV (and the overlaybd `registryfs` it embeds) | Reload the Docker config on 401 or watch the file; until then a token-refresh sidecar | Sidecar in our DaemonSet; no upstream change |
| 3 | **No producer** of overlaybd images on GCP: nothing converts on push, nothing links the converted form to the original | Artifact Registry / GKE product gap (Azure ACR ships this as Artifact Streaming) | AR-side conversion on push, published as an OCI referrer; or a documented Cloud Build recipe | Our own Cloud Build pipeline, one copy per image, parallel tags |
| 4 | **No discovery**: the overlaybd snapshotter finds the block by annotation on whatever tag it is given; nothing maps original to converted | overlaybd project (`containerd/accelerated-container-image`) plus the registry | Referrer-based discovery in the snapshotter (`subject` set by `convertor --referrer`), which AR's referrers API can now serve | Not implemented anywhere; ACR does it on the AKS node |
| 5 | **Block bytes flow through AR's own front end**, so every lazy read counts against the registry request quota | Artifact Registry | Redirect to a storage endpoint (as ECR and ACR do) or a documented quota path for block-level clients; peer cache (Dragonfly) in front | Open; regional repo and small caches keep us under quota at prototype scale |
| 6 | `GET /v2/.../referrers/` answers **401 before 200**; clients that probe unauthenticated conclude the API is missing | Client tooling (the SOCI project lists AR as unsupported for this reason) | Authenticate first; AR needs no change | Verified: 200 with an empty index when authenticated |
| 7 | **GKE Image Streaming does not apply**: it streams into containerd only, invisible to a microVM runtime | GKE | Block-level streaming, or a supported Dragonfly deployment, for non-containerd consumers | Open |
| 8 | The overlaybd **convertor has no retry** on a transient AR token-endpoint error | overlaybd project (`convertor`) | Retry the auth call | One shard re-run by hand |

Gaps 1 and 2 are bugs in the consumer; AR is within the HTTP and registry specifications on both.
Gaps 3, 5 and 7 are product gaps on the Google side. Gaps 4 and 8 are upstream overlaybd work.

## What Artifact Registry actually returns (verified)

The converted image is an ordinary manifest whose layer descriptor carries the block reference
as annotations. This is all the overlaybd snapshotter needs:

```
mediaType: application/vnd.docker.image.rootfs.diff.tar
digest:    sha256:e7cc6a99...dfed49   size: 48209408
annotations:
  containerd.io/snapshot/overlaybd/blob-digest: sha256:e7cc6a99...dfed49
  containerd.io/snapshot/overlaybd/blob-size:   48209408
  containerd.io/snapshot/overlaybd/version:     0.1.0
```

A blob GET with a bearer token:

```
GET /v2/<repo>/blobs/sha256:e7cc...   ->   HTTP/2 302
location: /artifacts-downloads/namespaces/gke-ai-eco-dev/repositories/agentenv-images/downloads/h1T2gB-TxizgNGcV
```

Following the redirect with a `Range` header and **no** `Authorization`:

```
HTTP/2 206
accept-ranges: bytes
content-range: bytes 0-1048575/48209408
content-type: application/octet-stream
cache-control: private, max-age=0
server: UploadServer
```

The download URL is reusable for further ranges. The bytes are served by AR itself, not by a
Cloud Storage URL. ECR (307 to a presigned S3 URL, valid one hour) and ACR (307 to Azure
Storage or a dedicated data endpoint, valid 20 to 30 minutes) both hand the client an absolute
storage URL instead; that difference is gap 5.

The referrers API (OCI Distribution 1.1), authenticated:

```
GET /v2/<repo>/referrers/sha256:d469...   ->   HTTP/2 200
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":null}
```

Unauthenticated the same request answers 401, which is gap 6.

## Gap 1: the relative redirect

**Symptom.** Lazy loading of any image fails; the runtime logs an invalid URL for the block
download and falls back to nothing (the sandbox never becomes ready).

**Cause.** `storage/overlaybd/src/backend/registryfs_v2.rs` takes the `Location` header of the
302 and stores it as the block URL. RFC 7231 allows a relative reference; AR sends one.

**Patch** (`build/runtime/0001-registryfs-resolve-relative-redirect-location.patch`), applied to
tag `v0.2.2` and shipped as `aenv-server:v0.2.2-ar-redirect1`:

```rust
let location = match Url::parse(url).and_then(|base| base.join(location)) {
    Ok(absolute) => absolute.to_string(),
    Err(_) => location.to_string(),
};
```

`join` returns an absolute location unchanged, so the patch is safe for every other registry.
It belongs upstream in `kvcache-ai/AgentENV` (and, if the same code exists there, in the
overlaybd registryfs it derives from). AR could also emit an absolute `Location`; that is a
courtesy, not a requirement.

## Gap 2: credential lifetime

**Symptom.** Lazy loading works for about an hour after the runtime starts, then every block
read is a 401. Also: if the credential file does not exist when the runtime starts, lazy loading
never works at all.

**Cause.** AR has no long-lived registry password short of a service-account key. The supported
password is an OAuth access token (`oauth2accesstoken:<token>`), valid one hour. AgentENV's
lazy loader reads `$HOME/.docker/config.json` once at startup; `regctl`, which it uses for
manifests and copies, reads the file on every call.

**Workaround we run** (`deploy/overlays/barkland-test/daemonset-patch.yaml`): a native sidecar
in the runtime pod fetches the node's Workload Identity token from the metadata server every
15 minutes, writes a Docker config for `us-docker.pkg.dev` and `us-central1-docker.pkg.dev`
into a memory `emptyDir` mounted at `/root/.docker`, and a startup probe holds the runtime until
the first file exists. IAM: `roles/artifactregistry.reader` for the pod's Workload Identity
principal on each repository.

**Patch needed upstream.** In the lazy loader: re-read the credential file (or call a credential
helper) when a request answers 401, and read it lazily rather than at startup. With that, the
sidecar becomes unnecessary and the standard GKE pattern (Workload Identity plus the
`docker-credential-gcr` helper) works as it does for containerd.

## Gap 3: nobody produces overlaybd images on GCP

On Azure, `az acr artifact-streaming update --enable-streaming true` makes the registry convert
every pushed image to overlaybd and attach it to the original as an OCI referrer
(`application/vnd.azure.artifact.streaming.v1`); AKS nodes discover and mount it. On GCP the
equivalent does not exist, so we built it: `build/convert/` runs upstream's userspace
`convertor` in Cloud Build, sharded, about 40 s and one extra copy per image (500 images, roughly
600 GB of additional storage), into a regional repository. Conversion needs the source in the
same repository, so each image is copied to a staging tag first and the staging manifest deleted
after.

**What would close it.** Conversion as an Artifact Registry feature (on push, opt-in per
repository, output linked by `subject`), or at minimum a supported Cloud Build recipe and a
documented storage and quota model. Until then the pipeline in this repository is the recipe.

## Gap 4: no discovery of the converted image

The upstream snapshotter identifies an overlaybd image only by the annotations on the manifest
it is asked to pull; it has no notion of "the accelerated form of image X". The convertor can
push the converted manifest with a `subject` pointing at the original (`--referrer`, artifact
type `application/vnd.containerd.overlaybd.native.v1+json`), and AR's referrers API can serve
that link, but nothing on the consumer side asks for it. Azure closed this in the AKS node
agent. The fix is a referrer lookup in the snapshotter (or in AgentENV's image resolver), the
same mechanism the SOCI snapshotter uses on ECR.

## Gap 5: request quota on block reads

Because AR serves blob bytes from its own front end, a fleet of lazily loading sandboxes turns
every block read into a registry request. Our prototype kept 15 GB caches per node and one
regional repository and never hit the limit, but the proposal's gap 33 stands: at rollout scale
the per-region request quota, not bandwidth, is the ceiling. Options, none requiring an AR change:
a peer cache in front of AR (Dragonfly is protocol-compatible with overlaybd's accelerate-URL
hook), larger node caches, or a quota increase sized from measured block-read rates. The AR-side
fix would be to redirect to a storage endpoint the way ECR and ACR do.

## Gaps 7 and 8, briefly

GKE Image Streaming (Riptide) accelerates pulls made by the node's containerd; a microVM runtime
that maps images as block devices never goes through containerd, so the feature is simply not
in the path. Either block-level streaming for non-containerd consumers, or a supported
Dragonfly deployment, would be the GKE-side answer. The overlaybd convertor failed one image
out of 500 on a transient 502 from AR's token endpoint and does not retry; a retry around the
auth call is a small upstream fix.

## Recommended actions

1. Upstream gap 1 (the redirect patch) and gap 2 (lazy credential reload) to `kvcache-ai/AgentENV`;
   both are small and registry-neutral.
2. File gap 3 and gap 5 with the Artifact Registry team as one feature request: overlaybd
   conversion on push with referrer linking, and storage-endpoint redirects for block-level
   clients. Cite ACR Artifact Streaming as the reference behavior.
3. File gap 7 with GKE: streaming for microVM runtimes, or a supported peer cache.
4. Propose referrer-based discovery (gap 4) and the convertor retry (gap 8) upstream in
   `containerd/accelerated-container-image`.
