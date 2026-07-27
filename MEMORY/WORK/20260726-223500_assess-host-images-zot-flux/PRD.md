---
task: Assess moving host images through Zot Flux
slug: 20260726-223500_assess-host-images-zot-flux
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T22:35:00+01:00
updated: 2026-07-26T22:44:00+01:00
---

## Context

Andrew asked which host-loaded images can move to Zot, whether this is a re-tag-and-push plus in-cluster Flux problem, and whether existing Flux templating supports it. No implementation was requested. The repository has host-to-Kind loads for three OSRAMP app images, six Olly images, and a disposable SPIRE helper. Flux already substitutes `${IMAGE_BASE}` and `${ARTIFACT_TAG}` from `flux-runtime-info` for the Signal Loom frontend, but the OSRAMP and Olly manifests use literal local image names.

## Criteria

- [x] ISC-1: Host-loaded OSRAMP images are enumerated from repository targets.
- [x] ISC-2: Host-loaded Olly images are enumerated from repository targets.
- [x] ISC-3: Disposable SPIRE helper is classified separately.
- [x] ISC-4: Existing Flux image substitution pattern is identified.
- [x] ISC-5: Existing Flux substitution source is identified.
- [x] ISC-6: Zot push requirement is distinguished from Flux substitution.
- [x] ISC-7: Recommended migration order is justified by restart impact.
- [x] ISC-8: No implementation changes are made during assessment.

## Decisions

- Flux `postBuild.substituteFrom` is the correct existing pattern for image references, but images must first be built and pushed to Zot independently.
- Migrate the OSRAMP listener and processor first because they each run twice in the current cluster; keep the disposable SPIRE helper as a Kind-loaded proof image.

## Verification

- `d2-osramp-apps/Makefile` host-loads `archiver:dev`, `listener:dev`, and `processor:dev`.
- `olly-replica/Makefile` host-loads `olly-sentinel`, `olly-authz`, `olly-elk-mcp`, `olly-stubs`, `olly-tenant-app`, and `olly-llm-guard`.
- `d2-signalloom/apps/fe-signalloom/base/deployment.yaml` already uses `${IMAGE_BASE}` and `${ARTIFACT_TAG}`; Flux `postBuild.substituteFrom` reads `flux-runtime-info`.
- No application or infrastructure files were modified during this assessment.
