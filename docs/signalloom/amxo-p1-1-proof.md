# AMXO-P1-1 attributable operator lifecycle proof

**Evidence captured:** 2026-09-12T20:42:11+01:00
**Base commit:** `ebd90f096bfc43bda100463f284941ffaa8caa19`
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`

## Prompt-to-artifact checklist

| Required outcome | Artifact | Positive evidence |
| :--- | :--- | :--- |
| Individually attributable operator identity | `038_operator_identities.sql`; `operator_identity.py` | Global `(issuer, subject)` uniqueness, individual-only check, immutable UUID linkage |
| Tenant-derived authorization | `config.py`; `operator_identity.py` | Tenant absent from request models; configured tenants fail closed against persisted membership |
| Admin/editor/viewer authorization | `agentmaxxing-operator-policy.json`; `AUTHORIZATION_MATRIX` | Admin manages identities; editor and viewer sign in only |
| Shared and anonymous rejection | Pydantic models and persisted-row checks | Request and legacy-row negative tests pass |
| Server-owned attributable audit | Migration 038 and `_audit_log` | Actor UUID, issuer, subject, target UUID, action, outcome, database timestamp |
| Durable removal lifecycle | `remove_operator_identity` | Transactional soft removal, user deactivation, retained history, post-removal denial |
| Concurrent administrator safety | Tenant advisory lock | Real PostgreSQL race leaves one active administrator and one removal audit |
| Focused automated tests | `test_platform_users.py`; `operator-identity.bats` | 33 Pytests and six BATS assertions pass without skips |
| Existing API compatibility | Signal Loom backend suite | 1,295 passed; existing 83 conditional skips |
| Consumer contract compatibility | Existing contract target | 56 of 56 tests pass |
| Fresh-database packaging | Both generated bootstrap SQL artifacts | Canonical bootstrap drift check passes with migration 038 included |
| Reviewable operator contract | Policy JSON and lifecycle guide | Identity source, matrix, removal owner, and denial behavior documented |
| Scoped repository delivery | Git diff and commit audit | No push, merge, deployment, board mutation, or sibling-worktree write |

## Required commands

These commands are the reproducible acceptance surface for this delivery:

```bash
python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/test_platform_users.py -q -k test_operator_identity
bats test/signalloom/operator-identity.bats
make demo-agentmaxxing-contract-test
make demo-signalloom-api-test TIER=contract
bash test/signalloom/operator-identity-postgres.sh
bash d2-signalloom/test/check-bootstrap-drift.sh
```

The complete backend regression command was:

```bash
UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \
  --with pytest --with pytest-asyncio --with pytest-xdist \
  --with-requirements d2-signalloom/apps/fe-signalloom/src/requirements.txt \
  python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests -q
```

The dashboard audit-vocabulary regression command was:

```bash
cd d2-signalloom/apps/dashboard-signalloom
bun run test --run src/views/adversarial-audittrail.test.ts
bun run typecheck
```

## PostgreSQL execution proof

A temporary clean `postgres:16-alpine` database was exercised by the checked-in
`test/signalloom/operator-identity-postgres.sh` harness. It applied all 23 repository
migrations in filename order with `psql -v ON_ERROR_STOP=1`. Migration 038 was
then applied a second time. Catalog assertions proved:

```text
MIGRATIONS_APPLIED=23
MIGRATION_038_RERUN=PASS
OPERATOR_TABLE=operator_identities
EVENT_CHECK=true
ACTOR_TENANT_FK=FOREIGN KEY (actor_user_id, tenant_id) REFERENCES platform_users(id, tenant_id) ON DELETE RESTRICT
```

Two real asyncpg transactions then raced to remove two different administrators
from the same tenant through `remove_operator_identity`. The tenant advisory
lock serialized the decisions:

```text
CONCURRENT_OUTCOMES=refused:last_operator_admin,removed:True
ACTIVE_ADMINS=1
REMOVED_ADMINS=1
REMOVAL_AUDITS=1
```

## Scope and safety gates

```text
WORKTREE=/home/andy/src/.worktrees/32b57/osramp-demo
BASE_REF_GATE=PASS
LANDLOCK_ABI=9
```

No customer files, process memory, external partner systems, runtime cluster,
remote repository, Kanban state, or sibling worktree were accessed or changed.
