# EAPR-P2-1 Preflight Refusal Evidence

Created: 2026-09-24 03:10:13+01:00
Last Updated: 2026-09-24 03:21:05+01:00

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

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
