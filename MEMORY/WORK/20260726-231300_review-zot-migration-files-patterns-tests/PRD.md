---
task: Review Zot migration files patterns tests without modifications
slug: 20260726-231300_review-zot-migration-files-patterns-tests
effort: standard
phase: complete
progress: 10/10
mode: interactive
started: 2026-07-26T23:13:00+01:00
updated: 2026-07-26T23:23:00+01:00
---

## Context

Andrew requested a read-only review of `/home/andy/src/cp/osramp-demo/worktrees/feat/zot-host-images`. The deliverable is concise implementation guidance for migrating host-loaded OSRAMP archiver, listener, and processor images plus six Olly images into the existing local Zot cache through Flux runtime substitutions. The review must identify exact manifests and Makefiles, reusable helper patterns, test commands, and semantic gotchas. No project files in the reviewed worktree may be modified.

### Risks

- The six Olly image identities may be split among several workload manifests.
- Flux substitutions may require a non-obvious variable name or activation path.
- Make targets can distinguish build/push mechanics from local demo orchestration.
- A rendered manifest can succeed while runtime image pull semantics still fail.

## Criteria

- [x] ISC-1: OSRAMP archiver image source manifest is precisely identified
- [x] ISC-2: OSRAMP listener image source manifest is precisely identified
- [x] ISC-3: OSRAMP processor image source manifest is precisely identified
- [x] ISC-4: Each required Olly image manifest is precisely identified
- [x] ISC-5: Existing Zot substitution helper pattern is precisely located
- [x] ISC-6: Required root Makefile migration target is precisely identified
- [x] ISC-7: Required Olly Makefile migration target is precisely identified
- [x] ISC-8: Relevant static rendering test command is precisely identified
- [x] ISC-9: Relevant local runtime verification command is precisely identified
- [x] ISC-10: Reviewed target worktree remains unmodified after analysis

## Decisions

- 2026-07-26 23:14: Use standard effort because this is a bounded read-only repository review.

## Verification

- ISC-1: `archiver.yaml` and local overlay were inspected directly.
- ISC-2: `osramp-purl.yaml`, listener manifest, and overlays were inspected.
- ISC-3: `osramp-purl.yaml` and local overlays define processor image fields.
- ISC-4: Six Olly workload manifest paths were enumerated with `rg`.
- ISC-5: `REGISTRY_BASE` ConfigMap and ResourceSet postBuild pattern were read.
- ISC-6: Root `images` and lifecycle targets were inspected directly.
- ISC-7: Olly build targets and omitted guard target were inspected.
- ISC-8: Existing config-render targets were read from the root Makefile.
- ISC-9: Existing demo-up and BATS acceptance targets were read directly.
- ISC-10: Target `git status --short`, `git diff --check`, and diff check emitted nothing.
