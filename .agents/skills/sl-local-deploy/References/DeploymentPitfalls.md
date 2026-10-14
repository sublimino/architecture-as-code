# Common Local Deployment Pitfalls

This reference catalogues common failure modes encountered during local deployments.
Review these patterns when a deployment fails or rolls back unexpectedly.

The diagram shows the five common points of failure during local deployment.

```mermaid
flowchart LR
  A["Image Pin Trap"] --> B["Containerd Load Drop"]
  B --> C["Cosign Key Mismatch"]
  C --> D["SPDY Stream Severance"]
  D --> E["Nginx SPA Masking"]
```

## 1. The Kustomization Image Pin Trap

**Defect**:
A commit hardcodes an image tag in `d2-signalloom/apps/fe-signalloom/local/kustomization.yaml`.
Flux applies this patch on every reconciliation loop.
Any newly built image carrying `:latest` is ignored.
Flux immediately rolls the pod back to the hardcoded tag.

**Resolution**:
Always synchronize the image patch to match the new image source fingerprint.
Alternatively, configure the patch to reference `${IMAGE_BASE}` and `${ARTIFACT_TAG}`.

## 2. Docker Containerd Image Store Dropping `kind load`

**Defect**:
On Docker engines with containerd snapshotter enabled, `kind load docker-image` can exit zero without transferring image layers.
The pod enters `ImagePullBackOff` as it attempts to pull non-existent remote tags.

**Resolution**:
Use `scripts/kind-load-verified.sh` rather than raw `kind load`.
This script verifies that the unpacked image diffIDs appear in the CRI container runtime.

## 3. Cosign Signing Key Trust Divergence

**Defect**:
The `.keys/` directory is gitignored and unique to each local clone.
If a cluster is created from one worktree and code is pushed from another, the keys will differ.
Flux rejects OCI artifacts with an error stating no matching signatures were found.

**Resolution**:
Run `scripts/push-local.sh` with key preflight checks enabled.
The script asserts that `.keys/cosign.pub` matches the cluster secret `flux-system/cosign-pub`.

## 4. Port-Forward Termination on Rollout

**Defect**:
Kubernetes SPDY port-forward tunnels attach to a specific pod instance.
When a deployment rolls out, the old pod is deleted.
The port-forward process remains running on the host but the stream is terminated.
Browsers display connection refused errors.

**Resolution**:
Re-establish port-forwards following any deployment restart.
Run the supervisor or spawn a detached background port-forward process.

## 5. Nginx Single Page Application Route Masking

**Defect**:
Nginx catches unrouted API requests and falls back to serving `index.html`.
The browser receives HTTP 200 OK with `text/html` instead of JSON.
Client applications fail when attempting to parse HTML responses.

**Resolution**:
Verify backend location blocks in `d2-signalloom/apps/dashboard-signalloom/nginx.conf`.
Ensure all API paths are routed to their respective backend services.
