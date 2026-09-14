# SLDP-P1-1 execution evidence — failed prerequisite gate

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
