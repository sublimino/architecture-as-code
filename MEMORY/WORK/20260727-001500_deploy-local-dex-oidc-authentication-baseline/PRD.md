---
task: Deploy local Dex OIDC authentication baseline safely
slug: 20260727-001500_deploy-local-dex-oidc-authentication-baseline
effort: advanced
phase: complete
progress: 1/24
mode: interactive
started: 2026-07-27T00:15:00+01:00
updated: 2026-07-27T00:23:00+01:00
---

## Context

Implement the scoped local Dex OIDC baseline inside the isolated Signalloom
worktree. The baseline must provide demo-password authentication without
embedding plaintext credentials in versioned manifests, discovery and JWKS
endpoints, an explicitly local issuer, tenant-aware claims, and dashboard
generic-OIDC integration. Authentication tests, evidence, one scoped commit,
and the proposal's machine-readable kanban-check errata are required.

Token estimate: 28000.

Not requested: board edits, remote pushes, pull requests, nonlocal issuer
configuration, unrelated refactoring, or changes outside this task worktree.

### Risks

- Existing repository patterns may already provide an OIDC adapter that must be
  extended rather than duplicated.
- A Dex static-password fixture may be incompatible with the pinned Dex image.
- Browser-oriented login tests may need a deterministic token-flow substitute.
- The proposal could have an existing errata convention that must be preserved.

### Plan

1. Validate the worktree, integration ancestry, and current implementation.
2. Reuse existing Kubernetes and dashboard configuration conventions.
3. Add the smallest Dex deployment, Secret, configuration, and provider changes.
4. Add deterministic auth checks for config, discovery, JWKS, and credentials.
5. Run scoped and relevant regression commands, inspect the diff, commit it.
6. Add proposal kanban-check evidence using its established errata format.

## Criteria

- [ ] ISC-1: Integration branch is an ancestor before repository changes.
- [ ] ISC-2: Dex workload manifest is present in local baseline.
- [ ] ISC-3: Dex service exposes the local HTTPS listener.
- [ ] ISC-4: Dex configuration uses an explicitly local issuer URL.
- [ ] ISC-5: Dex configuration references a Kubernetes credential Secret.
- [ ] ISC-6: Kubernetes Secret contains bcrypt demo credential hash.
- [ ] ISC-7: Versioned manifest contains no plaintext demo password.
- [ ] ISC-8: Dex static password identity includes configured demo email.
- [ ] ISC-9: Dex static password identity includes configured tenant claim.
- [ ] ISC-10: Dex client has a configured client identifier.
- [ ] ISC-11: Dex client permits the dashboard redirect URI.
- [ ] ISC-12: Dex OIDC discovery endpoint resolves from local issuer.
- [ ] ISC-13: Dex JWKS endpoint returns a nonempty key set.
- [ ] ISC-14: Dashboard provider type is configured as generic OIDC.
- [ ] ISC-15: Dashboard provider uses the Dex issuer URL.
- [ ] ISC-16: Dashboard provider maps tenant identity into access control.
- [ ] ISC-17: Authentication test validates discovery document issuer value.
- [ ] ISC-18: Authentication test validates JWKS response key availability.
- [ ] ISC-19: Authentication test accepts correct demo credential flow.
- [ ] ISC-20: Authentication test rejects an invalid demo credential.
- [ ] ISC-21: Authentication test validates tenant claim propagation.
- [ ] ISC-22: Scoped test command exits successfully after implementation.
- [ ] ISC-23: Repository commit contains only scoped task changes.
- [x] ISC-24: Proposal errata records machine-readable kanban-check status.

## Decisions

- Keep the implementation local-only and minimally scoped to the card.
- Treat evidence as command output plus exact changed-file and commit data.
- Do not alter repository files while required integration ancestry is false.

## Verification

- `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited
  1. HEAD `86e6de27ed041ea98d64ece669ce474f4df58d3a` therefore cannot accept
  repository edits under the card contract.
- `git diff --check` exited 0; tracked diffs were pre-existing unrelated
  MEMORY records and staged diff names were empty.
- No Dex auth tests were run because no compliant repository change was
  permitted. No scoped commit exists.
- Proposal errata was appended through `obsidian append` and reread through
  `obsidian read`; it has the required `kanban-check.v1` fail/no-proceed/
  blocking-drift record.
- FirstPrinciples, Delegation, CodeReview, and Explore-agent capabilities were
  invoked. roborev was unavailable, so its review could not pass.
