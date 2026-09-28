# EAPR-P2-3 relaunch evidence (2026-09-24 22:50:18+01:00)

Second run of the card, in the same worktree as the first (`/home/andy/src/.worktrees/5ef56/osramp-demo`, branch `EAPR-P2-3`).
Verdict: `status=fail proceed=no blocking_drift=no`. Blocker: stale worktree base. Everything below is
measured, not inferred; measurements on the integration tip were taken on `git archive 0445bb53`
extracted to `/tmp/eapr-tip-0445bb53`, never on a sibling or governor worktree.

## Ancestry gate

```text
$ git rev-parse HEAD                                              683e11dba65b5d6c2d945dba8de924f6f8485935  (base at start; branch EAPR-P2-3)
$ git merge-base integration/eapr-v0.1.0 HEAD                     68d87aca666b28fbdd96c48bdeca881fcf7fef25
$ git merge-base --is-ancestor integration/eapr-v0.1.0 HEAD; echo rc=$?     rc=1
$ git rev-parse integration/eapr-v0.1.0                           0445bb53fc8e683585418b1571282d7505e69b5b  (tag integration/eapr-v0.1.0-p1)
$ git reflog show --date=iso EAPR-P2-3 | tail -1                  68d87aca EAPR-P2-3@{2026-09-24 03:14:11 +0100}: branch: Created from HEAD
$ git reflog --date=iso | tail -1                                 68d87aca HEAD@{2026-09-24 03:06:14 +0100}   (worktree created)
$ git log -1 --format=%ci 0445bb53                                2026-09-24 21:50:46 +0100                   (tip advanced, 18h later)
$ make -n test-eap-offline                                        make: *** No rule to make target 'test-eap-offline'.  Stop.   (rc=2 on HEAD)
$ git show integration/eapr-v0.1.0:Makefile | grep -n '^test-eap-offline:'   536:test-eap-offline: ...
$ rg -c strict=True d2-signalloom/apps/fe-signalloom/src/tests/test_scenario_seeding.py     (0 on HEAD; 7 on the tip)
```

The runtime reused the 03:06 worktree for the 22:43 relaunch instead of creating one from the tip. P2-PRE's
errata shows its worktree (`d04e1`) was created from `0445bb53`; this one was not.

## Draft on this branch (683e11db), re-verified

```text
$ yq '(.on // .true) | keys | join(",")' .github/workflows/signalloom-eap-pr.yaml    pull_request,workflow_dispatch
$ yq ... signalloom-ci.yaml                                                            workflow_dispatch,schedule
$ yq ... security-scan.yaml   (positive control)                                       pull_request,push,workflow_dispatch,schedule
$ bats test/eap-pr-workflow.bats                                                       1..14, 14 ok
$ EAP_PR_WORKFLOW=<scratch copy, make line -> python -m pytest tests -q> bats ...     not ok 5, 6, 7, 8   (drift guard red)
$ git diff --stat 68d87aca HEAD -- .github/workflows/signalloom-ci.yaml               (empty)
$ git ls-tree -r --name-only 0445bb53 | rg 'signalloom-eap-pr|eap-pr-workflow'        (neither exists on the tip: additive, no merge conflict)
$ cp workflow + bats onto /tmp tip; bats test/eap-pr-workflow.bats                    14 ok;  make -n test-eap-offline  rc=0
```

## Gate timing on the tip (T3)

| run | where | wall-clock | result |
|---|---|---|---|
| `time make test-eap-offline`, warm uv cache | /tmp tip, this host | 30.9s | pytest 2 failed / 188 passed / 7 xfailed; bats 10/10 (ROUTELIVE ran against the live local cluster); make rc=2 |
| same, `UV_CACHE_DIR` pointed at an empty dir | /tmp tip, this host | 35.6s | identical counts, rc=2 |
| `act pull_request -j eap-offline` (catthehacker/ubuntu:act-latest) | workflow overlaid on /tmp tip | 38.5s total; make step 28s | checkout, assert, setup-uv, apt bats, versions, no-credentials all green; pytest 2 failed / 188 passed / 7 xfailed; bats 10/10 with the 7 ROUTELIVE cases skipped (`fe-signalloom not deployed`); `eap-offline wall-clock: 28s (rc=2)`; job failed with exit 2, so a red suite is not laundered |

All three are far under the 300s budget. The workflow is red on the tip by design until the two failures close.

## The two failures are product gaps, not archive artefacts

```text
tests/test_tenant_isolation.py:637  AssertionError: these API routes are in neither DB_ROUTES nor NOT_DATABASE_BACKED ...
                                    GET /api/v1/eap/lifecycle/active, /audit-events, /metrics, /reaper/dlq, /reaper/status, ...   (P2-1)
tests/test_audit_provenance.py:975  AssertionError: 1 mutating route(s) neither write an audit event nor declare why they should not:
                                    scenario_seeding.py:api_execute_scenario (POST /execute)                                     (P2-2, unmerged: its errata says this is wired)
```

## Strict-xfail probes under --runxfail on the tip (T5)

`pytest tests/test_scenario_seeding.py --runxfail -q` → `7 failed, 27 passed`. Each fails on its stated assertion:

| probe | assertion under --runxfail | defect | closing card | action here |
|---|---|---|---|---|
| test_blocker_execute_requires_authentication | `assert 201 in (401, 403)` | B1 | P2-1 (in progress) | keep strict |
| test_blocker_history_is_tenant_scoped | `assert 2 <= 1` | B2 | P2-1 | keep strict |
| test_blocker_execute_rejects_non_hex_customer_hash | `assert 201 == 422` | B13 | P2-1 | keep strict |
| test_blocker_event_schema_matches_multiplane_audit_event | field-set `<=` fails | B3 | P2-2 (`aca62a5e`, unmerged; already retired there) | keep strict |
| test_blocker_compliance_proof_is_signed | `assert False` | B4 | P2-2 (same) | keep strict |
| test_blocker_every_event_carries_spiffe_identity | `assert False` | B5 | P2-2 (same) | keep strict |
| test_blocker_generation_is_deterministic | list equality fails | B8 | P2-2 (same) | keep strict |

Retired: 0. Remaining: 7 (T6 is not 0). No marker exists on this branch's base to flip in any case.
Scope collision: P2-2's errata records it removed the B3/B4/B5/B8 markers in its own commit; if P2-3 ever
flips the same lines it will conflict at P2-GOV. Recommend P2-3's retirement pass be limited to B1/B2/B13 after P2-1 lands.

## Runner dependency audit of the workflow

- `api-route-liveness.bats` `setup()` skips every ROUTELIVE case when `kubectl get deployment fe-signalloom` fails (line 322); proven inside the act container (7 skips). ubuntu-latest ships kubectl, node, python3, curl; uv comes from setup-uv (0.5.10, the local version); bats from apt.
- No secrets, no cloud auth, `permissions: contents: read`, all `uses:` pinned to 40-hex SHAs (bats 9, 10, 11 on HEAD).
- `actionlint` and `zizmor` are not installed on this host; both remain owed.
- Not pushed; no PR; no run URL exists.
