---
task: Inventory dashboard API contracts and supporting evidence
slug: 20260727-142300-api-contract-inventory
effort: standard
phase: complete
progress: 12/12
mode: interactive
started: 2026-07-27T14:23:00+01:00
updated: 2026-07-27T14:45:00+01:00
---

## Context

Create a source-backed dashboard API inventory in the assigned Governor worktree.
It must map every dashboard `/api/*` client call to its method, request and
response shapes, local handler, and adapter, fake-service, or persistence
backing. The named React path is absent at this integration baseline, so the
inventory must accurately identify the effective local dashboard source rather
than invent React calls. Required evidence also includes focused contract
validation, a scoped repository commit, and proposal errata. Never edit
`board.json`, any sibling worktree, remotes, or pull-request state. Verify the
named integration ref is an ancestor before repository changes.

### Risks

- Existing inventory rows may be stale against current client call sites.
- Fixture tests may cover a route set different from dashboard discovery.
- HEAD may not descend from the required integration reference.
- Proposal errata requires an Obsidian-safe writer outside git staging.

## Criteria

- [x] ISC-1: Assigned worktree path matches the required Governor repository.
- [x] ISC-2: Named integration reference resolves inside the assigned repository.
- [x] ISC-3: Named integration reference is ancestor of current HEAD.
- [x] ISC-4: Dashboard API source location is evidenced from repository files.
- [x] ISC-5: Inventory enumerates each discovered dashboard `/api/*` client call.
- [x] ISC-6: Every inventory row records one HTTP request method.
- [x] ISC-7: Every inventory row records one request shape.
- [x] ISC-8: Every inventory row records one response shape.
- [x] ISC-9: Every inventory row identifies its local serving handler.
- [x] ISC-10: Every inventory row identifies its concrete response backing.
- [x] ISC-11: Contract validation test passes for documented endpoint coverage.
- [x] ISC-12: Scoped repository commit and proposal errata record evidence.

## Decisions

- 2026-07-27 14:26: Treat the existing inventory as evidence requiring current-baseline revalidation, not proof of completion.
- 2026-07-27 14:36: Review remediation requires a source-closed completeness diagnosis, not a duplicate inventory rewrite.

## Verification

- ISC-1: `git rev-parse --show-toplevel` returned the assigned Governor worktree.
- ISC-2: `refs/heads/integration/signalloom-d2-v2.5.0` resolved to current HEAD.
- ISC-3: `git merge-base --is-ancestor` exited `0` after the scoped commit.
- ISC-4: `ui/` exists; `cp/platform/dashboard/src/api/` does not exist.
- ISC-5: 18 `/api/*` fixture endpoints match 18 inventory document rows.
- ISC-6: All 18 matched rows include nonempty method cells.
- ISC-7: All 18 matched rows include nonempty request-shape cells.
- ISC-8: All 18 matched rows include nonempty response-shape cells.
- ISC-9: All 18 matched rows include nonempty local-handler cells.
- ISC-10: All 18 matched rows include nonempty backing cells.
- ISC-11: `cd tools/demo-console && go test -count=1 ./...` exited `0`.
- ISC-12: Commit `184636134470dd5ceef1e206bfeccb9ee1fb7178` contains only the strengthened contract test; proposal errata lines 920-932 record passing evidence.
- Capability audit: FirstPrinciples was invoked. CodeReview was invoked, but roborev is unavailable; source-backed tests and coverage audit supplied verification.
