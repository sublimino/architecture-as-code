---
task: Verify Phase 2 integration and record evidence
slug: 20260727-064500_verify-phase2-signalloom
effort: extended
phase: execute
progress: 15/16
mode: interactive
started: 2026-07-27T06:45:00+01:00
updated: 2026-07-27T06:52:00+01:00
---

## Context

Verify the scoped Phase 2 Governor integration on the isolated worktree. The
review covers Gateway routing, NetworkPolicy isolation, signed artifact and
provenance contracts, and the TEST-1 test requirement. The work must preserve
the isolated-worktree contract, avoid board or other-worktree edits, record
canonical security and route patterns, run available deterministic tests, make
a signed repository commit, and append machine-readable proposal errata.

Requested evidence includes commands, exit codes, changed files, committed SHA,
tests, and a final `kanban-check` status. Live-cluster claims are not inferred
from static manifests or absent tooling.

### Risks

- The worktree may be detached or contain pre-existing changes, invalidating
  the integration ancestry and clean-start evidence.
- Static manifests may satisfy security intent while live Gateway or policy
  behavior remains untested because no cluster is available.
- Existing proposal errata may contain stale SHA or status fields; the new
  erratum must be self-contained and machine-readable.
- Broad test targets may require Docker, Kind, or network access and fail for
  environmental reasons rather than an integration defect.

### Plan

1. Confirm integration ancestry and capture baseline worktree state.
2. Run static topology, dependency, proof-helper, and BATS validation.
3. Run delivery-contract and release-pack checks, then inspect canonical
   Gateway, NetworkPolicy, and supply-chain sources.
4. Record evidence in this PRD and append proposal errata with the committed
   SHA and machine-readable `kanban-check` result.
5. Commit only scoped repository evidence; verify commit and proposal state.

## Criteria

- [x] ISC-1: Integration branch is an ancestor of task worktree HEAD
- [x] ISC-2: Worktree starts clean apart from this task PRD
- [x] ISC-3: Gateway defines HTTP listener for cluster domain
- [x] ISC-4: Gateway defines HTTPS listener with TLS termination
- [x] ISC-5: HTTP Gateway route redirects requests to HTTPS
- [x] ISC-6: HTTPS Gateway route permits cross-namespace attachments
- [x] ISC-7: Portal namespace has default-deny ingress policy
- [x] ISC-8: Portal namespace has default-deny egress policy
- [x] ISC-9: Portal egress allows DNS on TCP and UDP port 53
- [x] ISC-10: Portal egress allows declared database service ports
- [x] ISC-11: Portal ingress allows only Envoy Gateway namespace
- [x] ISC-12: Supply-chain contract requires cosign signature evidence
- [x] ISC-13: Supply-chain contract binds evidence to immutable digest
- [x] ISC-14: Supply-chain contract requires SPDX SBOM evidence
- [x] ISC-15: Supply-chain contract requires SLSA provenance evidence
- [ ] ISC-16: TEST-1 suite covers required product journeys

## Decisions

- Static contract and manifest evidence is distinguished from live-cluster
  acceptance; no runtime success is claimed without a running cluster.
- The existing canonical Gateway, NetworkPolicy, delivery-contract, and
  deterministic D2 test targets are reviewed without broad refactoring.

## Verification

- ISC-1: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD`; exit 0.
- ISC-2: Baseline `git status --short` showed only this task PRD untracked.
- ISC-3: Gateway manifest declares HTTP listener on port 80 for `${CLUSTER_DOMAIN}`.
- ISC-4: Gateway manifest declares HTTPS listener on port 443 with TLS termination.
- ISC-5: `http-to-https-redirect` declares HTTPS scheme and status code 301.
- ISC-6: HTTPS listener sets `allowedRoutes.namespaces.from: All`.
- ISC-7: Portal NetworkPolicy `default-deny` includes Ingress policy type.
- ISC-8: Portal NetworkPolicy `default-deny` includes Egress policy type.
- ISC-9: Portal dependency policy permits DNS TCP and UDP port 53.
- ISC-10: Portal dependency policy permits ports 5432, 6379, and 9000.
- ISC-11: Portal ingress policy permits only `envoy-gateway-system` on port 8000.
- ISC-12: Delivery contract requires `signature` evidence and cosign identities.
- ISC-13: Delivery contract requires immutable SHA-256 digest references.
- ISC-14: Delivery contract requires `spdx-json` SBOM evidence.
- ISC-15: Delivery contract requires SLSA v1 provenance evidence.
- ISC-16: FAIL. Existing runtime BATS only checks Flux and deployment presence;
  no frontend HTTPRoute or TEST-1 browser/API/auth/error/egress journey suite
  is present. `make -C d2-signalloom test` nevertheless passed 20 static checks.
- `make signalloom-contract-check`: exit 0.
- `make signalloom-check`: exit 0.
- `code_review` could not run because `roborev` is unavailable locally.
