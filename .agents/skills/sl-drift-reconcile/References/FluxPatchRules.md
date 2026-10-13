# Reference: Flux Patch & Variable Substitution Rules

## 1. JSON6902 Patch Index Invariant

`d2-osramp-fleet/tenants/local/kustomization.yaml` applies patches to swap remote GitHub Cosign keys with local verification keys:

```yaml
patches:
  - target:
      kind: ResourceSet
      name: tenant-signalloom
    patch: |-
      - op: replace
        path: /spec/resources/3/spec/verify/secretRef/name
        value: local-cosign-pub
```

### The Pitfall
JSON6902 path `/spec/resources/3/...` addresses the target **by array index**.
If any developer or tool inserts a new resource into `/spec/resources` before index 3:
1. Index 3 now points to a different resource.
2. The patch modifies the wrong resource or fails silently if structure differs.
3. The intended target is never patched, so Flux rejects local artifacts because it attempts GitHub-keyless verification against local untrusted signatures.
4. `make push-local-signalloom` still exits 0.

### The Rule
- **Always append new resources to the end of `/spec/resources`. Never insert above existing indexed elements.**
- Validate with `bats d2-signalloom/test/fleet-patch-indexes.bats`.

---

## 2. Flux Variable Substitution (`postBuild.substituteFrom`)

Flux Kustomizations use `postBuild.substituteFrom` to replace `${VAR}` tokens in raw manifest text before applying to Kubernetes.

### The Pitfall
- If a referenced ConfigMap or Secret is missing, Flux replaces nothing and leaves the literal string `${VAR}` inside manifests (e.g. `${PUBLIC_ORIGIN}`, `${REGISTRY_PORT}`).
- Kubernetes applies the object with the literal string.
- No error is thrown during apply, but downstream pods crash or bind to invalid URLs.

### The Rule
- Ensure `tenants.yaml` in `d2-osramp-fleet/clusters/*` maintains:
  ```yaml
  dependsOn:
    - name: flux-system
  ```
- Every `kustomization.yaml` containing `${VAR}` must declare `# FLUX ENVSUBST: YES` in its header.
- Reconcile with:
  ```bash
  flux reconcile kustomization tenants -n flux-system --with-source
  ```
