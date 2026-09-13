# AMXO-P2-PRE — execution evidence

**Status:** PASS  
**Created:** 2026-09-13 15:46:15+01:00  
**Task checkout:** `(detached)`  
**Launch source:** `1d224f51c63be3d771981a20fea8e30c1952e75c`  
**Baseline-fix commit:** `9d40dbd9e503509429003ba77d85eec0627f1025`  
**Integration ref inspected:** `integration/agentmaxxing-onboarding-v0.1.0`  
**Integration tip inspected:** `7a2b45d2c3adb1223163a89fd190f0abaa97f9ac`

## Runtime evidence

| Probe | Observed result |
| :--- | :--- |
| `pwd -P` | `/home/andy/src/.worktrees/905f5/osramp-demo` |
| `git rev-parse --show-toplevel` | `/home/andy/src/.worktrees/905f5/osramp-demo` |
| Initial `git status --short` | empty |
| Initial integration ancestry | exit `0` |
| Initial task and integration SHA | `1d224f51c63be3d771981a20fea8e30c1952e75c` |
| Landlock version syscall | ABI `9`, errno `0` |
| Sandbox denial probe | `/usr/include/stdc-predef.h`: permission denied |
| Board inspection | P2-PRE active; Phase 2 implementation cards backlog |

The integration ref advanced during execution to
`7a2b45d2c3adb1223163a89fd190f0abaa97f9ac`. The three intervening commits modify
only `docs/signalloom/amxo-governor-log.md`; they do not overlap this task diff.
The task did not merge, rebase, switch branches, or mutate integration.

## Command evidence

| Command | Exit | Evidence |
| :--- | :---: | :--- |
| `git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD` | 0 | Required base ancestry passed before edits |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py -v` | 0 | 11 passed, one deprecation warning |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_platform_users.py -q` | 0 | 33 passed, one deprecation warning |
| `python3 -m pytest tests/test_tenant_isolation.py -q -o addopts=` | 0 | 95 passed after route-inventory repair |
| `pytest .../test_write_transactions.py -q -o addopts= -k revoking_credentials` | 0 | 1 passed, 53 deselected |
| `CGO_ENABLED=0 GOCACHE=/tmp/opencode/amxo-p2-pre-go-cache go test ./collectors/agentnono` | 0 | Agentnono contract package passed |
| `UV_CACHE_DIR=... bats test/authz-suite-liveness.bats test/nginx-unauthenticated-locations-are-readonly.bats` | 0 | 9 passed |
| `CGO_ENABLED=0 UV_CACHE_DIR=... make -C d2-signalloom test` | 0 | 571 BATS checks, zero `not ok` |
| `make test` | 0 | Eight end-to-end BATS tests, zero skipped |
| `ls -1 d2-signalloom/apps/fe-signalloom/src/db/migrations/` | 0 | Last entry `038_operator_identities.sql` |

## Migration evidence

- SQL migration count: `23`.
- Prefixes: `001`–`012`, `020`–`021`, `030`–`038`.
- Duplicate prefix set: empty.
- Highest prefix: `038`.
- Next available prefix at inspection time: `039`.
- Data-destructive operations in `035`–`038`: none.
- Conditional constraint replacements: present in `035` and `038`.

## Route evidence

- `/api/agents` list: authenticated tenant dependency; query binds tenant.
- `/api/agents` create: tenant sourced from `principal.tenant`.
- `/api/agents/claim`: tenant sourced from `principal.tenant`.
- `/api/agents/claims`: tenant-filtered claim list.
- `/api/agents/claim/{claim_id}` GET: tenant plus claim predicate.
- `/api/agents/claim/{claim_id}` DELETE: tenant plus claim predicate.
- `/api/agents/{agent_id}/claim`: tenant-qualified agent lookup.
- Cross-tenant conflict response omits the owning tenant identifier.

## Baseline repairs

| File | Repair | Why preflight required it |
| :--- | :--- | :--- |
| `src/api_compat.py` | Tenant-qualified claim upsert conflict target | Match migration `035` |
| `tests/test_agent_claim.py` | Static conflict-target drift guard | Prevent schema/handler text drift |
| `tests/test_tenant_isolation.py` | OpenAPI route inventory | Audit opaque included routers |
| `test/authz-suite-liveness.bats` | Clear disabling addopts for xdist collection | Make liveness test execute its intended probe |
| `apps/dashboard-signalloom/nginx.conf` | Restrict `/docs` to GET/HEAD | Restore static authorization suite |

## Safety evidence

- No remote push occurred.
- No production deployment occurred.
- No live partner infrastructure was contacted.
- No sibling worktree was edited.
- No Kanban runtime state was edited.
- No customer payload, file content, or memory content was collected.
- No Phase 2 registration functionality was implemented.

The conflict-target regression is intentionally static and does not substitute
for P2's future PostgreSQL execution coverage. Landlock ABI availability plus
an observed sandbox denial establish preflight readiness and task confinement,
not completed external-host sandbox enforcement.

The canonical readiness analysis is
`docs/signalloom/amxo-p2-preflight-proof.md`. The qualified proposal errata is
written after the repository deliverable commit so it can contain the resolved
40-character commit identifier without a self-referential Git commit.
