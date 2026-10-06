# STUN definition-of-done evidence ledger

> **Recovered record (2026-10-06).** Harvested verbatim from the abandoned
> `integration/stun-under-flux` branch (tip `5482e79b`) per
> `/tmp/sldc2/lost-brief-common.md` row 4. This ledger is the governor's own
> record that the mission closed with definition-of-done items 1-5 FAILED,
> INSUFFICIENT or BLOCKED; it is reproduced as-is because it is itself the
> evidence that the mission never shipped, not a claim about the current
> base. See `docs/signalloom/stun-residual-risk.md` for which of this
> mission's findings are now moot (architecture changed), resolved (fixed
> since), or still open against current code.

**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/stun-under-flux/governor`
**Integration ref:** `refs/heads/integration/stun-under-flux`
**Pre-merge HEAD:** `e737972116d0e95d592cb11713601dddb88dccf1`
**Post-merge HEAD:** `e737972116d0e95d592cb11713601dddb88dccf1`
**Merge decision:** no merge command was safe or necessary: the integration HEAD is the
P7-1 commit itself (`merge-base --is-ancestor` exited `0`).

## Finding: definition-of-done count mismatch

The reviewed-plan row says “all six definition-of-done items evidenced”; the parent
proposal lists **seven** definition-of-done bullets. This ledger takes the seven-bullet
proposal as authoritative because it is the complete accepted definition of done. No
bullet is dropped to make the plan-row count fit.

## Ledger

`MEASURED` means the command was independently invoked by this governor on the
integration worktree. It does **not** mean the command passed. A failed or unavailable
measurement blocks mission closure just as an `INHERITED` row would.

After the initial refusal, Andrew explicitly authorised restoration of only the
staged-deleted STUN artefacts from `HEAD`, preserving the remaining staged
modifications. The re-runs below are therefore available, but the worktree is still
not byte-identical to the integration commit and failed required checks remain gates.

| # | Definition-of-done bullet | Satisfying card | Re-run command | Observed result | Commit SHA | Evidence class |
|---|---|---|---|---|---|---|
| 1 | Stun survives twenty forced reconciles while label and both annotations remain intact. | P2-2 | `STUN_PROOF_LIVE=1 bats --tap test/stun-reconcile-survival.bats` | **FAILED**: TAP `1..5`, cases 1–4 passed; case 5, `live proof reports twenty verified retained stuns`, failed at `[ "$status" -eq 0 ]`. No twenty-readback trace exists. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED — FAILED |
| 2 | Ordinary allow policy cannot defeat quarantine in CI after dataplane readiness. | P3-2 | `bats --tap d2-signalloom/test/stun-admin-tier-deny.bats` | **FAILED**: stored `stun-quarantine-admin-deny` was absent; test reported prerequisite `ResourceSet/agent-swarm` must be restored. The probe recorded `UNVERIFIED`; no CI-success evidence exists. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED — FAILED |
| 3 | Established connection is severed within five seconds after stun. | P4-1 | `scripts/stun/measure-severance.sh --arm on` | **FAILED**: exit `1`; Kubernetes returned `daemonsets.apps "stun-sentinel" not found`. No elapsed severance measurement exists. Required scope remains **Cilium only**; see the P7-1 CNI matrix and scoped parent erratum. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED — FAILED |
| 4 | Cold-cluster stun → un-stun → stun cycle completes and ends managed. | P6-1 | `bats --tap d2-signalloom/test/stun-unstun-cycle.bats && bash d2-signalloom/test/stun-unstun-mutation-proof.sh` | **FAILED**: cycle suite exit `1`; cases 15–17 failed, including tracked-frozen-pod severance release and both pipeline stage7i registration. Mutation proof exit `1` because baseline was red. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED — FAILED |
| 5 | Containment event survives a reconcile that reverts the label. | P5-1 | `bats --tap d2-signalloom/test/stun-evidence-ownership.bats` | **INSUFFICIENT**: exit `0`, four ownership-structure cases passed, but the suite does not execute a label-reverting reconcile or read an event after it. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED — BLOCKED |
| 6 | Published residual-risk statement names every bypass, including fail-open CNI. | P7-1 | `bats --tap --filter 'P7 completeness: published bypasses equal derived register' d2-signalloom/test/residual-risk-completeness.bats` | **PASSED**: `1..1`, completeness guard passed. Four targeted falsification tests also passed, proving their mutations go red. The whole suite remains red on missing two-pipeline registration. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED |
| 7 | Parent-proposal erratum scopes severance claim per CNI. | P7-1 | `bats --tap --filter 'P7 erratum: severance claim is scoped per CNI' d2-signalloom/test/residual-risk-completeness.bats` | **PASSED**: `1..1`, scoped CNI erratum guard passed. The filter had one declared match; no zero-match acquittal occurred. | `e737972116d0e95d592cb11713601dddb88dccf1` | MEASURED |

## Consolidated gate result

**REFUSE CLOSURE.** The restored artefacts enabled further measurement, which found
live cluster prerequisites absent, a no-daemonset severance failure, an incomplete
cycle, an insufficient containment-reconcile proof, and missing P7 suite registration.
The remaining staged modifications mean the worktree is not a clean committed-tree
execution environment. This governor records those facts and does not repair them.

## Required completion audits

- **Falsification sweep:** P7 targeted mutations passed (`1..4`); P1/P6 mutation
  proofs refused to provide a result because their baselines were red, and the generic
  guard proof was terminated after its self-test. This is a failed consolidated sweep.
- **Both-lane run and arithmetic:** no full lane run was possible after prerequisite
  failures. Static extraction measured 61 demo declarations, 58 CI declarations, and
  58 common declarations; the three demo-only suites are named in the transcript.
  No passed-plus-skipped runtime arithmetic is claimed.
- **Pipeline registration audit:** generic dual-lane guard passed, but P7’s own suite
  reported zero matching residual-risk stages in `scripts/ci/vm-pipeline.sh`; the
  full residual-risk suite therefore exits `1`. The dedicated admin-tier suite is also
  absent from both pipeline files. Those gaps independently block bullets two and six.
- **Completion check:** `kanban-check.sh --repo /home/andy/src/cp/osramp-demo
  --shortcode STUN progress` reported `in_progress=1` for P7-GOV. Its doctor also
  reported graph-integrity, base-ref, and historical state-oscillation exceptions.
  Therefore the mission is not terminal.
- **Cost accounting:** the exact mandated invocation rejected `--update-table` as an
  unknown argument. The installed bundled tool cannot update the decomposition table
  using the reviewed card’s required syntax.

## Merge transcript

```text
pwd
/home/andy/src/.worktrees/osramp-demo/stun-under-flux/governor

git -C /home/andy/src/.worktrees/osramp-demo/stun-under-flux/governor show -s --format='before=%H%nsubject=%s%nparent=%P' HEAD
before=e737972116d0e95d592cb11713601dddb88dccf1
subject=feat(signalloom): residual-risk matrix, completeness tests, and parent erratum (STUN-P7-1)
parent=3ae13b0d7465fa6a3e050323676ec225624f0374

git -C /home/andy/src/.worktrees/osramp-demo/stun-under-flux/governor merge-base --is-ancestor e737972116d0e95d592cb11713601dddb88dccf1 HEAD
exit=0
```

No remote was contacted or pushed.
