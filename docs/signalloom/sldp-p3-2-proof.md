# SLDP-P3-2 Execution Proof

**Status:** PASS — erasure is gated by an Article 17(3) legal hold that fails closed, overridable only by a dual-operator Ed25519-signed, time-bounded retention exception naming an enumerated ground; the hold check provably precedes any key operation; every refusal is recorded; 23/23 controls proven failable by real-source mutation with every kill confirmed by an observed `--- FAIL`. Adversarial review found two CRITICAL and one HIGH defect after the suite was already green; all are fixed and regression-tested, and §14 records them because they are the most useful output of this card.
**Logical ID:** `SLDP-P3-2`
**Role:** Implementation
**Base Commit:** `9bd11bcd` (ancestor of `integration/sldp-v0.1.0` at `9ba2e83c`)
**Integration Branch:** `refs/heads/integration/sldp-v0.1.0`
**Runtime Worktree:** `/home/andy/src/.worktrees/96d0f/osramp-demo`
**Recorded Date:** 2026-09-14 16:40:00+01:00

---

## 1. What this card built, and what it deliberately did not

Erasure in a cryptographically-attested evidence store is not only a privacy control. It is an
**evidence-destruction primitive**: crypto-shredding a subject's key destroys forensic attribution
for every action that subject took. A compromised or coerced operator can therefore invoke GDPR
Article 17 against an actor tied to a live incident and delete that incident's attribution chain —
simultaneously a privacy-shaped action and a DORA Article 11 operational-resilience breach.

This card built the **gate**, not the mechanism, and deliberately built it *before* the mechanism so
that no commit exists in which unconstrained on-demand crypto-shredding is reachable. Per-subject key
hierarchy and the erasure saga remain SLDP-P4-1; non-linkable tombstones SLDP-P4-2; the retention
controller SLDP-P6-1.

New package `d2-signalloom/apps/signal-ingest/privacy/` (9 source files, 6 test files), one HTTP
route, one permission, migration 008, and a mutation-proof harness.

## 2. Pre-execution gates

| Gate | Finding |
|---|---|
| Worktree | `/home/andy/.cline/worktrees/96d0f/osramp-demo` → `/home/andy/src/.worktrees/96d0f/osramp-demo`; NOT the principal checkout |
| Base ref | `git merge-base --is-ancestor HEAD integration/sldp-v0.1.0` → rc=0. Branch advanced one docs-only commit (`9ba2e83c`, governor tick #73) after this worktree was created; benign, recorded in errata |
| Concurrency | Board read once, read-only. Sibling `SLDP-P3-1` in_progress on `store/frostdb.go`, which this card does not touch |
| Migration sequence | 007 is the next free number; claimed and recorded |
| Baseline suite | Green before any edit — mutations are attributable |

### Two card "verified facts" were stale and were not relied upon

The card's fact sheet states signal-ingest has no HTTP authentication and that zero RLS exists. Both
were closed by P1 and P2 before this card ran:

- `api.NewProtectedRouter` / `api.NewJWTAuthenticator` exist (`api/auth.go:329`); `main.go` refuses
  startup on invalid auth configuration. The new erasure route is registered through that boundary.
- `identity/migrations/006_tenant_isolation_rls.sql` enables and **forces** row-level security.
  Migration 008 follows that pattern rather than reinventing it.

## 3. The control

A subject linked to an unresolved security incident or an active containment record may not be
erased; neither may one whose incident state cannot be determined. The only way past a hold is a
retention exception signed by at least two **distinct**, registry-bounded operators, **neither of
whom is the requester**, naming one of exactly five enumerated Article 17(3) grounds, carrying an
expiry no more than 90 days after issue and a review date no later than the expiry.

### A hold is a proof obligation, not an authorisation check

This reframing is what shaped the API, and it is the reason the design is not merely "add a check".
An authorisation failure is recoverable — retry with better credentials. A hold asks the destroyer
to positively demonstrate that **no hold exists**, and "I could not find one" is not a
demonstration. Three consequences, each load-bearing:

- `IncidentSource.ActiveHolds` returns a **three-valued** answer (`determined` / `declined` /
  `undetermined`), not `([]Hold, error)`. Absence, no-jurisdiction and failure are different facts.
- `CompositeIncidentSource` refuses if **any** constituent errors, and also if **no** constituent had
  jurisdiction. A union from a partial view is not a union.
- No constructor yields a `Service` with a permissive default incident source.

### Why "fail closed" was under-specified, and which direction was chosen

Every other control in this service is monotone — refusing is always safe. Erasure is **not**.
Erasing under a hold destroys irrecoverable incident evidence (DORA Art. 11); refusing a legitimate
erasure breaches GDPR Art. 17, and falsely reporting an erasure is a misstatement to a regulator. The
safe defaults point in **opposite directions**, so the architectural constitution's "controls fail
closed" does not by itself determine the answer here.

**Chosen direction: REFUSE.** Article 17 breaches are remediable — the subject re-submits and the
lateness is visible. Evidence destroyed during a live incident is not remediable by anything.
Refusal also fails loudly (409 naming the hold); wrongful erasure fails silently. Recorded in
`privacy/doc.go` rather than assumed, because the opposite choice is defensible on Art. 17 grounds
alone.

## 4. Deliverables against evidence

| # | Deliverable | Where | Evidence |
|---|---|---|---|
| D1 | Legal-hold evaluation failing closed on unavailable incident state | `privacy/erasure.go` phase 2 | `TestErasureHold_UnavailableIncidentStateRefuses`, mutation case 01 |
| D2 | Dual-operator signed override recording both identities | `privacy/exception.go` | `TestOverrideRequiresTwoDistinctOperators`, cases 06–09 |
| D3 | Signed, expiring exception naming an enumerated ground | `privacy/exception.go`, `privacy/grounds.go` | `TestRetentionExceptionMustBeTimeBounded`, cases 10–13 |
| D4 | Abuse-case test: contained actor refused | `privacy/erasure_test.go` | `TestErasureHold_ContainedActorErasureIsRefused` (§5) |
| D5 | Documented hold-vs-retention-expiry precedence | `privacy/doc.go`, `privacy/retention.go`, §6 below | `TestRetentionPrecedenceTruthTable`, case 20 |
| D6 | Errata noting erasure is an evidence-destruction primitive | Proposal Appendix Errata | Errata block for SLDP-P3-2 |
| D7 | Bounded, recorded operator set | `privacy/operator.go` (`MaxOperators = 32`) | `TestOperatorRegistryIsBounded`, cases 14–15 |
| D8 | Behaviour when a hold expires while a request is pending | `privacy/doc.go`, `MaxRequestAge` | `TestErasureHold_HoldIsEvaluatedAtDecisionTimeNotRequestTime`, cases 16–17 |
| D9 | Refusal logging with reason and ground | `privacy/erasure.go` `refuse()` / `writeDecision()` | §5.2, case 19 |
| D10 | Ordering: hold check precedes any key operation | `privacy/erasure.go` phases 2→5 | §5.3, observed call sequence |
| D11 | Proof document | this file | — |
| D12 | Commit, errata, Result column | see errata | — |

## 5. Required evidence, captured

### 5.1 Abuse case — erasure of an actor under active containment is refused

`TestErasureHold_ContainedActorErasureIsRefused` drives a real `privacy.Service` whose
`KeyDestroyer` is a **tripwire** that fails the test if it is called at all.

```
$ go test ./privacy/ -run 'TestErasureHold_ContainedActor' -count=1 -v
=== RUN   TestErasureHold_ContainedActorErasureIsRefused
--- PASS: TestErasureHold_ContainedActorErasureIsRefused (0.00s)
=== RUN   TestErasureHold_ContainedActorRefusalIsDiscoverable
--- PASS: TestErasureHold_ContainedActorRefusalIsDiscoverable (0.00s)
PASS
```

The HTTP half (`api/erasure_test.go:TestErasureRouteRefusesContainedActorWith409`) drives the
**production `ProtectedRouter`**, not the handler directly — a gate reachable only by an
unregistered route is not a gate, and calling the handler directly would pass in that broken world.

### 5.2 Refusal log showing the reason and the enumerated legal ground

Literal stderr from the run above:

```
WARN erasure refused request_id=req-001 tenant_id=tenant-a outcome=refused_legal_hold
     hold_ids=[quarantine:spiffe://signalloom.test/ns/default/sa/compromised-agent]
     required_ground=art17_3_e_legal_claims
     reason="erasure refused: subject is under an active Article 17(3) legal hold:
             1 active hold(s): [quarantine:spiffe://...compromised-agent]"
```

The matching audit row carries `category`, `outcome`, `reason`, `hold_ids`, `required_ground`,
`required_ground_description`, `subject_pseudonym` and `trace`. The **cleartext subject is absent**
and asserted absent from the whole serialised detail — an audit trail of refused erasures is a list
of the exact identifiers people asked to have removed, so storing them in the clear would turn the
transparency mechanism into a re-identification corpus.

### 5.3 Ordering — the hold check precedes any key operation

Two independent witnesses, because one of them is not sufficient:

1. **Observed call sequence.** A `sequenceRecorder` is shared between the fake incident source and
   the fake key destroyer, so the test observes the order in which the doubles were *called*.
2. **`Decision.Trace`**, populated by the production code.

Witness 2 alone would be circular: asserting that a trace field exists proves the code *says* the
phases ran in order, not that they did. Witness 1 is what makes the claim real. `Decision.Trace` on a
permitted erasure:

```
[validate_request, evaluate_legal_hold, write_audit, destroy_subject_keys]
```

`index(evaluate_legal_hold) < index(write_audit) < index(destroy_subject_keys)`. On every refusal
path `destroy_subject_keys` is **absent**, and the tripwire destroyer records zero calls.

The audit write also precedes destruction, so an unrecorded destruction is unreachable: if the audit
backend is down the erasure is refused, because "destroyed but not recorded" is strictly worse than
"not destroyed".

## 6. Precedence: legal hold beats retention expiry

|  | no active hold | active hold |
|---|---|---|
| **within retention period** | not due, not deletable | not due, not deletable |
| **past retention period** | due **and** deletable | due but **NOT** deletable |

Retention expiry is a *schedule*; a hold is a *fact about the world*. A schedule that silently
overrides a fact is a fail-open path with a calendar attached. `RetentionDecision` keeps `Due` and
`Deletable` as separate fields precisely so a caller cannot collapse them — an operator must be able
to see "this should have gone six weeks ago, and here is what is stopping it". Retention evaluation
fails closed on unavailable incident state for the same reason erasure does.

## 7. Behaviour when a hold expires while a request is pending

A genuine policy choice, stated rather than assumed. Holds are evaluated against the **decision-time**
clock, never the request-time clock. A refused request is **terminal**: it does not queue and does not
auto-execute when the hold lapses. Requests older than `MaxRequestAge` (7 days) are refused with
`ErrRequestStale`.

The rejected alternative — holding the request open and acting the moment the hold clears — destroys
data with no fresh operator in the loop, against an incident picture nobody re-examined.

## 8. Mutation proof — every control observed failing

A green suite is not evidence that the suite asserts anything. `test/erasure-legal-hold-mutation-proof.sh`
removes each control from the **real source file**, requires the named test to go red, restores, and
requires green again.

```
══ result ═════════════════════════════════════════════════════════════
controls proven failable: 23
controls NOT proven:      0
VERDICT: PASS — every mutated control was caught by its named test
```

Harness defences, each against a failure this repository has actually suffered:

- `go test -run <pattern>` matching **zero** tests exits 0. Every case asserts its pattern selects
  ≥1 test **before** mutating, so a typo cannot read as "mutation survived".
- A `perl` substitution matching nothing is a silent no-op. Every case asserts the file's checksum
  changed.
- A killed harness leaves the tree mutated. An EXIT/INT/TERM trap restores every target, and the run
  ends by verifying each file's SHA-256 matches its pre-run value — reported as
  `every mutated file restored byte-for-byte`.
- Backups are keyed by a short **label**, not basename: three packages here contain an `erasure.go`.
- The suite must be green before mutating, or a pre-existing failure wears the mutation's clothes.

### What the first run found, which is the point of running it

The first pass reported **5 survivors**, and every one was the same shape: defence in depth. Removing
one guard left an overlapping guard catching the violation, so the case read "survived" while the
property was in fact enforced. Two corrections followed, and both are genuine improvements rather
than harness cosmetics:

- **A real missing assertion.** `TestErasureHold_UnavailableIncidentStateRefuses` did not
  distinguish an incident-source **outage** from a **no-jurisdiction misconfiguration**. Deleting the
  error-handling arm let control fall through to the jurisdiction check, which refused for the wrong
  reason — and would have sent an operator to fix a configuration problem that did not exist. An
  explicit `!errors.Is(err, ErrNoJurisdiction)` assertion was added.
- **Compound mutations where the claim is behavioural.** "An override with no expiry is refused" is
  enforced by *three* independent checks (`IsZero`, expiry-after-issue, and the freshness
  comparison). Proving that property requires removing all three; removing two still left the third
  catching it. Cases 06, 11, 15 and 21 are compound for this reason, and each says so in the harness.

## 9. Test execution

| Command | Result |
|---|---|
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **21 packages ok, 0 FAIL** |
| `go test -race ./privacy/` | clean |
| `make test-signal-ingest` | **1020 PASS / 0 FAIL / 34 SKIP**, rc=0 |
| `go test -run TestErasureHold ./...` | **29 tests selected and run** (non-zero — a zero-match run would exit 0 and prove nothing) |
| `make demo-signalloom-api-test TIER=contract` | **56 passed**, rc=0 |
| `go vet ./...` | clean |
| `gofmt -l` on new files | clean |
| `rg -n 'legal.?hold\|dual.?operator' d2-signalloom/apps/signal-ingest` | 17 files |
| `test/erasure-legal-hold-mutation-proof.sh` | **23/23 killed, 0 survivors** |
| `scripts/check-vacuous-assertions.sh` | **0 findings in any file this card touched** (30 pre-existing findings elsewhere, in files not touched here) |

All 34 skips are pre-existing live-Postgres suites gated on `IDENTITY_TEST_DATABASE_URL` /
`ALIAS_PG_DSN` (SLDP-P2-1 and P2-2). **The `privacy` package reports 125 test results and zero
skips** — no test added by this card is silently skipped.

## 10. Migration 008 — one table, deliberately

`identity/migrations/008_retention_legal_holds.sql` creates exactly one table,
`retention_legal_holds`, plus its index and its FORCE-RLS policy. Additive only; no existing table's
data or definition is touched and no attested segment bytes are rewritten.

Why a migration at all, when the gate is pure Go: **an in-memory hold register releases every hold on
process restart.** That is the fail-open defect with extra steps, and a restart during an incident is
both when a hold is load-bearing and when restarts happen. `privacy/postgres.go` reads the table, so
the schema has a reader.

**Two tables were removed after review, and the reason belongs here rather than in a changelog.**
The first draft also created `retention_exceptions` and `erasure_decisions`, whose CHECK constraints
the SQL described as "a database backstop against a row arriving by a path that bypasses the Go
validation". Nothing in the Go tree wrote either table. Every constraint on them was unreachable
through the application, and a reader would have cited defence in depth that did not exist. They were
deleted rather than caveated — shipping unreachable constraints is worse than not having them.

Retention exceptions remain fully modelled and validated in Go; they are carried in the request and
bound to one request ID, so they are not long-lived state. Decisions go to the tamper-evident
`signal_audit_trail`. Persisting either belongs to SLDP-P6-1.

**The consequence is recorded rather than absorbed:** the Article 17(3) enumeration is now enforced
in one place, `privacy.LegalGround.Valid`, with no database backstop behind it. The cross-artifact
test that compared the Go enumeration against the SQL CHECK was removed, and a comment stands in its
place in `grounds_test.go` saying so, so nobody re-adds it without reading why. When P6-1 persists
exceptions, the constraint and that guard should return together.

## 11. Wiring — the gate has callers

A gate nothing calls is decoration. `main.go:buildErasureGate` assembles the service from whatever
incident sources the deployment has and wires it into `api.Handlers.Privacy`; the route is registered
in `routeDefinitions` and appears in `ProtectedRouter.Inventory()`, which
`TestErasureRouteIsRegisteredAndPermissionGated` asserts.

Three wiring decisions worth recording:

- **Startup is not refused when the gate cannot be built.** Every existing deployment predates this
  card and has no `SIGNAL_ERASURE_OPERATORS`; exiting would turn a new optional route into an
  estate-wide boot failure. A nil gate makes the route answer **503** — no gate, no erasure.
- **`PermissionErasureRequest` is its own permission**, not folded into `PermissionActorWrite`, so
  the set of principals who may destroy attribution is narrowable independently of those who may edit
  an actor. The route is actor-scoped and the subject is read from the **path**, so the router's
  scope check and the subject actually erased cannot disagree.
- **`UnimplementedKeyDestroyer` refuses.** Until SLDP-P4-1 ships, an authorised erasure fails loudly.
  A stub returning a plausible receipt was considered and rejected: it would make every gate above it
  appear to work end to end while destroying nothing, so the first genuine erasure would be reported
  complete to a data subject and to a regulator without having happened. There is **no development
  opt-in** anywhere in this package — asserted statically by
  `TestErasureHold_NoDevelopmentOptInRelaxesAnyGate`, which requires exactly one `os.Getenv` call in
  the whole package and requires it to be the operator registry.

## 12. Open boundaries and assumptions — recorded, not assumed away

These are stated because a prerequisite left them open, and the phase Governor should weigh them.

1. **Identifier-space crossing (for SLDP-P4-1).** `Hold.SubjectID` is in the **cleartext actor-ID**
   space, matching `ErasureRequest.SubjectID` and the quarantine engine's keys. It is *not* in the
   `(tenant, epoch)`-bound HMAC pseudonym space the persisted graph uses. This is deliberate:
   SLDP-P2-1 measured that an epoch rotation silently turns pseudonym-space exact-equality
   comparisons into no-ops, so comparing in cleartext space makes hold matching rotation-immune. The
   cost is that the crossing is **deferred, not solved** — P4-1 must decide how a hold on a cleartext
   actor ID maps onto the epoch-bound keys it destroys. Pinned in `hold.go`'s `SubjectID` doc.
2. **Quarantine is not tenant-aware.** The correlation engine is a single in-process map keyed by
   actor ID, so `QuarantineIncidentSource` is bound to one tenant via `SIGNAL_ERASURE_TENANT` and
   **declines** every other. A multi-tenant deployment must configure the Postgres hold source, which
   is authoritative for all tenants. A tenant-aware quarantine index belongs to whichever card makes
   the correlation engine multi-tenant.
3. **Postgres hold source is schema- and code-verified, not live-verified here.** It follows the
   established DSN-gated pattern (`identity/alias_pg_live_test.go`); no live database was available
   in this run.
4. **Recommendation for SLDP-P5-1 (out of scope here, raised deliberately).** The strongest available
   hardening is to make bypass *impossible* rather than *forbidden*: hold no key-destruction
   permission in the erasure executor at all, and have KMS/HSM policy authorise destruction only
   against a dual-signed exception record. Bypassing the gate then stops being a silent code path and
   becomes a loud, audited IAM change. The repository already implements this inversion correctly in
   `olly-replica/apps/sentinel/olly_sentinel/approval.py` — the sentinel holds only the public half,
   so it cannot sign its own approval. This is the cheapest moment to choose that topology, because
   there are currently **zero** key-destruction call sites in the tree.
5. **Audit event types were not extended.** `signal_audit_trail`'s `event_type` CHECK lives in
   `d2-signalloom/contracts/discovery-portal-bootstrap.sql`, outside this card's ownership boundary.
   Following the SLDP-P1-1 precedent, existing legal types are reused and the specific semantics
   carried in the detail's `category` key. A permitted erasure uses `partition_dropped`, whose
   meaning is exact.

## 13. Reproduction

```bash
cd /home/andy/src/.worktrees/96d0f/osramp-demo
cd d2-signalloom/apps/signal-ingest && go test ./... -count=1
go test ./privacy/ -run TestErasureHold -count=1 -v
cd ../../.. && make test-signal-ingest
make demo-signalloom-api-test TIER=contract
test/erasure-legal-hold-mutation-proof.sh
./scripts/check-vacuous-assertions.sh
```

## 14. What adversarial review found after the suite was green — the most useful output of this card

The package reached 125 tests, a 23-case mutation harness, 1020 module tests and 56 contract tests,
all green. An adversarial review then found **two CRITICAL and one HIGH** defect, three of them
proven by execution against a live PostgreSQL 16. All are fixed, each has a regression test in
`privacy/review_findings_test.go` or `api/erasure_test.go`, and they are recorded here because the
pattern matters more than the individual bugs.

| # | Severity | Defect | Fix |
|---|---|---|---|
| 1 | CRITICAL | `PostgresIncidentSource` queried a **bare pooled connection**, never setting `app.current_tenant`. Under FORCE RLS the policy matched nothing, so the query **succeeded with zero rows** — the wire encoding of "determined: no holds". Every durable hold was invisible and every erasure permitted. Measured: 0 rows without the claim, 1 with it. | Query runs in a transaction that sets the claim first (`privacy/postgres.go`) |
| 2 | CRITICAL | The HTTP handler took the requester identity from `body.RequestedBy`, falling back to the principal only when omitted. Since that field is the sole input to the requester-is-approver check, a caller could send `"requested_by": "nobody"` and then co-sign their own erasure — dual authorisation silently reduced to two humans. | Requester is always the authenticated principal; a mismatched body value is a 400 (`api/erasure.go`) |
| 3 | HIGH | Migration 008 could never be applied: PostgreSQL forbids subqueries in CHECK constraints and the dual-operator constraint used `count(DISTINCT …) FROM unnest(…)`. `ERROR: cannot use subquery in check constraint`. Because `ApplyMigrations` runs 007 in one transaction, the whole migration would have aborted, leaving even `retention_legal_holds` uncreated. | Table removed entirely (see §10); a guard now rejects subquery constructs in the SQL |
| 4 | MEDIUM | Duplicate operator **IDs** were refused but duplicate **public keys** were not, so one human enrolled as `alice` and `alice-oncall` satisfied dual authorisation alone. Chained with #2, one person could erase held evidence unaided. | Registry refuses a shared public key (`privacy/operator.go`) |
| 5 | MEDIUM | `MaxExceptionValidity` bounded only `ExpiresAt − IssuedAt`, never referencing `now`. An `IssuedAt` ten years out with an 89-day window passed every check and authorised erasure for a decade. | Ceiling also binds from the decision clock; future `IssuedAt` refused |
| 6 | MEDIUM | Two of 007's three tables had **no writer anywhere in Go**, while their comments claimed they were "a database backstop". | Both tables deleted; the claim is gone with them (§10) |
| 7 | LOW | `RecordingKeyDestroyer.Calls` appended without synchronisation in shipped non-test code. `-race` was clean only because no test drove it concurrently. | Mutex plus a `Calls()` snapshot; a 64-goroutine test now drives it |
| 8 | LOW | A `ReviewBy` before `IssuedAt` was accepted — non-zero and not after expiry, so nothing caught it. | Refused |
| 9 | LOW | The SQL comment claimed FORCE RLS binds a superuser. It does not; FORCE removes only the **owner's** exemption. The two misconfigurations fail in opposite directions, so the distinction matters. | Comment corrected, with the live assertion named |

### The methodological finding, which outlives all nine

**A non-zero `go test` exit is not evidence of a mutation kill.** Deleting a control line in Go
routinely leaves an unused import or variable, and both are *compile errors*. The harness originally
read any non-zero exit as "killed", so it credited kills for tests that never ran — the inverse of
"a check that never ran looks like a check that passed", and it would have made the headline
"23/23, zero survivors" partly unearned. Four of the twenty-three were exactly this.

The harness now requires an explicit `--- FAIL: <TestName>` line, and reports a build break as
**INCONCLUSIVE** rather than as a kill. Both the advisor and the adversarial review flagged this
independently, which is itself worth noting: the check that catches a false green is the one most
likely to be a false green.

Two other harness lessons, recorded because they cost real time:

- **Defence in depth makes single-line mutation misreport.** The first run showed 5 "survivors",
  every one caused by an overlapping guard catching the violation after the mutated one was removed.
  Where the claim is behavioural ("an override with no expiry is refused"), the mutation must remove
  *every* line that enforces it — three, in that case. Correcting this surfaced one genuinely missing
  assertion: an incident-source **outage** was indistinguishable from a **no-jurisdiction
  misconfiguration**, which would have sent an operator to fix a problem that did not exist.
- **A guard can match its own explanation.** `TestMigration007HasNoSubqueryInACheckConstraint` went
  red against the migration's own header comment, which names the forbidden construct while
  explaining why it was removed. The guard now strips `--` comments and inspects executable SQL.

### Outstanding, recorded rather than silently absorbed

- **Nothing here applies migration 008 to a real database.** Every schema assertion is
  `strings.Contains` over SQL text — which is how a migration that PostgreSQL rejects outright stayed
  green. A DSN-gated apply test belongs with the other live suites and is the single highest-value
  addition for SLDP-P4-PRE.
- **The Postgres tenant-claim fix is source-asserted, not live-asserted.** The regression test proves
  the query runs inside a claim-setting transaction; only a live database proves the claim satisfies
  the policy. The test says so in its own header.
- **Erasure paths outside this gate are not inventoried.** Crypto-shredding means KMS key deletion,
  object-store lifecycle rules, snapshot expiry and partition drops all achieve erasure without
  calling this package. An owner-per-path inventory belongs to SLDP-P6-PRE; presenting this gate as
  complete coverage would be wrong.
- **Cross-vendor audit did not run.** Both Forge and Cato route through the `codex` CLI, whose
  ChatGPT account is rate-limited until 2026-09-19. The review above is therefore Claude-family —
  same lineage as the author — and is a first pass, not the independent second opinion the E4 gate
  asks for. Stated plainly rather than recorded as a pass.
