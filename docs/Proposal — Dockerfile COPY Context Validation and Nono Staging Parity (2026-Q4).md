# Proposal — Dockerfile COPY Context Validation and Nono Staging Parity (2026-Q4)

## Context
Image builds in the repository must succeed in clean checkouts without relying on cached layers.
The test suite `test/dockerfile-copy-sources.bats` verifies that all `COPY` sources in Make-built Dockerfiles exist within their context.
It also ensures the parser observes all `docker build` commands declared across root and slice Makefiles.

## Problem Statement
The root `Makefile` defines target `swarm-cpai-engineer-image` without staging `nono.real` into the build context.
Because `d2-signalloom/apps/cpai-engineer/Dockerfile` requires `nono.real`, clean builds fail immediately.
In `test/dockerfile-copy-sources.bats`, test 1 expects two skipped build sites.
However, duplicate definitions of the `cpai-engineer` build site cause `all - resolved` to evaluate to three.
Additionally, test 2 fails because `nono.real` binaries are gitignored and only generated at build time.
In a clean tree, static existence checks report them as missing unless verified against Makefile staging rules.

## Objectives
1. Add `nono.real` staging to `swarm-cpai-engineer-image` in the root `Makefile`.
2. Update the expected skipped site count in `test/dockerfile-copy-sources.bats` from two to three with documentation.
3. Teach `test/dockerfile-copy-sources.bats` to verify Makefile staging rules for gitignored `nono.real` binaries.
4. Verify all tests in `test/dockerfile-copy-sources.bats` pass cleanly in an unpolluted tree.

## Proposed Changes

### 1. Root Makefile CPAI Engineer Nono Staging
In `Makefile`, update recipe `swarm-cpai-engineer-image`.
Copy `nono` to `d2-signalloom/apps/cpai-engineer/nono.real` and set execution permissions before running `docker build`.

### 2. Update Skipped Sites Count
In `test/dockerfile-copy-sources.bats`, update `SKIPPED_SITES_EXPECTED` to three.
Document the make-variable targets and the duplicate `cpai-engineer` build site.

### 3. Verify Makefile Staging Recipes for Nono Binaries
In `test/dockerfile-copy-sources.bats`, inspect Makefile staging recipes when `nono.real` is absent on disk.
Confirm that the build recipes contain explicit `cp` instructions for the binary.

## Verification Plan
1. Run `bats test/dockerfile-copy-sources.bats` and confirm all tests pass cleanly.
2. Verify documentation index synchronization with `bats test/docs-index-sync.bats`.
3. Check documentation style compliance using `scripts/docs-lint.sh`.
4. Run `scripts/lint-pipefail-grep-q.sh` to confirm no script regressions.
