# SLDP-P1-1 execution evidence — failed prerequisite gate

## Resumed attempt — 2026-09-14 12:57:51+01:00

**Current result: FAIL — authoritative object tenant ownership prerequisite.**
The prior audit blocker documented below is resolved by P1-2 at `fcc72aba`.
This attempt started from `111ef78bb2059271a8f18ef84d44956ea63e6135`,
which includes that integration commit. The original failure record below is
historical, not a claim that the audit prerequisite remains missing.

Implementation review and direct source inspection found:

| Inspected source | Missing enforcement input |
|---|---|
| `model/signal.go:99-119` | `Observation` has no authoritative tenant ownership field. Labels are supplied by producers, not authenticated ownership metadata. |
| `model/actor.go:19-46` | `ProvisionalActor` has no tenant ownership field. |
| `store/store.go:19-26` | `Query` supports layers, timestamps, actor ID and limit, but no tenant predicate. |
| `api/handlers.go:392` | Observation retrieval uses this query interface. |
| `api/handlers.go:613` | SSE replay uses `QueryRange` with time and limit only. |

Paths above are relative to `d2-signalloom/apps/signal-ingest/`.
Principal-to-tenant authentication does not establish object-to-tenant ownership.
Completing per-object tenant checks on these paths requires ownership propagation
through ingestion, persistence, correlation and streams, or an explicitly approved
alternative isolation architecture. Neither assigning historical data to an
invented tenant nor trusting a client-supplied label is an acceptable substitute.
Blanket denial of data routes would not demonstrate the requested useful control.

No implementation or hostile tests were written. Required Go and acceptance
tests were not run after this prerequisite stop. No application files, shared
schemas, historical segments or sibling worktrees were changed. A delegated
implementation reviewer identified the gap; direct Read inspection confirmed
the model and query fields before this decision.

### Resume errata handoff — not applied to sibling proposal

#### Errata — SLDP-P1-1 Authenticate and authorise the signal-ingest HTTP API
**Created:** 2026-09-14 12:57:51+01:00
**Last Updated:** 2026-09-14 12:57:51+01:00
**Status:** Failed
**Commit:** [full SHA of the commit containing this resumed-attempt evidence]
**Blocker:** Authoritative tenant ownership is absent from Observation and ProvisionalActor, and SignalStore.Query cannot scope reads by tenant. The requested cross-tenant object and SSE controls therefore need an additional data-ownership prerequisite or authorised scope expansion.
**Attempted:** Confirmed merged P1-2, reviewed implementation seams, and directly inspected model and store query definitions. The prior audit blocker is resolved. Stopped rather than inventing tenant ownership or weakening isolation.
**Evidence:** Git ancestry inspection succeeded at HEAD 111ef78bb2059271a8f18ef84d44956ea63e6135 including fcc72aba; successful source reads show the complete fields in model/signal.go:99-119, model/actor.go:19-46 and store/store.go:19-26. No runtime test failure or success is claimed.
**Recommended action:** escalate — authorise tenant ownership plumbing as part of P1-1 or schedule an explicit prerequisite covering observations, actors, correlation and SSE before retrying. Resolve shared-schema ownership with the Governor; do not rewrite historical attested bytes.
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->

Prepared current Result cell, not applied:
`fail — authoritative object tenant ownership prerequisite (see resumed SLDP-P1-1 errata)`

## Historical first attempt

Status: **FAIL — implementation stopped at a declared hard blocker.**

Created: 2026-09-14 12:37:07+01:00
Baseline: `48278f7e59b45a54cead8c428f53eb97c91445b9`
Task worktree: `/home/andy/src/.worktrees/7d932/osramp-demo`

## Objective and result

Authenticate and authorise the entire signal-ingest HTTP surface, including
metrics and SSE, with tenant-bound permissions, bounded enumeration, expiry
handling, and fail-closed audit events. Deliver hostile-case red/green tests,
proof, a task commit, and qualified proposal errata.

**Not delivered:** application controls and authentication tests. This document
records a prerequisite failure, not a failing runtime test or implementation
success. The existing HTTP exposure remains unresolved.

## Verified prerequisite blocker

The card requires the already-delivered fail-closed audit writer from P0-3 and
explicitly says to stop on a discarding audit writer. The approved baseline
instead contains these positively inspected behaviours:

| Source | Evidence |
|---|---|
| `d2-signalloom/apps/signal-ingest/audit/audit.go:46-52` | Interface documentation tells implementations to log and continue on transient failures. |
| `d2-signalloom/apps/signal-ingest/audit/audit.go:55-59` | `NopWriter.WriteAuditEvent` returns `nil` without persisting the event. |
| `d2-signalloom/apps/signal-ingest/main.go:71-82` | Writer-construction failure installs `audit.NopWriter{}`. |
| `d2-signalloom/apps/signal-ingest/main.go:115-119` | Missing DSN installs `audit.NopWriter{}` and leaves readiness green. |
| `d2-signalloom/apps/signal-ingest/main.go:211-215` | The selected writer is injected into the API handlers. |
| `docs/signalloom/sldp-p1-pre-proof.md:109-121` | Merged PRE explicitly assigns correction of these fail-open paths to P1-2. |

Qualification: a failed startup Postgres ping retains the Postgres writer
(`main.go:84-113`). This record does **not** claim every database outage selects
the discarding writer.

The proposal Work Decomposition assigns fail-closed encryption/audit to P1-2,
not an already-delivered P0-3. The single read-only board inspection showed
P1-2 in progress concurrently. Rebuilding that sibling's primitive, importing
unmerged work, or proceeding with the discarding fallback is not an authorised
way around this prerequisite.

## Commands and independent review

| Gate | Exit/result | Operative evidence |
|---|---|---|
| `pwd` in the supplied workdir | 0 | `/home/andy/.cline/worktrees/7d932/osramp-demo` |
| `git rev-parse --show-toplevel` | 0 | `/home/andy/src/.worktrees/7d932/osramp-demo` |
| `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | 0 | Successful gate; integration and HEAD both resolved to the baseline above. |
| `git status --short` before edits | 0 | Clean worktree. |
| `kanban-check.sh --repo /home/andy/src/cp/osramp-demo progress` | 0 | P1-1, P1-2, P1-3 in progress; board also reported health exceptions. No claim about the causes of those exceptions. |
| Source inspection through Read | successful | Exact nil-returning implementation and PRE P1-2 mandate above. |
| Independent read-only reviewer | confirmed | Stop justified; distinguished construction failure from startup ping failure. |

No runtime board state was edited. No remote push, merge, rebase, deployment,
customer access, or attested-evidence mutation occurred.

## Prompt-to-artifact completion audit

| Requirement | Outcome |
|---|---|
| Integration-derived isolated worktree | Verified before edits. |
| Read proposal and PRE | Read; dependency and scope collisions recorded. |
| Authentication / default-deny registration wrapper | Not implemented: prerequisite gate stopped execution. |
| Per-route and per-object permissions | Not implemented. |
| Principal-derived tenant contract | Not implemented. RLS consumer is P2-2 in the reviewed proposal, not P1-2 as stated in this card. |
| Enumeration bounds and shared principal budget | Not implemented. |
| Four SSE paths and mid-connection expiry | Not implemented or tested. |
| Metrics posture | Not changed. PRE preserves open metrics; this card requires protection or identifier-free-label evidence. Resolve in implementation, not by treating PRE as an exemption. |
| Credential decision | PRE selects SPIFFE JWT-SVID; no third identity system introduced. |
| CORS, constant-time validation, audit pseudonyms | Not implemented. |
| Fail-closed failure-event persistence | Blocked by the prerequisite described above. |
| Startup route inventory | Not implemented. PRE's source table is not runtime inventory proof. |
| Hostile tests observed red then green | Not run; no hostile-case success claimed. |
| Required Go API, full-module and TestAuth commands | Not run after the explicit STOP gate. |
| Required main.go / handlers.go search gates | Not used as success evidence: occurrence counts alone cannot establish a security control. |
| `make test-signal-ingest` | Not run after STOP; PRE results are not this card's authentication evidence. |
| `make demo-signalloom-api-test TIER=contract` | Not run after STOP. |
| `bats test/acceptance-spec-coverage.bats` | Not run after STOP. |
| Required proof path | This file. |
| Commit in task worktree | Evidence-only commit; Governor owns integration. |
| Proposal errata and Result update | Not applied: specified proposal path is inside the Governor sibling worktree; Safety Rules prohibit sibling edits. Prepared text below is a handoff, not a substitute claimed as completion. |

## Governor handoff

Remediate by integrating P1-2's fail-closed writer and scheduling a new
integration-derived P1-1 attempt with that prerequisite explicitly named.
Do not call the existing PRE PASS proof that the writer has been implemented.
Confirm the RLS consumer as P2-2 and retain the card's stricter metrics posture.
Provide an authorised proposal-update surface or have the Governor apply the
failure entry and Result cell. No sibling worktree was modified in this attempt.

Encryption at rest does not mitigate unauthenticated HTTP reads: responses are
decrypted by construction. Closing the HTTP boundary is still required before
privacy controls can be considered effective against graph exfiltration.

### Qualified failure errata for authorised application

The following is prepared only. Replace the Commit placeholder with this
evidence commit's full SHA when applying it inside Appendix / Spec: Errata.
Use `blocking_drift=no`: the immediate blocker is an undelivered dependency,
not a claim that the entire architecture needs replanning.

#### Errata — SLDP-P1-1 Authenticate and authorise the signal-ingest HTTP API
**Created:** 2026-09-14 12:37:07+01:00
**Last Updated:** 2026-09-14 12:37:07+01:00
**Status:** Failed
**Commit:** [full SHA of the commit containing this evidence document]
**Blocker:** Required fail-closed audit prerequisite is not delivered in baseline 48278f7e59b45a54cead8c428f53eb97c91445b9; missing DSN and writer-construction failure install the silently discarding NopWriter. PRE assigns the fix to concurrent P1-2, despite this card requiring an already-delivered P0-3 writer.
**Attempted:** Validated isolated integration ancestry, read the proposal and PRE, inspected audit construction and implementation, inspected the board once, and obtained independent read-only review. Stopped before implementation as required; did not rebuild P1-2 or edit the Governor sibling worktree.
**Evidence:** Ancestry command exited 0 at the baseline above; source Read returned `func (NopWriter) WriteAuditEvent(context.Context, Event) error { return nil }` at audit/audit.go:59; PRE lines 109-121 assign correction to P1-2; board progress exited 0 and showed P1-2 in progress. Full details: docs/signalloom/sldp-p1-1-proof.md. Encryption at rest does not prevent unauthenticated reads. RLS belongs to P2-2 in the reviewed proposal.
**Recommended action:** remediate — integrate P1-2, correct the prerequisite reference, then recreate an integration-derived attempt. Governor or an authorised proposal owner must apply this block and this row's Result because sibling edits are forbidden.
<!-- kanban-check: status=fail proceed=no blocking_drift=no -->

Prepared Result cell (not applied):
`fail — required fail-closed audit prerequisite undelivered (see Errata — SLDP-P1-1)`
