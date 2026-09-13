# AMXO-P2-PRE — Phase 2 identity and claim preflight proof

**Status:** PASS — Phase 2 identity implementation may start from the frozen contracts  
**Verified at:** 2026-09-13 15:46:15+01:00  
**Logical ID:** `P2-PRE`  
**Role:** preflight  
**Launch base:** `1d224f51c63be3d771981a20fea8e30c1952e75c`  
**Baseline-fix commit:** `9d40dbd9e503509429003ba77d85eec0627f1025`  
**Integration tip inspected:** `7a2b45d2c3adb1223163a89fd190f0abaa97f9ac`  
**Integration ref:** `integration/agentmaxxing-onboarding-v0.1.0`

## Verdict

Phase 1's attributable-operator, claim-lifecycle, signed-session, and external
wire contracts are present. Numbered migrations have no prefix collision, and
`039` is the next available external-agent migration number. Existing FastAPI
agent and claim routes derive tenant scope from authenticated server-side
identity and tenant-qualify claim reads and releases.

Two pre-existing baseline mismatches were repaired before this proof was
issued:

1. The database-backed claim upsert still targeted the removed global
   `UNIQUE(name)` contract. It now targets `(tenant_id, name)`, matching
   migration `035`.
2. The tenant-isolation route inventory walked opaque FastAPI router entries.
   It now audits the published OpenAPI method/path surface.

The Signal Loom static suite also exposed an unguarded `/docs` proxy and an
xdist-disabled collection check. Both received narrow baseline corrections.
No Phase 2 operator or external-agent registration behavior was implemented.

## Prompt-to-artifact checklist

| Requirement | Evidence | Result |
| :--- | :--- | :---: |
| Isolated runtime worktree | Physical Git top-level `/home/andy/src/.worktrees/905f5/osramp-demo` | PASS |
| Integration ancestry | Initial merge-base ancestry exit `0` at launch base | PASS |
| Phase 1 deliverables merged | Migrations `008`, `035`–`038`; contract schemas; API modules | PASS |
| Migration sequence audit | 23 ordered files; no duplicate prefixes; next `039` | PASS |
| FastAPI agent route audit | `/api/agents` handlers and tenant dependencies inspected | PASS |
| FastAPI claim route audit | create/list/get/release/by-id routes inspected | PASS |
| Tenant isolation readiness | Claim, operator, adversarial isolation, transaction tests | PASS |
| Runtime-isolation readiness | Isolated worktree, sandbox denial, Landlock ABI `9` | PASS |
| Deterministic telemetry handling | Closed schemas, canonical decoding, replay vocabulary | PASS |
| Required focused pytest | 11 passed | PASS |
| Root full test target | `make test` exited `0`; eight tests, zero skips | PASS |
| Signal Loom static baseline | 571 BATS checks, zero failures | PASS |
| Execution evidence | `docs/signalloom/amxo-p2-pre-proof.md` | PASS |
| Proposal errata | Qualified AMXO-P2-PRE block, written after commit | PASS |
| Phase 2 implementation exclusion | Diff contains baseline fixes plus proof only | PASS |

## Phase 1 contract presence

| Contract | Canonical artifact | Preflight finding |
| :--- | :--- | :--- |
| Platform users | `db/migrations/008_platform_users.sql` | Tenant-owned operator records exist |
| Claim vocabulary | `db/migrations/035_agent_claim_contract.sql` | Registry names are tenant-qualified |
| Claim persistence | `db/migrations/036_agent_claim_persistence.sql` | Active tenant-agent claims are unique |
| Signed sessions | `db/migrations/037_signed_audit_sessions.sql` | Session rows carry tenant and agent identity |
| Operator identity | `db/migrations/038_operator_identities.sql` | Issuer/subject attribution and soft removal exist |
| Tenant authorization | `src/api_compat.py` | JWT subject maps to configured tenant server-side |
| Claim lifecycle | `src/agent_claim.py`, `src/api_compat.py` | Claim delegation and release seams exist |
| Integrity authority | `signal-ingest/collectors/agentnono/` | Go retains original-chain verification authority |

The integration ref advanced during this task only through
`docs/signalloom/amxo-governor-log.md`. That path does not collide with this
card's changes. No merge, rebase, branch switch, or integration mutation was
performed.

## Migration collision audit

The directory contains these numeric ranges:

- `001`–`012`
- `020`–`021`
- `030`–`038`

The gaps are established range boundaries, not duplicate or out-of-order
collisions. Prefix counting found no duplicate number. The highest prefix is
`038`, therefore Phase 2 external-agent tables must begin at **`039`** unless a
Governor lands another migration first.

Migrations `035`–`038` contain no table drop, column drop, truncation, or row
deletion. Migrations `035` and `038` conditionally replace constraints inside
transactions; those operations alter validation contracts without deleting
stored rows. No destructive P2-PRE migration was created.

### Collision found and repaired

Migration `035` removes global `UNIQUE(name)` and creates:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_registry_tenant_name
  ON public.agent_registry (tenant_id, name);
```

The claim upsert still declared `ON CONFLICT (name)`. PostgreSQL would reject
that statement because no matching unique constraint remains. The baseline fix
changes only the conflict target to `ON CONFLICT (tenant_id, name)` and adds a
static drift guard tying the handler text to migration `035`. The guard does not
replace a future PostgreSQL execution test; P2's database-backed suite must
exercise the statement against the migrated schema.

## FastAPI route audit

The application router is mounted under `/api`, so source decorators below map
to the published `/api/...` paths.

| Published route | Handler | Tenant source | Storage boundary |
| :--- | :--- | :--- | :--- |
| `GET /api/agents` | `agents` | `Depends(authenticated_tenant)` | `agent_registry WHERE tenant_id = $1` |
| `POST /api/agents` | `create_agent` | `principal.tenant` | Tenant-qualified registry insert |
| `POST /api/agents/claim` | `claim_agent` | `principal.tenant` | `_execute_claim` transaction |
| `POST /api/v1/agents/claim` | `claim_agent` | `principal.tenant` | Same canonical handler |
| `GET /api/agents/claims` | `list_agent_claims` | `authenticated_tenant` | `agent_claims WHERE tenant_id = $1` |
| `GET /api/agents/claim/{claim_id}` | `get_agent_claim` | `authenticated_tenant` | Tenant plus claim predicate |
| `DELETE /api/agents/claim/{claim_id}` | `release_agent_claim` | `authenticated_tenant` | Tenant-qualified update |
| `POST /api/agents/{agent_id}/claim` | `claim_agent_by_id` | `principal.tenant` | Tenant-qualified agent lookup |

`authenticated_principal` validates the bearer JWT, maps `claims["sub"]` through
the server configuration, and rejects unmapped subjects with `403`. Request
bodies do not determine the handler's tenant. Cross-tenant claim conflicts
return a generic `409 claim_conflict` without disclosing the owning tenant.

## Tenant-isolation assertions ready for Phase 2

Existing suites already establish the reusable test seams:

- Claim list/get/release hides tenant A records from tenant B.
- Unauthenticated claim reads return `401`.
- Database statements bind the authenticated tenant.
- Operator creation rejects shared identities.
- Operator removal is atomic and attributable.
- Credential revocation and its audit row share one transaction.
- Claim persistence uses the tenant-qualified registry uniqueness contract.

P2-1 and P2-2 should add behavior at these existing seams, not create a second
identity plane. Their focused suites can assert independently:

1. A request-supplied tenant value cannot alter authenticated tenant scope.
2. A shared or anonymous operator identity is rejected before persistence.
3. A removed operator cannot register or claim an external agent.
4. One external host binds to one pre-registered tenant-agent pair.
5. Same-tenant duplicate registration follows the frozen deterministic result.
6. Cross-tenant duplicate registration returns a non-enumerating conflict.
7. Failed audit attribution rolls back registration state.
8. Read routes return `404`, not cross-tenant existence disclosure.

Single-use enrollment-token consumption and independent host-credential
revocation belong to Phase 3. Their closed schemas and owner boundaries are
present, but P2-PRE does not implement or falsely certify those future flows.

## Runtime isolation and telemetry handling

- The task executed in a dedicated worktree under the platform sandbox rather
  than the principal checkout. A blocked system-header read produced an explicit
  permission denial, confirming that filesystem restrictions were active.
- A direct `landlock_create_ruleset(..., LANDLOCK_CREATE_RULESET_VERSION)` probe
  returned ABI `9`; the declared missing-Landlock hard blocker is absent.
- External evidence schemas set `additionalProperties: false` at envelope and
  attribute-object boundaries.
- Process exports are limited to health, CPU time, resident-memory size, exit
  code, and restart count; no memory contents are represented.
- Artifact exports use opaque artifact/root identifiers, digest, size, and
  mutation time; no file-content field is represented.
- Network exports use destination identifiers and decisions; no raw URL field
  is represented.
- Privacy contracts explicitly track prohibited fields and raw path, URL, and
  error export flags.
- Strict decoding rejects unknown and duplicate keys.
- Canonical lexical tests pin deterministic signed input.
- Upload acknowledgement distinguishes `accepted` from `idempotent-replay`.
- Host assertion evidence remains separate from server-observed acceptance.
- Only the Go verifier can evaluate trusted local finalized raw events for
  original-chain integrity.

These observations prove P2-PRE delivery confinement and kernel readiness. They
do not claim that the future external host sensor is already Landlock-confined;
that product enforcement remains owned by Phase 4.

No customer file contents, process memory, payload contents, partner endpoint,
or production environment was accessed during this preflight.

## Verification summary

| Command | Result |
| :--- | :--- |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py -v` | 11 passed |
| `pytest .../tests/test_platform_users.py -q` | 33 passed |
| `python3 -m pytest tests/test_tenant_isolation.py -q -o addopts=` | 95 passed |
| `pytest .../test_write_transactions.py -q -o addopts= -k revoking_credentials` | 1 passed |
| `CGO_ENABLED=0 ... go test ./collectors/agentnono` | passed |
| Focused authorization and nginx BATS | 9 passed |
| `make -C d2-signalloom test` | 571 BATS checks; zero failures |
| `make test` | exit 0; eight tests; zero skips |
| `ls -1 d2-signalloom/apps/fe-signalloom/src/db/migrations/` | ordered through `038` |

Warnings were limited to Starlette's `httpx` deprecation notice. Go's default
CGO build could not read sandbox-blocked system headers, so the pure-Go contract
package was verified with `CGO_ENABLED=0`; this changes no tested contract.

Independent pre-commit review found no correctness, tenant-isolation, or scope
violation. It required the two evidence qualifications recorded above: runtime
readiness is not future host enforcement, and the SQL regression is a static
drift guard rather than a PostgreSQL round trip. Roborev was unavailable in the
runtime, so the review used an independent Engineer agent plus ripwire impact
evidence.

## Scope statement

This card changed baseline compatibility, test liveness, and documentation
only. It did not add Phase 2 tables, registration routes, operator behavior,
external credentials, deployment resources, acceptance-registry wiring, or
partner interactions. Integration remains Governor-owned.
