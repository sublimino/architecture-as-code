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

The two 401s are `/api/v1/webhooks/{github,generic}` HMAC signature failures
inside the handler, not principal authentication; every one of the 23 routes
reaches its handler without a principal. The 404/422/400 rows are handler
validation, not auth. The card's expected post-merge count (25, including the
two slet transit routes) cannot be measured on this base.

## Why not implement on the HEAD router versions

P1-4 replaces the same five router files wholesale (slea's
`environment_routing.py`, slet's `tenant_isolation.py` with the transit pair,
sled's `environment_lifecycle.py`). A P2-1 diff against HEAD would conflict at
the Governor's P1-4 merge and cannot satisfy "16 entries removed, sweep 0 failed"
or "`make test-eap-offline` green", none of which exist here.

## Required remediation

1. Resolve EAPR-P1-GOV under human review; merge P1-3 and P1-4 into
   `integration/eapr-v0.1.0`; apply tag `integration/eapr-v0.1.0-p1`.
2. Re-run EAPR-P2-PRE on the reconciled tip to produce the 25-route table.
3. Re-launch EAPR-P2-1 from the reconciled tip. Sibling cards EAPR-P2-2 and
   EAPR-P2-3 were launched on the same unmerged tip and need the same check.

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
