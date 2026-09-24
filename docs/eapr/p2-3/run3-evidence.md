# EAPR-P2-3 run 3 evidence (2026-09-24 23:05:50 +0100)

Third run of the card, worktree `/home/andy/src/.worktrees/f5f31/osramp-demo`, created detached at
`integration/eapr-v0.1.0` = `0445bb53` (tag `integration/eapr-v0.1.0-p1`). Base SHA at start: `0445bb53fc8e683585418b1571282d7505e69b5b`.
The card's branch `EAPR-P2-3` already sat at `70c1983f` (merge of that tip into the two earlier runs' work), so this
worktree was moved detached onto `70c1983f` and the branch ref is advanced by compare-and-swap `update-ref`.
No sibling or governor worktree was read; the archived `5ef56` worktree's `git status` hash is identical before and after.

## Preconditions

```text
P2-PRE errata machine tag                      status=pass proceed=yes blocking_drift=no  (base 0445bb53)
make -n test-eap-offline                        rc=0 (Makefile:536)
git diff --stat integration/eapr-v0.1.0 -- .github/workflows/signalloom-ci.yaml | wc -l     0   (T6)
git remote -v                                   origin git@github.com:controlplaneio-in-toto/osramp-demo (fetch/push)
```

## T1 — workflow shape (yq, verbatim)

```text
$ yq '(.on // .true) | keys' .github/workflows/signalloom-eap-pr.yaml        - pull_request / - workflow_dispatch
$ yq '.jobs[].steps[].run // ""' $F | grep -c '^make test-eap-offline'       1
$ yq '.jobs[]."runs-on"' $F                                                 ubuntu-latest
$ yq '.jobs[]."timeout-minutes"' $F                                         10
$ yq '(.on // .true) | keys' .github/workflows/security-scan.yaml             pull_request, push, workflow_dispatch, schedule   (positive control)
```

## T2 — guards and lints

| check | result |
|---|---|
| `bats test/eap-pr-workflow.bats` | 1..14, 14 ok |
| positive control: scratch copy with `python -m pytest tests -q` for the make line, `EAP_PR_WORKFLOW=/tmp/eap-drift.yaml` | not ok 5, 6, 7, 8 |
| `bats d2-signalloom/test/bats-registry-coverage.bats` | 10/10 ok (was 9/10: `eap-pr-workflow.bats` unrun) |
| positive control: self-lint step replaced by `run: true` | not ok 10, names `eap-pr-workflow.bats` |
| `bats test/terraform-dual-lane-registration.bats` | 5/6; test 3 fails on five suites registered in vm-pipeline only (sfas-live-acceptance, sfas-p1-2-nono-ingest, sler-p6-3-multiplane-acceptance, wait-job, wait-pods-service) — pre-existing, neither pipeline file is touched by this card |
| `actionlint` (built from source, go1.26.2) | rc=0 |
| `zizmor 1.30.1` (offline) | before: 1 medium `artipacked` (checkout persists credentials); after `persist-credentials: false`: "No findings to report", rc=0 |

Registry hook: the workflow runs `bats test/eap-pr-workflow.bats` as its own step, and
`bats-registry-coverage.bats` lists `.github/workflows/signalloom-eap-pr.yaml` as a third runner beside the two shell
pipelines. `scripts/ci/vm-pipeline.sh` (frozen, out of scope) and `Makefile` are untouched; registering in
`demo-pipeline.sh` alone would have tripped the dual-lane guard.

## T3 — gate timing on this base

```text
UV_CACHE_DIR=$(mktemp -d)  time make test-eap-offline        elapsed=39.195s   rc=2
  pytest: 2 failed, 188 passed, 7 xfailed in 20.15s
    FAILED tests/test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route   (P2-1)
    FAILED tests/test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision          (P2-2, unmerged)
  bats authz-suite-liveness + api-route-liveness: 10/10 ok (ROUTELIVE ran against the live local cluster)
```

39.2s cold against a 300s budget. Red by design until P2-1 and P2-2 merge; the workflow's make step propagates rc=2.

## T4 — PR run: not possible in this card

The merge boundary forbids `git push` and `gh pr create`. Negative evidence:

```text
$ gh run list --workflow signalloom-eap-pr.yaml --limit 1     HTTP 404: workflow signalloom-eap-pr.yaml not found on the default branch
$ gh pr list --head EAPR-P2-3 --json url,number                []
$ git ls-remote --heads origin EAPR-P2-3 | wc -l               0
```

Fallback, `act pull_request -W .github/workflows/signalloom-eap-pr.yaml -j eap-offline -P ubuntu-latest=catthehacker/ubuntu:act-latest --pull=false --action-cache-path /tmp/act-cache`:

```text
✅ checkout  ✅ Assert the EAP gate target exists  ✅ Install uv  ✅ Install bats (3.9s)  ✅ Show tool versions
✅ Assert no cloud credentials  ✅ Lint this workflow's own contract (1..14, 0.45s)
❌ make test-eap-offline [28.7s]   eap-offline wall-clock: 29s (rc=2)   → Job failed, exitcode '2'
act_elapsed=37.554s   act_rc=1
```

The job exit equals make's rc, so a red suite is not laundered. **The GitHub run URL is owed to P2-GOV**, whose row
already carries "PR CI run visible; human signs": push `EAPR-P2-3` and open a draft PR against `integration/eapr-v0.1.0`.

## T5 — strict-xfail ledger

`pytest tests/test_scenario_seeding.py --runxfail -q` → **7 failed, 27 passed** (positive control: every marker masks a real defect).
Strict run → **27 passed, 7 xfailed, 0 XPASS**. Counts come from `pytest -rx`, not `grep -c`.

| probe | defect | closing card | action here |
|---|---|---|---|
| test_blocker_execute_requires_authentication | B1 | P2-1 (relaunched, unmerged) | keep strict |
| test_blocker_history_is_tenant_scoped | B2 | P2-1 | keep strict |
| test_blocker_execute_rejects_non_hex_customer_hash | B13 | P2-1 | keep strict |
| test_blocker_event_schema_matches_multiplane_audit_event | B3 | P2-2 (`aca62a5e`, retired there, unmerged) | keep strict |
| test_blocker_compliance_proof_is_signed | B4 | P2-2 | keep strict |
| test_blocker_every_event_carries_spiffe_identity | B5 | P2-2 | keep strict |
| test_blocker_generation_is_deterministic | B8 | P2-2 | keep strict |

Retired: 0. Remaining SLES: 7. Other files (`pytest -rx`): `test_sled_p2_certification.py` 5 (D1–D5 → P3-2);
`test_slte_p4_preflight_lifecycle.py` 14 (G1, G1b, G2, G2a/b/c, G3, G4, G5, G6, G6b, G8×2, G9 → P3-4). Total strict-xfail on this base: 26.
No marker was loosened or removed; `git diff 70c1983f -- '*.py'` is empty. Retirement of B1–B13 is P2-GOV's reconcile
after both branches merge, as the card's consumes-from note states.

## Files changed on top of 70c1983f

- `.github/workflows/signalloom-eap-pr.yaml`: `persist-credentials: false` on checkout; new step `bats test/eap-pr-workflow.bats` before the make step.
- `d2-signalloom/test/bats-registry-coverage.bats`: workflow listed as a third runner; failure message names all three.
- `docs/eapr/p2-3/run3-evidence.md`: this file.

## Scratch-merge check (advisor gap 1)

Throwaway detached worktree from `EAPR-P2-3`, removed afterwards; git objects only, no sibling worktree files read.

```text
merge EAPR-P2-2 (aca62a5e)                       clean, 0 conflicts
merge EAPR-P2-1 (fd3a5bc2) on top                CONFLICT: tenant_isolation.py, scenario_seeding.py, environment_lifecycle.py  → aborted
make test-eap-offline on base+P2-2               2 failed, 192 passed, 3 xfailed, 0 XPASS   elapsed=28.814s   rc=2
  FAILED tests/test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route        (P2-1)
  FAILED tests/test_audit_provenance.py::test_the_not_audit_worthy_list_has_no_stale_entries             (13 routes P2-2 now audits; P2-1 prunes the list)
strict run of test_scenario_seeding.py            31 passed, 3 xfailed (B1, B2, B13), 0 XPASS
```

So P2-2's fixes flip exactly the four markers it retired and no other; merging P2-3 after P2-2 alone still leaves the gate red on two P2-1 items. P2-1 vs P2-2 conflict resolution is P2-GOV's.

Pre-existing and out of scope: `test/terraform-dual-lane-registration.bats` test 3 fails on five suites registered in `vm-pipeline.sh` only; neither pipeline file is touched here.
