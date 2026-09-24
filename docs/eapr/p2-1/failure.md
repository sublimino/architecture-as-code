# EAPR-P2-1 Preflight Refusal Evidence

Created: 2026-09-24 03:10:13+01:00
Last Updated: 2026-09-24 03:10:13+01:00

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
| P1-3 gate | `make test-eap-offline` | absent | present |
| P1 certification | tag `integration/eapr-v0.1.0-p1` | absent | n/a |

Verbatim probes:

```text
$ git merge-base --is-ancestor EAPR-P1-4 HEAD; echo $?        -> 1
$ git merge-base --is-ancestor EAPR-P1-3 HEAD; echo $?        -> 1
$ for b in slea slet sled sles slte: integration/$b-v0.1.0     -> NOT-MERGED (x5)
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

The wholesale replacement is measured, not asserted
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
it holds 110 entries, 16 of them EAP routes (the "remove 16" deliverable).
`x_spiffe_id` / `_authorize_or_403` occur 5 times on `EAPR-P1-4`'s
`tenant_isolation.py` and 0 times on the base.

All `EAPR-P1-4` content above was read with `git show EAPR-P1-4:<path>` from
this worktree's object store; no sibling or governor worktree was read.

## Launch anomaly (follow-up owed)

The kanban runtime launched EAPR-P2-1, P2-2 and P2-3 while their dependency
EAPR-P2-PRE and its predecessor EAPR-P1-GOV were both `proceed=no`. The
start-ready prerequisite gate (D11 site, EAPR-P1-2) did not hold on this board.
Follow-up: verify the P1-2 gate is active in the live supervisor before any
further P2 launch.

## Why not implement on the HEAD router versions

P1-4 replaces the same five router files wholesale (slea's
`environment_routing.py`, slet's `tenant_isolation.py` with the transit pair,
sled's `environment_lifecycle.py`). A P2-1 diff against HEAD would conflict at
the Governor's P1-4 merge and cannot satisfy "16 entries removed, sweep 0 failed"
or "`make test-eap-offline` green", none of which exist here.

## Required remediation

Human review of P1-GOV/P2-PRE → Governor lands P1-3 + P1-4 on
`integration/eapr-v0.1.0` → cut tag `integration/eapr-v0.1.0-p1` → re-run
EAPR-P2-PRE on that tag (25-route table) → relaunch EAPR-P2-1 on that tag.
Sibling cards EAPR-P2-2 and EAPR-P2-3 were launched on the same unmerged tip.

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
