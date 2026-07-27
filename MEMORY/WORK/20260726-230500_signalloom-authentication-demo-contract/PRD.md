---
task: Define isolated Signalloom authentication demo contract
slug: 20260726-230500_signalloom-authentication-demo-contract
effort: advanced
phase: complete
progress: 0/27
mode: interactive
started: 2026-07-26T23:05:00+01:00
updated: 2026-07-26T23:26:00+01:00
iteration: 2

---

## Context

Define the bounded local authentication contract for the Signalloom D2 V2.5 demonstration. The requested scope covers issuer, OIDC client, redirects, claims, tenant mapping, demo credentials, expiry, fixtures, and auth tests. Work remains in the named isolated worktree and must be committed with evidence recorded in the specified Obsidian proposal. Production federation, credentials, identities, external endpoints, board changes, pushes, and pull requests are explicitly excluded.

The contract makes the dashboard/API journey demonstrable and testable while preserving the local-only security boundary. The prerequisite is that the task worktree descends from `integration/signalloom-d2-v2.5.0`; otherwise no repository changes may proceed.

### Risks

Redirect mismatch, claim-name drift, accidental real credential inclusion, fixture network access, and missing integration ancestry would invalidate the result. The implementation must use existing local conventions and prove the contract through hermetic tests.

### Plan

Confirm branch ancestry before mutating the repository. Inventory existing Dex and authentication-test conventions; add only the smallest contract fixture and test files that fit those conventions. Validate with bounded test commands and configuration scans, commit the scoped repository diff, then record machine-readable Kanban evidence in the proposal using Obsidian's CLI writer.

## Criteria

- [ ] ISC-1: Repository ancestry includes integration Signalloom D2 baseline commit.
- [ ] ISC-2: Local issuer URL is explicitly defined in configuration.
- [ ] ISC-3: OIDC client identifier is explicitly defined in configuration.
- [ ] ISC-4: Callback redirect URI is explicitly defined in configuration.
- [ ] ISC-5: Post-logout redirect URI is explicitly defined in configuration.
- [ ] ISC-6: Client redirect URIs remain restricted to localhost endpoints.
- [ ] ISC-7: Issued token audience matches local API identifier.
- [ ] ISC-8: Issued token issuer matches configured local issuer.
- [ ] ISC-9: Token subject identifies the deterministic demonstration user.
- [ ] ISC-10: Token email claim identifies the demonstration user.
- [ ] ISC-11: Token groups claim carries authorized local role.
- [ ] ISC-12: Tenant claim maps demonstration user to local tenant.
- [ ] ISC-13: API tenant mapper accepts the authorized tenant claim.
- [ ] ISC-14: API tenant mapper rejects an unknown tenant claim.
- [ ] ISC-15: Demo credential fixture uses a non-production username.
- [ ] ISC-16: Demo credential fixture stores only a password hash.
- [ ] ISC-17: Access-token lifetime is explicitly configured for demonstrations.
- [ ] ISC-18: Expired access tokens are rejected by authentication tests.
- [ ] ISC-19: Valid local tokens are accepted by authentication tests.
- [ ] ISC-20: Incorrect token audience is rejected by authentication tests.
- [ ] ISC-21: Incorrect token issuer is rejected by authentication tests.
- [ ] ISC-22: Bounded authentication fixtures execute without network access.
- [ ] ISC-23: Authentication contract tests exit successfully in isolation.
- [ ] ISC-24: Repository changes are committed on the task branch.
- [ ] ISC-A-1: Anti: Production identity federation remains absent from configuration.
- [ ] ISC-A-2: Anti: Production identity credentials remain absent from fixtures.
- [ ] ISC-A-3: Anti: External identity endpoints remain absent from test fixtures.

## Decisions

- 2026-07-26 23:09: Blocked repository mutation because `integration/signalloom-d2-v2.5.0` is not an ancestor of this task worktree HEAD.
- 2026-07-26 23:23: Continued block: the target fast-forward changes `Makefile`, which is already modified by unrelated work in this task worktree.

## Verification

- ISC-1: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 1; branch is `integration/signalloom-d2-v2.0.0` at `4bdfc29`.
- ISC-2 through ISC-23: Not executed because the required ancestry prerequisite failed before scoped mutation.
- ISC-24: No commit created because repository mutation is prohibited by the failed ancestry check.
- ISC-A-1 through ISC-A-3: No new configuration or fixtures were created; agent review found no Dex/OIDC user-auth baseline.
- Proposal errata: Obsidian CLI appended `SLDPB25-P1-3` machine-readable failure status; direct file read confirmed it.
- Capability check: FirstPrinciples, explore, Engineer, and CodeReview skills/tools were invoked; roborev review was unavailable locally.
- Iteration 2: Integration ref is eight commits ahead but remains non-ancestor; its target delta overlaps the pre-existing modified `Makefile`, so reconciliation and implementation remain unsafe.
