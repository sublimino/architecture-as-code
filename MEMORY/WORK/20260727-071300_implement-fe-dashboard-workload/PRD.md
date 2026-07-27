---
task: Implement separate fe-dashboard workload fully
slug: 20260727-071300_implement-fe-dashboard-workload
effort: advanced
phase: blocked
progress: 0/28
mode: interactive
iteration: retry-after-ancestry-reconciliation
started: 2026-07-27T07:13:00+01:00
updated: 2026-07-27T07:19:00+01:00
token_estimate: 44000
---

## Context

Following reconciliation of `integration/signalloom-d2-v2.5.0`, build the
parallel React dashboard as an independent `fe-dashboard` workload. It must
have a buildable and signed nginx image, Deployment, Service, Kustomize base
and local configuration, health probes, SPA fallback, and focused container
and route tests. Work only in the named task worktree; do not modify board
state, another worktree, remotes, or pull-request state. Commit only the
scoped repository files and append evidence-backed machine-readable proposal
errata using the Obsidian CLI.

### Risks

- Existing dashboard source may be static JavaScript rather than Vite output.
- Image signing requires a local key or preconfigured signing convention.
- Existing task-worktree changes must remain outside this card's commit.
- Container execution may require an available local Docker daemon.
- Retry preflight found the claimed common SHA `e799fb3` is now only the merge base; current HEAD and required integration ref have diverged again.

### Blocker

The live `integration/signalloom-d2-v2.5.0` ref (`d6da1e7`) is not an
ancestor of task HEAD (`346e830`). The integration owner must reconcile the
required ref to contain the task base before this card can modify source.

### Plan

1. Pin the reconciled integration SHA and inspect only relevant source and workload patterns.
2. Add a standalone `fe-dashboard` application subtree and local fleet reference.
3. Use a multi-stage nginx image and health/SPA configuration tested in a container.
4. Render Kustomize, run targeted route tests, sign the local image by repository convention.
5. Review staged files, commit only scoped paths, and append passing proposal evidence.

## Criteria

- [ ] ISC-1: Required integration ref resolves to a commit.
- [ ] ISC-2: Task HEAD contains the required integration commit.
- [ ] ISC-3: Dashboard workload directory uses the fe-dashboard identifier.
- [ ] ISC-4: Dashboard Dockerfile builds dashboard assets in a build stage.
- [ ] ISC-5: Dashboard Dockerfile uses nginx as its runtime stage.
- [ ] ISC-6: Dashboard runtime image exposes the configured HTTP port.
- [ ] ISC-7: Image build target produces the dashboard runtime image.
- [ ] ISC-8: Image signing target verifies the dashboard image signature.
- [ ] ISC-9: Nginx serves dashboard static files from configured document root.
- [ ] ISC-10: Nginx falls back client routes to index.html.
- [ ] ISC-11: Nginx returns a health response from probe route.
- [ ] ISC-12: Dashboard Deployment uses the fe-dashboard workload name.
- [ ] ISC-13: Deployment container references the dashboard runtime image.
- [ ] ISC-14: Deployment exposes the dashboard HTTP container port.
- [ ] ISC-15: Deployment liveness probe requests the health route.
- [ ] ISC-16: Deployment readiness probe requests the health route.
- [ ] ISC-17: Dashboard Service selects fe-dashboard pod labels.
- [ ] ISC-18: Dashboard Service exposes the configured HTTP service port.
- [ ] ISC-19: Base Kustomization includes dashboard Deployment resource.
- [ ] ISC-20: Base Kustomization includes dashboard Service resource.
- [ ] ISC-21: Local Kustomization includes dashboard local configuration.
- [ ] ISC-22: Local overlay provides the dashboard image location.
- [ ] ISC-23: Local overlay provides the dashboard workload namespace.
- [ ] ISC-24: Container test builds the dashboard nginx image.
- [ ] ISC-25: Container test validates dashboard root HTTP response.
- [ ] ISC-26: Route test validates SPA fallback HTTP response.
- [ ] ISC-27: Kustomize renders both dashboard base and local manifests.
- [ ] ISC-28: Proposal records passing machine-readable kanban-check evidence.

## Decisions

- Preserve existing Signalloom image and Kubernetes conventions where applicable.
- Run deterministic local checks before committing scoped repository files.

## Verification

- Pending reconciled-ancestry verification, implementation, and tests.
