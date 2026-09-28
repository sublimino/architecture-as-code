# EAPR-P1-GOV Phase 1 Certification Refusal Evidence

Created: 2026-09-23 20:44:10-05:00
Last Updated: 2026-09-24 13:16:13+01:00

## Verdict

Phase 1 is not certified. Andy's provenance ruling resolves the earlier false
positive: EAPR-P1-2 is a tooling-only card delivered directly to
`~/.andy_sync` master, so no osramp-demo branch is required. Certification now
stops at the next declared hard gate: the complete fifteen-suite tooling run is
red. Phase 2 remains blocked. Predecessor governors: none.

## Repository boundary

- Worktree: `/home/andy/src/.worktrees/osramp-demo/eapr-v0.1.0/governor`
- Branch: `integration/eapr-v0.1.0`
- Starting integration tip: `68d87aca666b28fbdd96c48bdeca881fcf7fef25`
- Original Phase 1 baseline: `844afa5acd2bef019641bb915bc8a63aa9c6e0d4`
- Starting tracked status: clean
- Existing movement since baseline: three explained governor-evidence commits

## Step 0 prerequisite evidence

The canonical proposal's latest blocks record `status=pass proceed=yes` for
EAPR-P1-1 through EAPR-P1-4. The following osramp-demo objects resolve and are
ancestors of their implementation refs:

| Card | Full commit | Object | Branch ancestor rc |
| :--- | :---------- | :----- | :----------------- |
| EAPR-P1-1 | `36302b49fe304ddf6c6093ec8445d036e1dbfbda` | commit | 0 |
| EAPR-P1-3 | `1d15a906bcb4632d148f2f56468f3caefa336454` | commit | 0 |
| EAPR-P1-4 | `4621df93ed63e085abb90478a544e1904bad1ad4` | commit | 0 |

EAPR-P1-2 is satisfied by Andy's explicit ruling over the twelve unsigned
direct-to-master tooling commits. Its recorded eleven D11 commits end at
`905dc0629ab8bf196439d78e0f88a23cb6ef7a24`; P1-1's env-transport fix is the
twelfth relevant commit. The live tooling files are readable and executable in
this sandbox, while `~/.andy_sync/.git` traversal remains denied. The behavioral
suite below therefore tests the delivered live skill independently of that
repository-metadata ruling.

The five constituent refs exactly match their P1-4 recorded SHAs and are
ancestors of EAPR-P1-4. `git rev-list --count 844afa5a..EAPR-P1-4` is `41`.
The latest withdrawal blocks for SLED-P4-GOV and SLTE-P4-GOV both read
`status=fail proceed=no blocking_drift=yes`.

## Fifteen-suite gate

Each suite first parsed successfully through `bats --count`. The sum was 375:

| Suite | Count |
| :---- | ----: |
| ajm-auto-kanban-capacity | 4 |
| ajm-auto-kanban-contract | 36 |
| ajm-auto-kanban-helper-capacity | 3 |
| ajm-auto-kanban-mission-key | 24 |
| ajm-auto-kanban-state | 44 |
| ajm-auto-kanban-subscription-balancing | 7 |
| ajm-cline-kanban-mutation-gates | 45 |
| ajm-cline-kanban-prompt-contracts | 26 |
| ajm-cline-kanban-prompt-cron | 51 |
| ajm-cline-kanban-proposal-to-card | 87 |
| ajm-cline-kanban-shortcode | 10 |
| ajm-cline-kanban-state-oscillation | 2 |
| ajm-cline-kanban-trash-residue | 15 |
| kanban-check-prompt | 9 |
| kanban-max-arg-strlen | 12 |
| **Total** | **375** |

Aggregate summary captured from `/tmp/eapr-p1-gov-bats.tap` by the runner and
preserved in `bats-summary.txt`:

```text
SUMMARY expected=375 executed=375 passed=369 failed=6 skipped=0 runner_rc=1
RG_SKIP_COUNT=0
```

All six failures are in
`test/ajm-cline-kanban-proposal-to-card.bats`:

```text
not ok 273 supervise: the review column is adjudicated every cycle
not ok 299 create: --agent kpai maps to the runtime's kpai id
not ok 300 create: --agent antigravity maps to the runtime's antigravity id
not ok 303 create: a justified non-CPAI agent compiles
not ok 305 create: phase-specific shared patterns reach the compiled prompt
not ok 306 create: general shared patterns fallback reaches the compiled prompt
```

TAP shows test 273 failing its numeric assertion, three create tests unable to
open returned contract paths, and two create tests failing prompt-file
existence assertions. This establishes a red suite; the precise cause and the
exclusion of fixture or environment issues are not established by TAP alone.
The governor did not patch the behavior because that would make the governor
certify its own implementation work.

## Containment

The card's STOP rule says any red tooling suite yields `status=fail`, names the
suite and counts, and returns ownership to P1-2. Consequently the eleven-row
mutation rerun, two standalone impossibility proofs, four doctor runs,
P1-3/P1-4 merges, offline acceptance gates, and integration tag were not run or
claimed. No product code, tooling code, board state, sibling worktree, remote
ref, protected base ref, or proposal status outside this governor was changed.

The initial board snapshot already showed EAPR-P2-1 in progress and three P2
cards blocked. This governor did not start, restart, approve, or alter any P2
card. That pre-existing execution further confirms that the human gate has not
been honored by the surrounding scheduler.

The mechanical cost command completed with rc 0 and updated the proposal table.
Human final review required before any P2 card starts.

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
