# Image Verification Without Kyverno

Signal Loom defers Cilium integration and does not use Kyverno. This document
covers how to achieve image signature verification using CEL-based
ValidatingAdmissionPolicy (native k8s) and Flux's built-in cosign verification.

## Two layers of image verification

### Layer 1: Flux OCIRepository verification (GitOps gate)

Flux already verifies cosign signatures on every OCIRepository before
reconciliation. This is configured in the fleet tenants:

```yaml
# d2-osramp-fleet/tenants/base/apps.yaml
spec:
  ref:
    tag: latest
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/acme-co/osramp/...\.yaml@...$
```

**What this covers:** any OCI artifact Flux reconciles (Kustomizations, HelmReleases)
must carry a valid cosign signature matching the OIDC identity. Unsigned or
tampered artifacts are rejected before they enter the cluster.

**What this does NOT cover:** images pulled directly by pods (e.g. a Deployment
references `zot.registry.svc.cluster.local:5000/acme/images/app:latest`) — Flux
verifies the *manifest* artifact, not the *container image* in the Deployment spec.

### Layer 2: CEL ValidatingAdmissionPolicy (admission gate)

Kubernetes 1.30+ supports `ValidatingAdmissionPolicy` with CEL expressions as a
native, controller-free alternative to Kyverno/OPA for admission control.

**What CEL can do for image verification:**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-trusted-registry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.startsWith('zot.registry.svc.cluster.local:5000/acme/') ||
          c.image.startsWith('ghcr.io/controlplaneio/')
        )
      message: "All container images must come from the trusted registry"
    - expression: >-
        object.spec.initContainers.orValue([]).all(c,
          c.image.startsWith('zot.registry.svc.cluster.local:5000/acme/') ||
          c.image.startsWith('ghcr.io/controlplaneio/')
        )
      message: "All init container images must come from the trusted registry"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-trusted-registry-binding
spec:
  policyName: require-trusted-registry
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        signalloom.io/image-policy: enforced
```

**What CEL can enforce:**
- Image registry allowlist (only trusted registries)
- Image tag restrictions (no `latest`, require digest)
- Label/annotation requirements on pods
- Pod security standards (capabilities, privilege, root filesystem)
- Resource limits enforcement
- Namespace isolation rules

**What CEL CANNOT do (Kyverno's gap):**
- **Cryptographic signature verification** — CEL cannot call external APIs or
  run cosign/notation verification at admission time. It can only inspect the
  admission request object fields (image ref, labels, annotations).
- **Image mutation** (tag→digest resolution) — CEL is validate-only, not mutate.

### Closing the signature verification gap

For cryptographic image verification at admission time (the Kyverno
`verifyImages` capability), the alternatives without Kyverno are:

1. **Sigstore policy-controller** (`policy.sigstore.dev/v1alpha1/ClusterImagePolicy`)
   — a lightweight controller that verifies cosign/Notary signatures at admission.
   Single-purpose, well-maintained, Sigstore project. This is the recommended
   replacement for Kyverno's `verifyImages`.

2. **Connaisseur** — another dedicated image verification admission controller.

3. **Flux-only strategy** — rely on Flux OCIRepository verification for the
   GitOps path, and use CEL to restrict image sources to the trusted registry
   (which only contains Flux-verified artifacts). This means: if the image is in
   the registry, Flux already verified it. CEL just enforces "no image from
   outside the registry."

**Recommendation for Signal Loom:** Option 3 (Flux + CEL) for the demo/MVP. The
in-cluster Zot registry is the single trust root — Flux verifies signatures
before pushing to Zot, and CEL ensures pods can only pull from Zot. Add Sigstore
policy-controller for production deployments where defence-in-depth at the
admission layer is required.

## Implementation status

| Control | Mechanism | Status |
| :---- | :---- | :---- |
| OCI artifact signature verification | Flux `verify.provider: cosign` | **Implemented** (fleet tenants) |
| Trusted registry enforcement (pods) | CEL ValidatingAdmissionPolicy | **Adopted** — `policy/cel/require-trusted-registry.yaml`, binding `Deny` |
| Image tag restrictions (no `latest`, require digest) | CEL ValidatingAdmissionPolicy | **Adopted** — `policy/cel/require-image-digest.yaml`, binding `Warn` platform-wide, raised to `Deny` in `admission-demo` by `policy/cel/admission-demo-bindings.yaml` |
| Cryptographic image verification at admission | Sigstore policy-controller | **Not deployed.** This is the one capability lost with Kyverno, and nothing in the bundle replaces it |
| Kyverno `verifyImages` | Kyverno ClusterPolicy | **Removed (OSD-7).** See below |

### OSD-7 — why Kyverno went, and what it cost

Kyverno was never a working control in this repo, only an apparent one:

- It appears in **zero** files under `d2-osramp-fleet/` and `d2-infra/`, **zero** of the 30 entries in
  `bundle/.manifest.d/images.json`, and **zero** lines of either source image list. The appliance
  bundled no admission controller at all.
- `policy/kyverno-verify-images.yaml` was delivered by **no** Kustomization and **no** ResourceSet —
  only imperatively, by `scripts/admission-demo.sh`, which `kubectl apply`d Kyverno's upstream
  `install.yaml` from a GitHub release URL. An air-gapped appliance cannot make that fetch.

So the P2-4 / D4 deliverable — *a digest-pinned platform image is admitted and an untrusted one
rejected* — was unsatisfiable as built. The CEL path satisfies it with no extra image.

**What was genuinely lost, stated plainly:** cryptographic signature verification *at admission*.
CEL cannot call out of the API server, so no CEL expression can verify a cosign signature. Option 3
above (Flux + CEL) is now the shipped position, and its security claim is narrower than Kyverno's
would have been: Flux verifies the signature before an artefact reaches the in-cluster Zot registry,
and admission enforces "digest-pinned, and from that registry". That is sound **only while the
registry's contents are exclusively Flux-placed** — anything else with push access to Zot bypasses
the signature gate entirely while still satisfying admission. Sigstore policy-controller remains the
replacement for defence in depth, and it is not deployed.

**Also fixed while adopting it.** `require-trusted-registry.yaml` carried
`object.spec.initContainers.orValue([])`, which *compiles* and then fails at eval with
`no such key: initContainers` on any pod declaring none — `.orValue()` is a method on an optional,
and plain selection of an absent key errors before it is reached. With `failurePolicy: Fail` that
rejected every ordinary pod in any namespace carrying `signalloom.io/image-policy=enforced`: an
outage, not a guardrail, and the likeliest reason the policy was never wired into a Kustomization.
The fix is optional field selection, `object.spec.?initContainers.orValue([])`. Measured with cel-go
under `cel.OptionalTypes()` (the API server's environment) and pinned by
`d2-signalloom/apps/fleet-manager/image_trust_vap_test.go`.
