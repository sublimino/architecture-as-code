---
task: Wire Zot persistent image cache workflow
slug: 20260726-220000_wire-zot-persistent-image-cache
effort: advanced
phase: complete
progress: 23/24
mode: interactive
started: 2026-07-26T22:00:00+01:00
updated: 2026-07-26T22:14:00+01:00
---

## Context

Andrew wants the local workflow to build application images into Zot's host-backed persistent cache, then have workloads pull those images from Zot for fast restarts. Zot is healthy and the durable `.cache/zot` mount is live. Existing Flux `postBuild.substituteFrom` uses `flux-runtime-info`; local `REGISTRY_BASE` already resolves workload images to Zot. The current gap is the Make target: it builds the frontend image under the Zot address but loads it directly into Kind instead of pushing it to Zot. Preserve the existing Flux substitution and signed artifact path; do not alter non-local registry behavior or unrelated workloads.

### Risks

- Docker cannot address the in-cluster Zot DNS name directly; a localhost port-forward must bridge host pushes to the service.
- A successful push alone is insufficient: the live workload must resolve the same substituted Zot image address.
- Replacing the existing Flux runtime template would duplicate configuration and risk local/non-local drift.

### Plan

Keep Flux substitutions unchanged. Update only `make signalloom-images`: establish the existing Zot service port-forward, build the frontend under its deployed Zot image reference, and push to the forwarded local endpoint. Document the command and cache reuse. Verify the live Zot catalog and the deployed image reference.

## Criteria

- [x] ISC-1: Local runtime ConfigMap defines Zot registry base.
- [x] ISC-2: Frontend deployment image references substituted registry base.
- [x] ISC-3: Frontend deployment tag references substituted artifact tag.
- [x] ISC-4: Local Flux Kustomization imports runtime ConfigMap substitutions.
- [x] ISC-5: Zot cache data mount targets `/var/lib/zot`.
- [x] ISC-6: Kind node mount targets Zot host-cache directory.
- [x] ISC-7: Local image target builds frontend with Zot repository tag.
- [x] ISC-8: Local image target pushes frontend image into Zot.
- [x] ISC-9: Local image target waits for Zot registry availability.
- [x] ISC-10: Local image target avoids direct Kind image loading.
- [x] ISC-11: Push command uses the local registry endpoint.
- [x] ISC-12: Push command preserves the deployment image repository.
- [x] ISC-13: Push command preserves the deployment image tag.
- [x] ISC-14: Local image target is safe on repeated execution.
- [x] ISC-15: Target failure exposes an unavailable Zot registry.
- [x] ISC-16: Documentation describes persistent local image-cache behavior.
- [x] ISC-17: Documentation names the local image-push command.
- [x] ISC-18: Documentation explains restart reuse from Zot cache.
- [x] ISC-19: Documentation retains explicit empty-cache reset guidance.
- [x] ISC-20: Non-local runtime configuration remains unmodified.
- [x] ISC-21: Existing signed artifact push workflow remains unmodified.
- [x] ISC-22: Repository formatting validation succeeds for changed files.
- [x] ISC-23: A live Zot catalog contains the frontend image repository.
- [ ] ISC-24: A cluster workload resolves its image from Zot.

## Decisions

- Reuse the existing `flux-runtime-info` `REGISTRY_BASE` substitution rather than introduce a second image-source mechanism.
- Separate image storage under `IMAGE_BASE=/acme/images`; sharing the manifest artifact repository caused Zot to reject a Docker image manifest at the existing OCI artifact tag.

## Verification

- `make signalloom-images` built and pushed `acme/images/signalloom/apps/fe-signalloom:latest` to Zot at digest `sha256:c706f5c1646394e03f6599f687abcaef9c3a6e75f4e2c6085dd679d03137385b`.
- A live Zot catalog confirmed the image repository exists.
- `git diff --check` and `make -n signalloom-images` passed.
- The current cluster Flux fleet source fails verification for the freshly signed fleet OCI artifact. It therefore did not apply the updated local `IMAGE_BASE` ConfigMap; ISC-24 remains pending. Local `cosign verify --insecure-ignore-tlog` passed for the same fleet digest.
- `code_review` was invoked but roborev is unavailable in this environment.
