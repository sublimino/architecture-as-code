---
task: Separate dashboard into fe-dashboard workload
slug: 20260727-001500_separate-dashboard-fe-workload
effort: advanced
phase: complete
progress: 1/24
mode: interactive
started: 2026-07-27T00:15:00+01:00
updated: 2026-07-27T00:29:00+01:00
token_estimate: 38000
---

## Context

Separate the React dashboard into the `fe-dashboard` Kubernetes workload in the
isolated governor worktree. The work must provide a buildable nginx image,
Kustomize deployment surface, local configuration, probes, SPA fallback, and
container and route tests. Repository modifications must be committed only to
the task branch after validating ancestry against
`integration/signalloom-d2-v2.5.0`. The linked Obsidian proposal requires an
evidence-backed, machine-readable `kanban-check` errata status. No board state,
other worktrees, remotes, pushes, or pull requests are in scope.

### Risks

- Existing dashboard build tooling may differ from inferred conventions.
- Existing image tags and namespaces must be discovered rather than invented.
- Container tools or cluster tooling may be unavailable in this environment.
- Proposal writes must use the Obsidian-safe CLI path rather than filesystem edits.

### Plan

1. Validate clean task-worktree state and integration ancestry before edits.
2. Inspect the dashboard source and existing `fe-signalloom` application conventions.
3. Add only the image, nginx, manifests, local overlay, and focused tests required.
4. Run format/build/container/route/manifest tests and capture exit-code evidence.
5. Commit repository files, then append a proposal `kanban-check` errata entry using Obsidian.

## Criteria

- [ ] ISC-1: Task worktree ancestry contains integration baseline commit.
- [ ] ISC-2: Dashboard workload uses the fe-dashboard workload identifier.
- [ ] ISC-3: Dashboard image build uses an nginx runtime stage.
- [ ] ISC-4: Dashboard image build copies compiled dashboard assets.
- [ ] ISC-5: Nginx configuration serves the dashboard document root.
- [ ] ISC-6: Nginx configuration falls back unknown paths to index.html.
- [ ] ISC-7: Kubernetes Deployment defines the dashboard container image.
- [ ] ISC-8: Deployment container exposes the dashboard HTTP port.
- [ ] ISC-9: Deployment liveness probe requests the dashboard health route.
- [ ] ISC-10: Deployment readiness probe requests the dashboard health route.
- [ ] ISC-11: Kubernetes Service selects the dashboard workload labels.
- [ ] ISC-12: Kubernetes Service exposes the dashboard HTTP port.
- [ ] ISC-13: Base Kustomization includes each dashboard workload resource.
- [ ] ISC-14: Local Kustomization includes dashboard local configuration.
- [ ] ISC-15: Local configuration supplies the dashboard image reference.
- [ ] ISC-16: Local configuration supplies the dashboard workload namespace.
- [ ] ISC-17: Container test verifies the generated nginx image build.
- [ ] ISC-18: Container test verifies nginx serves the dashboard root.
- [ ] ISC-19: Route test verifies SPA fallback for a client route.
- [ ] ISC-20: Manifest test verifies Deployment resource construction.
- [ ] ISC-21: Manifest test verifies Service resource construction.
- [ ] ISC-22: Kustomize build validates the base dashboard overlay.
- [ ] ISC-23: Kustomize build validates the local dashboard overlay.
- [x] ISC-24: Proposal records evidence-backed machine-readable kanban-check errata.

## Decisions

- Keep the dashboard deployment aligned with existing Signalloom application conventions.
- Treat proposal errata as external evidence, never as a repository commit input.
- Do not make repository changes while the required integration ref is divergent.
- Pinned prerequisite: integration `59d00c43de1481885d78327ff472ce775db7d626` is not an ancestor of HEAD `86e6de27ed041ea98d64ece669ce474f4df58d3a` (exit 1).

## Verification

- Ancestry gate: `git merge-base --is-ancestor 59d00c43de1481885d78327ff472ce775db7d626 86e6de27ed041ea98d64ece669ce474f4df58d3a` exited 1; the required integration ref is not an ancestor.
- Repeat pinned-ref verification confirmed both SHAs remained unchanged during the check.
- Pre-existing changes under `d2-signalloom/apps/fe-signalloom/` were detected and left untouched.
- No repository workload, image, manifest, configuration, test, or commit changes were made because the mandatory gate failed.
- Proposal contains canonical `SLDPB25-P2-FE-DASHBOARD` kanban-check JSON and simple status tag, both `status=fail proceed=no blocking_drift=yes`.
