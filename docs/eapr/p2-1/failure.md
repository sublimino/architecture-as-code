# EAPR-P2-1 Preflight Refusal Evidence

Created: 2026-09-24 03:10:13+01:00
Last Updated: 2026-09-24 14:05:46+01:00

## Verdict

EAPR-P2-1 (D1: shared EAP authentication and tenant binding) did not run. The
card's decision policy (3) fired: files and targets the plan names as already
merged do not exist on the base commit, and both predecessor cards recorded
`status=fail proceed=no blocking_drift=yes` with an explicit human-review gate.
No router, handler, middleware, test, or Makefile file was changed.

## Repository boundary

- Worktree: `/home/andy/src/.worktrees/065d0/osramp-demo`
- Base commit: `68d87aca666b28fbdd96c48bdeca881fcf7fef25` (= `integration/eapr-v0.1.0` tip)
- `git merge-base --is-ancestor integration/eapr-v0.1.0 HEAD`: exit 0

## Consumed artefacts absent from the base

| Consumed from | Expected on base | Observed on base | Observed on `EAPR-P1-4` |
| :--- | :--- | :--- | :--- |
| P1-4 sealed sweep | `test_tenant_isolation.py` 1983 lines, `NOT_DATABASE_BACKED` (16 EAP entries) | 183 lines, no `NOT_DATABASE_BACKED` | 1983 lines |
| P1-4 merged branches | `integration/sl{ea,et,ed,es,te}-v0.1.0` ancestors of HEAD | all five `NOT-MERGED` | merged in order |
| P1-4 slet transit routes | `x_spiffe_id` Header params, `_authorize_or_403` | none (`rg` empty) | present on slet |
| P1-3 gate | `make test-eap-offline` | absent | absent — exists only on `EAPR-P1-3` (`Makefile:536`); `EAPR-P1-3` is not an ancestor of `EAPR-P1-4` (rc=1), so the Governor lands them separately |
| P1 certification | tag `integration/eapr-v0.1.0-p1` | absent | n/a |

Verbatim probes:

```text
$ git merge-base --is-ancestor EAPR-P1-4 HEAD; echo $?        -> 1
$ git merge-base --is-ancestor EAPR-P1-3 HEAD; echo $?        -> 1
$ for b in slea slet sled sles slte; do git merge-base --is-ancestor integration/$b-v0.1.0 HEAD; echo $?; done -> 1 1 1 1 1
$ git tag -l 'integration/eapr-v0.1.0-p1'                      -> (empty)
$ wc -l d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py -> 183
$ git show EAPR-P1-4:.../tests/test_tenant_isolation.py | wc -l -> 1983
$ rg -n '^test-eap-offline' Makefile                            -> (empty)
$ rg -n 'x_spiffe_id|_authorize_or_403|X-SPIFFE-ID' d2-signalloom/apps/fe-signalloom/src/*.py -> (empty)
```

## Predecessor gates

- EAPR-P1-GOV: `status=fail proceed=no blocking_drift=yes` — "Human final review required before any P2 card starts".
- EAPR-P2-PRE: `status=fail proceed=no blocking_drift=yes` — STOP conditions 1 and 2 fired on the same tip.

## Anonymous surface measured on the base ("before" number)

Read-only `TestClient` sweep over every route whose endpoint module is one of
the five EAP routers, without a bearer:

```text
REACHABLE 21 of 23 EAP routes anonymously (non-401/403)
```

Stated precisely: 0 of 23 EAP routes require an authenticated principal;
21 respond non-401 anonymously; the 2 that return 401
(`/api/v1/webhooks/{github,generic}`) reject on HMAC signature only, not on a
principal. The 404/422/400 rows are validation responses, not auth. The card's expected post-merge count (25, including the
two slet transit routes) cannot be measured on this base.

## Evidence hardening (advisor gaps closed)

Every ref below resolves (`git rev-parse --verify <ref>^{commit}`), so the
ancestor exit status is exactly 1 (not merged), never 128 (missing ref):

```text
EAPR-P1-3                    1d15a906bcb4  ancestor-rc=1
EAPR-P1-4                    4621df93ed63  ancestor-rc=1
integration/slea-v0.1.0      18c9456db5be  ancestor-rc=1
integration/slet-v0.1.0      7e837f946ebf  ancestor-rc=1
integration/sled-v0.1.0      aac53d634fdf  ancestor-rc=1
integration/sles-v0.1.0      f1b6780e702e  ancestor-rc=1
integration/slte-v0.1.0      377058754c9b  ancestor-rc=1
```

The router divergence is measured, not asserted
(`git diff --stat 68d87aca EAPR-P1-4 -- <five routers>`):

```text
 environment_lifecycle.py | 844 +++++++++++++++++++--
 environment_routing.py   | 124 ++-
 scenario_seeding.py      |  83 +-
 tenant_isolation.py      | 279 ++++++-
 4 files changed, 1239 insertions(+), 91 deletions(-)
 (webhook_triggers.py unchanged: 295 lines on both)
```

Line counts base | `EAPR-P1-4`: tenant_isolation 329 | 558; scenario_seeding
327 | 408; environment_routing 520 | 636; environment_lifecycle 399 | 1121.

Exemptions: `NOT_DATABASE_BACKED` does not exist on the base; on `EAPR-P1-4`
(`tests/test_tenant_isolation.py:670`) `ast.literal_eval` of the list gives
96 entries, 16 of them EAP routes (the "remove 16" deliverable). An earlier
revision of this record said 110 — a line-count regex, not a parse; corrected
after cross-vendor audit.
`x_spiffe_id` / `_authorize_or_403` occur 5 times on `EAPR-P1-4`'s
`tenant_isolation.py` and 0 times on the base.

All `EAPR-P1-4` content above was read with `git show EAPR-P1-4:<path>` from
this worktree's object store; no sibling or governor worktree was read.

## Launch anomaly (escalate separately — higher severity than this card)

The kanban runtime launched EAPR-P2-1, P2-2 and P2-3 (02:06:09–14 UTC) five
seconds after EAPR-P2-PRE exited 0 into the `review` column, which itself
started four seconds after EAPR-P1-GOV exited 0 into `review`. A FiveWhys pass
over the run records and `kanban-check.sh` found the mechanism:

1. `supervise --apply` STEP 0b → `cmd_start_ready` judged P2-PRE satisfied.
2. The start-ready predicate (`kanban-check.sh` ~:1700–1709) blocks only on
   prerequisite columns `backlog | in_progress | trash | archived` when no
   proposal is supplied; `review`, `done` and `blocked` fall through as
   satisfied. The errata verdict tag is never read on that path.
3. The supervise invocation carried no `--proposal` (deduced: no
   `errata-seen.EAPR.json` / `supervisor-prompt.EAPR.md` exist, which supervise
   writes only under a proposal; `SKILL.md:333` documents the no-proposal form).
4. The D11 site-2 fix from EAPR-P1-2 (`905dc062`) is an opt-in overlay keyed on
   `DONE_CHECK_PROPOSAL`; the legacy "review = ready" semantics remain the
   default, and `--apply` does not enforce a proposal.
5. Its regression test (`ajm-cline-kanban-mutation-gates.bats:221`) passes
   `--proposal` in both arms, so it proved the gate works when armed, never that
   it is armed. The runtime's own `evaluateStartableTasks` uses
   `SATISFIED_COLUMNS = {review, done, archived}` and `task start` has no
   dependency guard, so both layers equate "agent finished" with "satisfied".

Fail-closed cards exit 0 by contract, so a refusal is indistinguishable from a
pass at every mechanical gate on this path. Corrective actions (owner: Andy,
P1-2 follow-up card, before any EAPR relaunch): refuse `--apply` without a
resolvable proposal and resolve it from the mission capsule; invert start-ready
to an allow-list requiring a corroborated pass; add BATS for prereq-in-`review`
and prereq-in-`blocked` without `--proposal`; add a start-time gate that the
integration tip contains each predecessor's errata `Commit:` SHA (or the
`integration/<x>-p<N-1>` tag); adjudicate `review` before STEP 0b. EAPR-P2-3
was still running on the same base at the time of writing; no board state was
touched by this card.

## Why not implement on the HEAD router versions

The decisive reason is that three acceptance criteria are unsatisfiable on the
base: "16 entries removed" (no `NOT_DATABASE_BACKED`), "sweep 0 failed" (183-line
stub, not the 1983-line sealed sweep), and "`make test-eap-offline` green" (no
target). Both predecessor gates independently say `proceed=no`.

Supporting, not decisive: P1-4 changes four of the five routers, mostly by
addition (+1239/−91; `tenant_isolation.py` +279 including the transit pair,
`environment_lifecycle.py` +844). A P2-1 diff against HEAD's versions of those
files carries a real merge-conflict risk at the Governor's P1-4 merge, but no
trial merge was run, so that risk is inference rather than proof.

## Required remediation

Human review of P1-GOV/P2-PRE → Governor lands P1-3 + P1-4 on
`integration/eapr-v0.1.0` → cut tag `integration/eapr-v0.1.0-p1` → re-run
EAPR-P2-PRE on that tag (25-route table) → relaunch EAPR-P2-1 on that tag.
Sibling cards EAPR-P2-2 and EAPR-P2-3 were launched on the same unmerged tip.

## Cross-vendor audit

Cato (read-only, claude-opus-5-5 because the codex path was unavailable) verdict:
`concerns`. It reproduced all six probes and the router line counts, corrected
the exemption total (96, not 110) and the Makefile-target column (P1-3 only),
flagged "wholesale" as overstated, and noted the anonymous sweep was not
independently re-run. All three corrections are applied above.

## Relaunch 2026-09-24 12:06Z (task 28b07) — same base, same verdict

Relaunched as kanban task `28b07` at 12:06:58Z, five seconds before the
restarted twin `065d0` exited (12:07:03Z). The provenance HOLD on P1-GOV was
cleared at 11:47Z (EAPR-P1-2's missing osramp-demo branch ruled a false
positive: its contract delivers direct to `~/.andy_sync` master). That ruling
resolves P1-GOV's Step 0 blocker; it does not put P1-3/P1-4 on the integration
tip, and P2-PRE was not restarted. Every probe above re-run at 12:13Z gives the
same answer:

```text
$ git rev-parse HEAD                                            -> 68d87aca666b28fbdd96c48bdeca881fcf7fef25
EAPR-P1-3                    1d15a906bcb4 ancestor-rc=1
EAPR-P1-4                    4621df93ed63 ancestor-rc=1
integration/sl{ea,et,ed,es,te}-v0.1.0                          ancestor-rc=1 1 1 1 1
$ git tag -l 'integration/eapr-v0.1.0-p1'                       -> (empty)
$ wc -l .../tests/test_tenant_isolation.py                      -> 183
$ rg -n '^test-eap-offline' Makefile                            -> (empty)
$ rg -n 'NOT_DATABASE_BACKED\s*[:=]' src/tests/                  -> (empty)
$ proposal '#### Errata — EAPR-P2-PRE' machine tag              -> status=fail proceed=no
$ kanban task_runs run-7ce29-1790250873041… (P1-GOV)            -> state=running since 2026-09-24 11:54:33Z
```

STOP condition 1 ("EAPR-P2-PRE errata absent or status!=pass, or its route
table is missing") fires verbatim. Verdict unchanged: `status=fail proceed=no`.

**What is new.** (1) The restarted twin `065d0` (11:54:45Z–12:07:03Z) recorded
1 tool call, 0 files modified, and a response beginning "- Five install_*
functions mounting with dependencies=[Depends(api_compat.authent…" — a
deliverable list asserted as prose with nothing on disk. It is the
zero-output-run class the D11 gates exist to refuse; its `awaiting_review` row
should not be promoted. (2) The launch-ordering defect described in the section
above is unchanged after the clearance: P2-1 was restarted in parallel with the
governor it depends on, not after it, and a second P2-1 card was minted while
the first was still running. The 12:06:58Z launch is the same start-ready
predicate firing: P2-PRE sat in `review` with `proceed=no`, and a prerequisite
in `review` satisfies `cmd_start_ready` (`kanban-check.sh` ~:1700–1709) unless
`--proposal` is supplied.

**What this relaunch leaves behind.** `scripts/eap/anon_sweep.py` — the /tmp
probe from the first refusal, committed so the Governor can reproduce the
"before" and "after" numbers. T2 needs a reproducible sweep and names
P2-PRE's script as the source; that script is not on this base, so this is a
stand-in for P2-GOV to reconcile against P2-PRE's at merge. With
`--expect-zero` it exits 1 while anything is reachable or a websocket route
exists unprobed; it refuses to run under a live `DATABASE_URL`. It derives the
route list from `app.routes` by endpoint module, counts websocket routes
separately (0 on this base), and prints a positive control (`GET /health`
without a token). Run from `d2-signalloom/apps/fe-signalloom/src` with the uv
recipe; output on this base:

```text
POST   /api/v1/environments/provision                                422  REACHABLE
POST   /api/v1/environments/resolve-domain                           400  REACHABLE
GET    /api/v1/environments/                                         200  REACHABLE
GET    /api/v1/environments/{environment_id}                         404  REACHABLE
POST   /api/v1/environments/{environment_id}/extend                  422  REACHABLE
POST   /api/v1/environments/{environment_id}/teardown                404  REACHABLE
POST   /api/v1/webhooks/github                                       401  auth
POST   /api/v1/webhooks/generic                                      401  auth
POST   /api/v1/eap/tenants                                           422  REACHABLE
GET    /api/v1/eap/tenants                                           200  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}                           404  REACHABLE
DELETE /api/v1/eap/tenants/{customer_hash}                           404  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}/manifests                 200  REACHABLE
GET    /api/v1/eap/tenants/{customer_hash}/spire-entry               200  REACHABLE
POST   /api/v1/eap/lifecycle/register                                422  REACHABLE
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/heartbeat  404  REACHABLE
POST   /api/v1/eap/lifecycle/environments/{customer_hash}/activity   404  REACHABLE
GET    /api/v1/eap/lifecycle/environments/{customer_hash}            404  REACHABLE
GET    /api/v1/eap/lifecycle/active                                  200  REACHABLE
POST   /api/v1/eap/lifecycle/reap-now                                200  REACHABLE
POST   /api/v1/eap/scenarios/execute                                 201  REACHABLE
GET    /api/v1/eap/scenarios/events/{customer_hash}                  200  REACHABLE
GET    /api/v1/eap/scenarios/history                                 200  REACHABLE
websocket routes on EAP modules: 0
positive control GET /health without token: 200
REACHABLE 21 of 23 EAP routes anonymously (non-401/403)
```

Stated precisely, as before: 0 of 23 require a principal; 21 respond non-401
anonymously; the 2 webhook routes reject on HMAC only. No router, handler,
middleware, test or Makefile file was changed by this relaunch either.

**Required remediation** is the sequence in the section above, with one
addition: do not relaunch P2-1 until P2-PRE's errata reads `status=pass` on a
tip that contains P1-3 and P1-4 and carries `integration/eapr-v0.1.0-p1`.

**Unblock checklist (all three must hold before any relaunch; relaunching on
`68d87aca` fails deterministically — this is the second refusal on that SHA):**

```text
[ ] proposal '#### Errata — EAPR-P2-PRE' machine tag reads status=pass proceed=yes
[ ] git merge-base --is-ancestor EAPR-P1-4 integration/eapr-v0.1.0 ; echo $?   -> 0   (now 1)
[ ] git merge-base --is-ancestor EAPR-P1-3 integration/eapr-v0.1.0 ; echo $?   -> 0   (now 1)
[ ] git tag -l 'integration/eapr-v0.1.0-p1'                                     -> non-empty (now empty)
```

Sweep caveats, stated so the number is not over-read: it is an in-process
`TestClient` sweep of a bare app (no lifespan, no database, no ingress, no demo
flag set in the environment), so it measures the routers, not the deployed
topology; "REACHABLE" means not 401/403 — 404/422/400 rows show validation or
lookup ran before any principal gate; routes are found by endpoint module, so
the 23 is a lower bound on the anonymous surface. Once P1-4's sealed sweep is
on the base, that file is the source of truth and this script is the
reproduction of the pre-merge number; a disagreement between them is a finding.
The twin's "1 tool call, 0 files modified" is the run's recorded row after it
ended (`ended_at` 12:07:03Z), not an inference about a live agent.

**Cross-vendor audit (relaunch).** Cato's codex path is rejected on this host,
so the audit ran on a Claude-family model — Rule 2a is recorded as skipped for
infrastructure reasons plus a manual same-family audit. Verdict `concerns`,
criticality low, five minor findings, all applied: websocket count on the
verdict line, `--expect-zero`, `DATABASE_URL` refusal, the T2 wording above,
and the start-ready sentence above.

## Remediation attempt 1 (2026-09-24 13:48:01+01:00, runtime auto-remediation) — not fixable in this scope

The runtime re-invoked this card as "attempt 1/5" after reading the failure
signal as a failed review. Re-probed at 13:47 local:

```text
integration/eapr-v0.1.0                       -> 9294bd11 (moved from 68d87aca: two docs commits, docs/eapr/p1-gov/* only)
git merge-base --is-ancestor EAPR-P1-4 tip     -> rc=1
git merge-base --is-ancestor EAPR-P1-3 tip     -> rc=1
git tag -l 'integration/eapr-v0.1.0-p1'        -> (empty)
tests/test_tenant_isolation.py on tip          -> 183 lines
Makefile test-eap-offline on tip               -> absent
proposal '#### Errata — EAPR-P2-PRE' tag       -> status=fail proceed=no
docs/eapr/p1-gov/proposal-errata.md on tip     -> status=fail proceed=no (13:16:13+01:00: fifteen-suite BATS gate 369/375, 6 failed, "return the six failures to P1-2")
kanban task_runs 7ce29 (P1-GOV)                -> a third run started 12:46:34Z, state=running
```

The blocker moved one layer further up, not closer: P1-GOV's second run
failed at its own suite gate, so P1-3/P1-4 will not land until P1-2 fixes six
BATS cases (`supervise: the review column is adjudicated every cycle`, four
`create:` prompt-compilation cases, one agent-id mapping case) and P1-GOV
passes. Nothing in EAPR-P2-1's file ownership (five `install_*_api` mounts,
handler signatures, header middleware, the new tests) can change any of those
probes. A "materially different strategy" inside this scope does not exist:
the only alternative — implementing against HEAD's router versions — was
rejected in the first refusal for three unsatisfiable acceptance criteria and
a merge collision with P1-4, and both reasons still hold on `9294bd11`.

Strategy recorded: re-verify, state non-fixability, stop. Result: unchanged
verdict. The branch is not rebased onto `9294bd11`; the two new tip commits
touch only `docs/eapr/p1-gov/`, so the Governor's `--no-ff` merge is
conflict-free when the card is eventually accepted.

## Remediation attempt 2 (2026-09-24 13:50:48+01:00, runtime auto-remediation) — not fixable in this scope

Re-probed three minutes after attempt 1; every value identical: tip
`9294bd11`, `EAPR-P1-4`/`EAPR-P1-3` ancestor rc=1, no p1 tag, sweep 183
lines, no `make test-eap-offline`, P2-PRE `status=fail proceed=no`, P1-GOV on
the tip `status=fail proceed=no`, P1-GOV third run (`7ce29`, started
12:46:34Z) still `running`. The only working-tree change is the runtime's own
`.kanban-failed-28b07` marker, left untouched.

Diagnosis is unchanged because the evidence is unchanged; a different strategy
requires a different world. The remediation loop is re-invoking a card whose
predecessors are red — the same start-ready defect this record describes
twice — and each attempt costs a run without any path to green. Stop
re-dispatching EAPR-P2-1 until the unblock checklist above is satisfied.

## Remediation attempt 3 (2026-09-24 13:55:35+01:00, runtime auto-remediation) — not fixable in this scope

Probes at 13:55 local identical to attempts 1 and 2: tip `9294bd11`,
`EAPR-P1-4`/`EAPR-P1-3` ancestor rc=1, no p1 tag, P2-PRE and P1-GOV both
`status=fail proceed=no`, P1-GOV third run (`7ce29`, 12:46:34Z) still
`running`. No in-scope action exists; verdict unchanged. Three attempts in
eleven minutes against an upstream blocker is the loop misfiring, not the card.

## Remediation attempt 4 (2026-09-24 14:00:38+01:00, runtime auto-remediation) — not fixable in this scope

Probes at 14:00 local identical to attempts 1–3: tip `9294bd11`, P1-4/P1-3
ancestor rc=1, no p1 tag, P2-PRE and P1-GOV `status=fail proceed=no`, P1-GOV
third run still `running`. Verdict unchanged; nothing in scope to change.

## Remediation attempt 5 of 5 (2026-09-24 14:05:46+01:00, runtime auto-remediation) — not fixable in this scope; loop exhausted

Probes at 14:05 local identical to attempts 1–4: tip `9294bd11`, P1-4/P1-3
ancestor rc=1, no p1 tag, P2-PRE and P1-GOV `status=fail proceed=no`, P1-GOV
third run (`7ce29`, 12:46:34Z) still `running`. Verdict unchanged.

### Hand-off (for the human, after the loop)

- Five remediation attempts in 21 minutes, every one against an upstream
  blocker this card cannot touch. The dispatcher re-runs cards whose
  predecessors are red; that is the defect to fix before EAPR Phase 2 is
  relaunched (see "Launch anomaly" above and the P1-2 follow-up it names).
- Branch `EAPR-P2-1` (base `68d87aca`, ten commits on `4de9dadc`) carries
  exactly two non-record artefacts: `scripts/eap/anon_sweep.py` and this file.
  Zero router, handler, middleware, test or Makefile changes. The Governor may
  merge it as evidence or leave it; either is safe.
- Unblock order: P1-2 fixes the six BATS cases → P1-GOV passes and lands
  P1-3 + P1-4 on `integration/eapr-v0.1.0` → tag `integration/eapr-v0.1.0-p1`
  → re-run P2-PRE to `status=pass` → relaunch P2-1 on that tag with the
  sweep script as the before/after instrument (`--expect-zero` for the gate).

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
