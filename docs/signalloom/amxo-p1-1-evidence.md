# AMXO-P1-1 verification evidence

**Recorded:** 2026-09-12T20:42:11+01:00
**Scope:** attributable AgentMaxxing operator identity, authorization, audit,
removal, and regression compatibility.

## Test ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/test_platform_users.py -q -k test_operator_identity` | 33 passed | 0 | Identity models, bootstrap, authorization, sign-in, audit, removal, OpenAPI |
| `bats test/signalloom/operator-identity.bats` | 6 passed | 0 | Policy, schema, wire negatives, focused lifecycle suite |
| `make demo-agentmaxxing-contract-test` | 6 passed | 0 | Stable named AgentMaxxing acceptance target |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | Consumer contracts and migration harness |
| Full backend Pytest command in proof report | 1,295 passed | 83 existing conditional skips | Complete `src/tests` regression suite |
| Audit provenance, event vocabulary, and migration subset | 44 passed | 0 | Server-owned audit and migration invariants |
| `python3 -m pytest .../test_tenant_isolation.py -q` via pinned uv environment | 95 passed | 0 | Exhaustive authenticated route and SQL tenant sweep |
| `bun run test --run src/views/adversarial-audittrail.test.ts` | 18 passed | 0 | Dashboard event types and colour taxonomy remain synchronized |
| `bun run typecheck` | passed | n/a | Dashboard TypeScript contract |
| `bash test/signalloom/operator-identity-postgres.sh` | passed | n/a | Real migration rerun and concurrent removal proof |
| `bash d2-signalloom/test/check-bootstrap-drift.sh` | passed | n/a | Both generated bootstrap artifacts include migration 038 |
| `git diff --check` | passed | n/a | No whitespace errors |

The repository-wide dashboard ESLint command remains red on 82 errors and six
warnings that predate this task. Its output includes the pre-existing unused
`Link` import in `AuditTrail.tsx`; this change adds only event vocabulary entries
to that file and introduces no new lint finding.

## Database evidence

- Fresh PostgreSQL 16 migration replay: pass, 23 migrations.
- Migration 038 immediate second application: pass.
- Operator table presence: pass.
- Legacy plus operator audit vocabulary preservation: pass.
- Tenant-coherent actor foreign key: pass.
- Concurrent final-admin safety: one removal accepted, one refused.
- Remaining active administrators after race: exactly one.
- Attributable removal events after race: exactly one.

## Independent review evidence

Two read-only reviewers identified unmanaged-tenant lifecycle access,
concurrent bootstrap/removal races, schema-ambiguous constraint lookup, stale
login response data, an incomplete error schema, and tenant-incoherent audit
attribution. Each implementation defect was corrected and focused regressions
were rerun. The second engineering review confirmed its four prior findings
resolved; its only follow-up exposed a tenant-isolation fixture setup gap, which
was corrected before the 95-test tenant suite passed.

`roborev` could not run because the executable is not installed. This absence
is reported rather than represented as a passing review. Deterministic ripwire
analysis and two independent read-only code reviews were used instead.

## Delivery boundaries

- No remote push performed.
- No merge or rebase performed.
- No runtime deployment performed.
- No project-board state changed.
- No sibling worktree changed.
- Temporary PostgreSQL containers removed automatically after each proof.
