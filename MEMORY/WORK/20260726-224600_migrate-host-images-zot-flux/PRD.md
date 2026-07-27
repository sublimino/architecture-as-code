---
task: Migrate host-loaded images through Zot Flux
slug: 20260726-224600_migrate-host-images-zot-flux
effort: advanced
phase: execute
progress: 0/24
mode: interactive
started: 2026-07-26T22:46:00+01:00
updated: 2026-07-26T23:00:00+01:00
---

## Context

Andrew asked to implement the migration of host-loaded application images into the durable local Zot registry, use the existing Flux runtime substitution pattern, do the work in a new worktree, and integrate the result into the v2.5.0 worktree. The current v2.0.0 worktree has unrelated tracked and untracked changes, so it must not be used for the implementation. The portable targets are the OSRAMP archiver, listener, processor, and six Olly images. The disposable SPIRE proof helper remains Kind-loaded.

### Risks

- The v2.5.0 integration worktree can contain concurrent changes, so the new branch must start clean and integration must be committed rather than copied.
- Local image pushes require the Zot port-forward and must not collide with Flux manifest artifacts.
- Flux substitution only applies to Kustomizations configured with `postBuild.substituteFrom`; the Olly delivery definition requires that existing pattern to be enabled deliberately.

### Plan

Create an isolated branch from `integration/signalloom-d2-v2.5.0`. Centralize local image push preparation in a shared helper, retag the OSRAMP and Olly build targets into Zot’s separate image namespace, replace literal workload references with `${IMAGE_BASE}` and `${ARTIFACT_TAG}`, and enable the already-used Flux runtime ConfigMap substitution for Olly. Build and push all migrated images, verify Zot catalog and Flux-rendered image references, commit, then fast-forward or merge the isolated commit into the v2.5.0 worktree without touching the dirty v2.0.0 worktree.

## Criteria

- [ ] ISC-1: New implementation worktree starts from v2.5 integration branch.
- [ ] ISC-2: Implementation worktree excludes current v2.0 dirty changes.
- [ ] ISC-3: OSRAMP archiver build tags a Zot image reference.
- [ ] ISC-4: OSRAMP archiver build pushes its image into Zot.
- [ ] ISC-5: OSRAMP listener build tags a Zot image reference.
- [ ] ISC-6: OSRAMP listener build pushes its image into Zot.
- [ ] ISC-7: OSRAMP processor build tags a Zot image reference.
- [ ] ISC-8: OSRAMP processor build pushes its image into Zot.
- [ ] ISC-9: OSRAMP archiver manifests use the Zot image template.
- [ ] ISC-10: OSRAMP listener manifests use the Zot image template.
- [ ] ISC-11: OSRAMP processor manifests use the Zot image template.
- [ ] ISC-12: Olly sentinel build pushes a Zot image.
- [ ] ISC-13: Olly authz build pushes a Zot image.
- [ ] ISC-14: Olly MCP build pushes a Zot image.
- [ ] ISC-15: Olly stubs build pushes a Zot image.
- [ ] ISC-16: Olly tenant application build pushes a Zot image.
- [ ] ISC-17: Olly guard build pushes a Zot image.
- [ ] ISC-18: Olly manifests use the Zot image template.
- [ ] ISC-19: SPIRE proof helper retains its Kind-load workflow.
- [ ] ISC-20: Flux substitution reads the existing runtime ConfigMap.
- [ ] ISC-21: Build recipes wait for Zot before push.
- [ ] ISC-22: Changed shell and Makefile syntax validates successfully.
- [ ] ISC-23: Zot catalog contains every migrated image repository.
- [ ] ISC-24: Verified commit is integrated into v2.5 worktree.

## Decisions

## Verification
