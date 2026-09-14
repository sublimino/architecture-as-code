# SLDP-P2-2 Execution Proof

**Status:** PASS — `tenant_id` added to all three identity tables, row-level security enabled and forced, transaction-local tenant claims with a connection-reset hook, a reason-gated cross-tenant maintenance path, and a 28-test hostile-context suite that runs against a real PostgreSQL server and is falsified by disabling the control.
**Logical ID:** `SLDP-P2-2`
**Role:** Implementation
**Base Commit / Integration Ref:** `6baa5f1c` on `refs/heads/integration/sldp-v0.1.0`
**Runtime Worktree:** `/home/andy/src/.worktrees/72dc8/osramp-demo`
**Recorded Date:** 2026-09-14 15:07:59+01:00

---

## 1. Starting state

Established by inspection before any edit, and consistent with the card's verified facts:

| Fact | Evidence |
|---|---|
| Zero `tenant_id` columns in the identity graph | `001_identity_graph.sql` defines `actors`, `aliases`, `delegations` with no tenant column |
| Zero enforcement anywhere in the repository | `rg -c 'ENABLE ROW LEVEL SECURITY\|CREATE POLICY' d2-signalloom` → 0 matches |
| Seventeen SQL statements in `repository.go`, none tenant-predicated | read in full |
| No test in `identity/` has ever connected to a server | `identity/migration_test.go` asserts on migration *text*; no DSN is read anywhere in the package |

The last row is the one that shaped this card. A control asserted only as a string comparison passes identically whether the policy denies anything or does not exist. Everything below therefore has a live counterpart.

---

## 2. Contract compliance

| Contract | Source | Honoured |
|---|---|---|
| Migration sequence `006` | SLDP-P2-PRE §3.2 | Yes — `006_tenant_isolation_rls.sql`. `005` left free for SLDP-P2-1, which was `in_progress` on the board throughout this card. |
| GUC name `app.current_tenant` | SLDP-P2-PRE §5 / P1-GOV | Yes — `identity.TenantSettingName` and every policy predicate. |
| `ENABLE ROW LEVEL SECURITY` per table | SLDP-P2-PRE §5 | Yes, plus `FORCE`, which §5 does not require and without which the table owner bypasses every policy. |
| `SET LOCAL app.current_tenant` per transaction | SLDP-P2-PRE §5 | Yes — `set_config($1, $2, true)` inside `WithTenant`. |
| Tenant derived from the verified principal, never a header | SLDP-P2-PRE §5.3 | Yes — `api/tenant_bridge.go`; asserted end-to-end through the real `ProtectedRouter`. |
| Single connection pool | `identity/pool_sharing_test.go` | Yes — `PostgresRepository.DB()` still returns the shared `*sql.DB`; that test still passes. |

---

## 3. Deliverables

### D1 — Migration adding `tenant_id` and RLS policies to all three tables

`d2-signalloom/apps/signal-ingest/identity/migrations/006_tenant_isolation_rls.sql`, wired into
`ApplyMigrations` after `004`.

The design decision that carries the rest of the card: **`tenant_id` takes a column DEFAULT of
`app_current_tenant()`**, so none of the seventeen existing SQL statements in `repository.go` were
rewritten. Two consequences follow directly.

- A caller with no claim gets `NULL` from the default and hits the pre-existing `NOT NULL`
  constraint. The write path fails closed using a constraint that already existed.
- A correctly-scoped caller issues byte-identical SQL to what it issued before, which is what makes
  "no silent narrowing" provable rather than asserted.

Four ordered steps, because it cannot be one statement: `ADD COLUMN` nullable → report → backfill →
`SET DEFAULT` → `SET NOT NULL`. `ADD COLUMN ... NOT NULL DEFAULT app_current_tenant()` evaluates its
`STABLE` default once at migration time, when no claim is set, and dies on its own constraint.

Every data-modifying step precedes `ENABLE`/`FORCE ROW LEVEL SECURITY`. `FORCE` binds the table
owner, so a backfill run after enablement would be policy-checked against a claim a migration does
not have. `TestMigration006_DataStepsPrecedeRowLevelSecurity` pins the ordering.

`app_current_tenant()` maps the empty string to `NULL`. This is not defensive tidiness — it was
measured:

```
signalloom=# select set_config('app.current_tenant','tenant-a',false);  -- tenant-a
signalloom=# reset all;
signalloom=# select 'after_reset=[' || coalesce(current_setting('app.current_tenant', true),'<null>') || ']';
after_reset=[]
```

`RESET ALL` restores a custom GUC to the **empty string**, not to `NULL`. Without the `nullif`, a
reset connection would match every row tagged `''`, and an attacker gets that claim for free by
doing nothing. `TestTenantRLS_EmptyClaimIsNotAWildcard` is the live counterpart.

### D2 — Application role is neither table owner nor BYPASSRLS

Asserted twice, deliberately, because the two answer different questions. The migration pins
`ALTER ROLE signal_identity_app NOSUPERUSER NOBYPASSRLS` — what was requested once. `identity.
AssertTenantIsolationPosture` reads `pg_roles` and `pg_class` at runtime — what is true now. A later
`ALTER ROLE ... BYPASSRLS`, a table restored from a dump without its policies, or an application
connecting as the owner would all leave the SQL file unchanged and the control gone.

Live output, connected as `signal_identity_app`:

```
posture: user=signal_identity_app super=false bypass=false policies=6
```

The assertion is shown to be able to fail, against the superuser pool:

```
identity: tenant isolation posture assertion failed: role "postgres" is SUPERUSER and ignores
row-level security; role "postgres" has BYPASSRLS and ignores row-level security
```

LOGIN is deliberately **not** granted by the migration. Which role the application authenticates as,
and with what credential, is deployment configuration; a migration that hands out a login creates a
credential nobody rotates. The test harness grants it, which is the honest place for it.

### D3 — Transaction-local claim plumbing with a pool-reset hook

`identity.WithTenant` leases a dedicated `*sql.Conn`, opens a transaction on it, sets the claim with
`set_config(..., is_local => true)`, and hands the callback a scoped `*PostgresRepository` whose
statements run on that transaction. Three distinct failures are each addressed:

| Failure | Mechanism |
|---|---|
| Claim outlives the work | `is_local => true` — PostgreSQL discards it at COMMIT or ROLLBACK without being asked |
| Claim lands on a different connection than the query | the work runs on a leased connection, not on `*sql.DB` |
| Claim set at session scope by code that bypasses `WithTenant` | `RESET ALL` on release, under `context.WithoutCancel` so it still runs when the caller's context was cancelled |

The third is the one the hook exists for, and it has a dedicated test —
`TestTenantRLS_ResetHookClearsASessionLevelClaimLeftByOtherCode` sets a session-scoped claim on a
pooled connection, confirms it takes effect, then takes the same connection through `WithTenant` and
asserts the leftover is gone. `SET LOCAL` alone would not clear it; that test is the only thing in
the suite that would notice if the hook were deleted.

A connection whose reset fails is marked bad via `conn.Raw` returning `driver.ErrBadConn`, because
`(*sql.Conn).Close` **returns** the connection to the pool rather than discarding it.

Repository churn was kept to the minimum that makes this work: the struct's `db` field became a
three-method `tenantQuerier` with a separate `pool *sql.DB`, and the single `BeginTx` call site in
`RevokeActiveDelegations` became `r.begin(ctx)`, which joins `WithTenant`'s enclosing transaction
rather than opening a second one on a claimless connection. No query text changed.

### D4 — Documented cross-tenant maintenance path

Some operations legitimately cross tenants: resolving the backfill quarantine, investigating a
reported leak, answering a regulator. If there is no sanctioned way to do them they get done as a
superuser, which reintroduces this card's hole under a different name and leaves no trace.

The crossing is explicit on two axes simultaneously:

1. **A distinct role.** The maintenance policies are scoped `TO signal_identity_maintenance`, not to
   `PUBLIC`. A permissive policy is ORed with the tenant policy, so a `PUBLIC`-scoped version would
   hand every application session a cross-tenant read the moment anything set the reason GUC.
2. **A declared reason.** `app.maintenance_reason` must be non-empty, set transaction-locally, or
   the policy denies. A maintenance session that forgets the reason reads zero rows — the failure
   mode of the sanctioned path is the same fail-closed silence as the ordinary path, not an open
   door.

Intended operators: platform engineers holding the `signal_identity_maintenance` credential, which
is separate from the application credential. Three live tests cover it: no reason → 0 rows; with a
reason → 3 distinct tenants visible; and the application role declaring a reason → still 0 rows,
proving the reason GUC is not a universal skeleton key.

### D5 — Hostile-context suite

`identity/tenant_live_test.go`, 28 tests, run via `make test-identity-rls-live` which stands up
`postgres:16-alpine`, runs the suite and tears the container down.

Every confined session authenticates as `signal_identity_app` — non-superuser, non-owner,
`NOBYPASSRLS`. A suite run as the superuser that owns the tables would see every row and could only
ever fail, proving nothing.

| Hostile condition | Test | Observed |
|---|---|---|
| Missing claim, read | `MissingClaimReadsNothing` | 0 rows on all three tables |
| Missing claim, write | `MissingClaimCannotWrite` | `pq: new row violates row-level security policy for table "actors" (42501)` |
| Missing claim, Go layer | `WithTenantRefusesAnUnclaimedContext` | `ErrNoTenantClaim`, callback never runs |
| Forged claim, read | `ForgedClaimCannotReadAnotherTenant` | 0 of tenant A's actors; positive control confirms its own are visible |
| Forged claim, write | `ForgedClaimCannotWriteIntoAnotherTenant` | `pq: new row violates row-level security policy for table "actors" (42501)` |
| Empty-string claim | `EmptyClaimIsNotAWildcard` | 0 rows |
| Stale claim after reuse | `StaleClaimDoesNotSurviveConnectionReuse` | 0 rows and an empty GUC on the same physical connection (`SetMaxOpenConns(1)`) |
| Stale session-scoped claim | `ResetHookClearsASessionLevelClaimLeftByOtherCode` | leftover cleared |
| Stale claim after an error | `ResetHookRunsAfterAFailedCallback` | 0 rows |
| Shared alias value across tenants | `RepositoryQueriesAreConfined` | `FindAliasesAsOf` on a value held by **both** tenants returns exactly 1 row, the caller's |

**The falsification test is what makes the rest mean anything.** "A session claiming tenant B sees
none of tenant A's rows" is also satisfied by an empty table, a mistyped predicate, or a policy that
denies everything including the caller's own. `TestTenantRLS_Falsification` therefore disables
row-level security, re-runs the central probe, asserts the leak **appears**, restores enforcement,
and re-probes:

```
falsified correctly: 1 cross-tenant rows visible with RLS off, 0 with it on
```

The skip path is deliberately asymmetric. With `IDENTITY_TEST_DATABASE_URL` unset the suite skips
with a message saying what is being given up. With it **set but unusable** the suite `Fatal`s:

```
IDENTITY_TEST_DATABASE_URL is set but the server is unreachable
(dial tcp 127.0.0.1:1: connect: connection refused). Refusing to skip.
```

A configured-but-broken database must fail, not vanish. A check that never ran is otherwise
indistinguishable from a check that passed.

### D6 — Tenant source agrees with the P1-1 principal binding

`api/tenant_bridge.go` is the single point of conversion. It lives in `api` because `api` already
imports `identity` and the reverse would not build — a constraint that turns out to be the right
shape, since `identity` then has no way to reach an HTTP request and no code path in the repository
layer could read a tenant from one even by accident.

The bridge reads only the `TenantContext` that `ProtectedRouter.authorize` installs from the
verified principal, and copies both fields verbatim. It refuses rather than defaults on: no tenant
context, an empty tenant, an empty principal, and the reserved quarantine tenant.

`TestTenantBridge_DerivedClaimMatchesTheAuthenticatedPrincipalEndToEnd` drives the real
`ProtectedRouter` with `X-Tenant-ID: tenant-attacker` and `X-Tenant: tenant-attacker` set, and
asserts the derived claim is the principal's `tenant-a` and the subject is the principal's subject.
The header changes nothing because nothing in the chain reads the request at all.

### D7 — Query plans before and after the composite index

This produced a **finding that contradicts the card's framing**, and it is reported rather than
engineered around.

The single hottest statement in `repository.go` is the `alias_value` lookup in `FindAliasesAsOf`.
Under row-level security its plan is:

```
Index Scan using idx_aliases_value_temporal on aliases
  Index Cond: (((alias_value)::text = 'bulk-4242@example.test'::text) AND (valid_from <= now()))
  Filter: (((valid_to IS NULL) OR (now() < valid_to)) AND ((tenant_id)::text = NULLIF(current_setting('app.current_tenant'::text, true), ''::text)))
```

The planner keeps the **pre-existing** `alias_value`-leading index and applies the tenant predicate
as a filter on the one row it finds. It is right to: `alias_value` is near-unique, while `tenant_id`
has a handful of distinct values, so a tenant-leading index would begin the scan on the least
selective column. Asserting that a tenant-leading index is used here would mean forcing a worse
plan to satisfy a criterion. `TestTenantRLS_HighSelectivityLookupKeepsItsExistingPlan` asserts what
actually matters for the 2.75 ms budget instead: still an index scan, not a sequential one, and the
tenant predicate present in the plan.

The tenant-leading indexes earn their place on the path where the tenant predicate is the *only*
thing narrowing the scan — a tenant-scoped enumeration. Measured over a 12,000-row corpus with a
realistic size skew (two large tenants, one small), before and after produced by dropping and
recreating the indexes rather than by recalling what used to happen:

**BEFORE** (tenant-leading indexes dropped):

```
Aggregate
  ->  Seq Scan on aliases
        Filter: ((valid_from <= now()) AND ((valid_to IS NULL) OR (now() < valid_to)) AND ((tenant_id)::text = NULLIF(current_setting('app.current_tenant'::text, true), ''::text)))
```

**AFTER**:

```
Aggregate
  ->  Bitmap Heap Scan on aliases
        Recheck Cond: (((tenant_id)::text = NULLIF(current_setting('app.current_tenant'::text, true), ''::text)) AND (valid_from <= now()))
        Filter: ((valid_to IS NULL) OR (now() < valid_to))
        ->  Bitmap Index Scan on idx_aliases_tenant_actor_temporal
              Index Cond: (((tenant_id)::text = NULLIF(current_setting('app.current_tenant'::text, true), ''::text)) AND (valid_from <= now()))
```

Sequential scan → bitmap index scan. Six tenant-leading indexes were added
(`idx_actors_tenant_actor`, `idx_aliases_tenant_{actor,value,hash}_temporal`,
`idx_delegations_tenant_{delegate,principal}_temporal`).

**Latency budget:** the 2.75 ms p95 at 12,000 observations figure belongs to Signal Fusion query
latency, which this card did not re-measure end to end. What was measured is that the hottest
identity lookup retains an index scan and that the enumeration path improved from a sequential scan.
A p95 re-measurement against the fusion path is left to SLDP-P2-GOV; this is stated rather than
implied.

### D8 — Backfill report

Rows that predate this migration cannot have their tenant determined — there was no column to
determine it from, and no other column in any of the three tables carries tenant attribution. They
are assigned `__unattributed__`, a reserved identifier no principal binding maps to, rather than a
live tenant. **Assigning indeterminate rows to a real tenant merges two estates invisibly and is not
reversible**, because the original attribution is gone the moment it is overwritten.

`identity_tenant_backfill_report` records one row per quarantined row, written *before* the
`UPDATE` — afterwards there is no way to tell which rows it should have named. Live output from a
run seeded with four pre-tenancy rows:

```
actors      row_key=legacy-actor-predating-tenancy  tenant=__unattributed__  reason=row predates 006_tenant_isolation_rls.sql; no tenant column existed at insert time, and no other column in actors carries tenant attribution
actors      row_key=legacy-principal                tenant=__unattributed__  reason=row predates 006_tenant_isolation_rls.sql; no tenant column existed at insert time, and no other column in actors carries tenant attribution
aliases     row_key=1                               tenant=__unattributed__  reason=row predates 006_tenant_isolation_rls.sql; tenant is not derivable from actor_id because actors was itself unattributed
delegations row_key=1                               tenant=__unattributed__  reason=row predates 006_tenant_isolation_rls.sql; tenant is not derivable from delegate_actor_id or principal_actor_id because actors was itself unattributed
```

The quarantine tenant is unreachable through the ordinary path on two layers: `NewTenantClaim`
refuses it, and no principal binding maps to it. Only a reason-bearing maintenance session can see
those rows. Re-running the migration does not duplicate report rows
(`TestTenantRLS_MigrationIsIdempotentAndDoesNotDuplicateTheReport`).

---

## 4. The referential-integrity existence oracle — found, measured, closed

This was not in the card's failure-modes list and is the substantive discovery of this work.

PostgreSQL runs foreign-key checks **as the table owner with row security bypassed**, by design —
otherwise a policy could silently break a constraint. Measured on PostgreSQL 16.14 as
`signal_identity_app` with claim `t-b`, against tenant A's actor `p`:

```
INSERT INTO delegations (..., principal_actor_id = 'p', ...)
  -> SUCCEEDED
INSERT INTO delegations (..., principal_actor_id = 'does-not-exist-anywhere', ...)
  -> ERROR: insert or update on table "delegations" violates foreign key constraint
     "delegations_principal_actor_id_fkey"
     DETAIL: Key is not present in table "actors".
```

Two distinguishable answers to "does this identifier exist somewhere in the estate", from a session
that can read neither. That is an enumeration oracle over every tenant's actor identifiers, and
`aliases.actor_id` has the same shape. It would have survived every policy in this migration.

**The structural fix** is a composite key — `actors (tenant_id, actor_id)` — so the foreign key is
itself tenant-scoped. That breaks every foreign key and every query in `repository.go` and collides
with SLDP-P2-1's in-flight alias work, so it is out of scope here and handed to SLDP-P2-GOV.

**What is in scope** is making the two outcomes indistinguishable. Section 7 of the migration adds
`check_tenant_scoped_actor_reference()` as a `BEFORE INSERT OR UPDATE ROW` trigger on `aliases` and
`delegations`. `BEFORE ROW` triggers run before referential-integrity checks, and the trigger's
subquery *is* subject to row-level security, so it sees only the caller's tenant. Both cases now
raise the same message with the same SQLSTATE:

```
both refused identically: "pq: referenced actor X does not exist (23503)"
```

`TestTenantRLS_ForeignKeyIsNotACrossTenantExistenceOracle` asserts the two refusals are identical
**and** carries a positive control — a legitimate same-tenant delegation must still be accepted.
Without that control, "both are refused" is equally satisfied by a trigger that refuses everything,
which is a broken product rather than a closed oracle.

---

## 4a. Advisor-driven hardening — one further hole, five decay guards

A commitment-boundary advisor pass over the finished design surfaced one genuine gap and a set of
ways the controls decay silently. All are now closed and tested.

**The gap, and it was real.** `NewTenantClaim` refuses to construct a claim naming the quarantine
tenant — but the database cannot tell a claim that arrived through `NewTenantClaim` from one set
directly with `set_config`. Anything reaching the connection could have set
`app.current_tenant = '__unattributed__'` and read every row the backfill quarantined. The tenant
policies now carry `AND tenant_id <> identity_quarantine_tenant()` on both `USING` and `WITH CHECK`,
so the quarantine is reachable only through the maintenance policy — a different role plus a
declared reason. `TestTenantRLS_ForgedQuarantineClaimReadsNothing` proves it, and carries a positive
control through a maintenance session confirming those rows do exist, so the zeros are not just an
empty backfill.

The remaining five are guards against silent decay. Each is **derived from the catalogue** rather
than checked against a hand-written list, because a hand-written list is a copy of the source of
truth and drifts from it with nothing going red.

| Guard | What it would catch |
|---|---|
| `AppRoleCannotAssumeTheMaintenanceRole` | Role membership, or any other `SET ROLE` route, collapsing the maintenance gate's first axis to nothing — the reason GUC would degrade from a control into a comment |
| `ClaimAccessorsAreStableNotImmutable` | `app_current_tenant()` marked `IMMUTABLE` (tempting, since it would allow the function in an index expression). The planner constant-folds an `IMMUTABLE` function into a cached generic plan, so a pooled connection serves the baked-in tenant to whoever holds it next — a total bypass |
| `EveryForeignKeyIntoActorsHasATenantScopedTrigger` | A new table referencing `actors`, reopening §4's oracle. Derived from `pg_constraint`; currently reports `[aliases delegations]` |
| `NoViewBypassesThePoliciesOnTheIdentityTables` | A view without `security_invoker=true` (evaluates policies as its owner) or any materialised view (RLS is not applied to matview contents at all — the refresh runs as owner and the result is an ordinary unfiltered table) |
| `AppRoleHoldsNoTruncateOrReferencesPrivilege` | `TRUNCATE`, which no policy covers, and `REFERENCES`, which would let the app role create the very foreign keys §4's trigger exists to constrain |

Two of the advisor's points were considered and **not** acted on, for stated reasons. Replacing
`RESET ALL` with `DISCARD ALL` would also drop prepared statements, which `database/sql` caches per
connection, turning the next reuse into an error; the advisor's stronger suggestion — set-on-acquire
rather than reset-on-release — is already the design, since `WithTenant` sets the claim
unconditionally at the start of every transaction and `RESET ALL` is only a backstop for code that
bypasses it. Per-control falsification (drop `FORCE`, drop `WITH CHECK`, and confirm exactly one
named test goes red for each) is a genuine improvement over one global falsification test and is
**not** done here; it is recorded as residual 6 below.

---

## 5. Residual risks carried to SLDP-P2-GOV

Stated because they are real, not because they were reached and abandoned.

1. **Primary-key collision oracle — OPEN.** `actors.actor_id` is a global primary key. A session
   claiming tenant B inserting an `actor_id` owned by tenant A receives
   `ERROR: duplicate key value violates unique constraint "actors_pkey"` — measured. This discloses
   existence of an identifier, not its content. It is the same root cause as §4 and is closed by the
   same composite-key change. The section-7 trigger does **not** cover it, because a primary-key
   conflict on `actors` happens before any reference is made.
2. **Never-merge invariant is now tenant-scoped.** `check_never_merge_alias()` and
   `check_never_merge_delegation()` are `SECURITY INVOKER`, so their `EXISTS` subqueries see only
   the caller's tenant. Measured: the invariant still raises within a tenant. Across tenants it
   cannot see the other side and would not raise — which the section-7 trigger now makes largely
   unreachable for `delegations`, since both endpoints must be same-tenant. The residual case is a
   **quarantined** row: a `__unattributed__` delegation is invisible to a tenant session, so a
   never-merge violation spanning the quarantine boundary would not be detected. This belongs to
   SLDP-P2-3, which owns never-merge pinning, and is handed over explicitly.
3. **Latency not re-measured against the fusion path.** See D7.
4. **`signal_audit_trail` has no row-level security.** It carries `tenant_id` already. Out of scope
   for a card that names the three identity tables; worth a decision at P2-GOV.
6. **Falsification is global, not per-control.** `TestTenantRLS_Falsification` disables row-level
   security and confirms the leak appears, which proves RLS is load-bearing. It does not prove each
   *individual* control is. The stronger harness — drop `FORCE`, drop a `WITH CHECK`, mark the
   accessor `IMMUTABLE`, and assert that exactly one named test goes red for each — is the right
   next step and is not done here. Raised by the advisor pass; recorded rather than quietly skipped.
7. **Application-level caches keyed by the global `actor_id`.** None exist in `identity/` today
   (`memory.go` is a test double). Any future in-process cache keyed on the global identifier would
   serve tenant A's data to tenant B with no database involvement, and row-level security cannot
   see it.
8. **Pre-existing `gofmt` finding in `repository.go`.** `gofmt -l` flags a trailing blank line at
   end of file. Verified pre-existing via `git show HEAD:...repository.go | gofmt -l` — it flags the
   HEAD version too. Left untouched deliberately: fixing it would add a diff hunk unrelated to this
   card while SLDP-P2-1 is editing the same file.

---

## 6. Test execution evidence

| Gate | Command | Result |
|---|---|---|
| Isolated runtime | `pwd` | `/home/andy/src/.worktrees/72dc8/osramp-demo` — not the principal checkout |
| Integration lineage | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | exit 0 |
| Hostile-context suite | `make test-identity-rls-live` | **28/28 PASS**, exit 0, PostgreSQL 16.14 |
| Identity package, no database | `go test ./identity/...` | **ok**; every live test skips loudly, the text and unit tests all pass |
| Configured-but-broken DSN | `IDENTITY_TEST_DATABASE_URL=<unreachable> go test ./identity/...` | **FAIL** — refuses to skip, as designed |
| Full ingest suite | `make test-signal-ingest` | exit 0, 822 PASS lines |
| API bridge | `go test ./api/... -run TestTenantBridge` | 5/5 PASS |
| Vet | `go vet ./identity/... ./api/...` | clean |
| Vacuous-assertion oracle | `scripts/check-vacuous-assertions.sh` | 30 findings — **30 at HEAD baseline too**, none naming a file from this card |
| Acceptance spec coverage | `bats test/acceptance-spec-coverage.bats` | 7/7 PASS |

The vacuous-assertion baseline was established by extracting HEAD with `git archive` into a scratch
directory and running the same script there, rather than by comparing against a remembered number.

---

## 7. Files

**Added**

- `d2-signalloom/apps/signal-ingest/identity/migrations/006_tenant_isolation_rls.sql`
- `d2-signalloom/apps/signal-ingest/identity/tenant.go`
- `d2-signalloom/apps/signal-ingest/identity/tenant_test.go`
- `d2-signalloom/apps/signal-ingest/identity/tenant_live_test.go`
- `d2-signalloom/apps/signal-ingest/api/tenant_bridge.go`
- `d2-signalloom/apps/signal-ingest/api/tenant_bridge_test.go`
- `docs/signalloom/sldp-p2-2-proof.md`

**Modified**

- `d2-signalloom/apps/signal-ingest/identity/migrations.go` — `006` embedded and executed after `004`, append-only
- `d2-signalloom/apps/signal-ingest/identity/repository.go` — struct field type, constructor, `DB()`, one `BeginTx` call site
- `Makefile` — `test-identity-rls-live`

**Deliberately untouched** — `005_*.sql` (reserved for SLDP-P2-1), `migration_test.go`, and every
existing query body in `repository.go`.

---

## 8. Verdict

**SLDP-P2-2 is COMPLETE and PASSING.** Tenant isolation on the identity graph is enforced by
PostgreSQL rather than assumed by the application, the enforcement is proven against a real server
by a suite that is demonstrably able to observe its absence, and three residual risks are named with
their root cause and their owner rather than left for P2-GOV to rediscover.
