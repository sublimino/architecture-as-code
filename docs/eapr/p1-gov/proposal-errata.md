#### Errata — EAPR-P1-GOV Phase 1 Governor

**Created:** 2026-09-23 20:44:10-05:00
**Last Updated:** 2026-09-24 13:16:13+01:00
**Result:** Failed at fifteen-suite gate; Phase 1 not certified
**Predecessors:** none
**Repository evidence:** pending this correction commit; never amend

**Decision:** `status=fail`, `proceed=no`. Andy's provenance ruling resolves
the prior false positive: EAPR-P1-2 is a tooling-only card delivered directly
to `~/.andy_sync` master and needs no osramp-demo branch. The next mandatory
gate is genuinely red, so no integration merge was attempted.

**Step 0 dependency evidence:**

| Dependency | Latest proposal marker | Evidence |
| :--------- | :--------------------- | :------- |
| EAPR-P1-1 | `status=pass proceed=yes` | `36302b49fe304ddf6c6093ec8445d036e1dbfbda`, commit, branch ancestor rc 0 |
| EAPR-P1-2 | `status=pass proceed=yes` | Andy's direct-to-`~/.andy_sync` master ruling; eleven D11 commits through `905dc0629ab8bf196439d78e0f88a23cb6ef7a24` plus P1-1 env fix |
| EAPR-P1-3 | `status=pass proceed=yes` | `1d15a906bcb4632d148f2f56468f3caefa336454`, commit, branch ancestor rc 0 |
| EAPR-P1-4 | `status=pass proceed=yes` | `4621df93ed63e085abb90478a544e1904bad1ad4`, commit, branch ancestor rc 0 |

Starting integration tip:
`68d87aca666b28fbdd96c48bdeca881fcf7fef25`. The movement from original
baseline `844afa5acd2bef019641bb915bc8a63aa9c6e0d4` is fully explained by
three governor-evidence documentation commits. Each of the five constituent
refs matches its recorded SHA and is an ancestor of EAPR-P1-4. P1-4's
`844afa5a..EAPR-P1-4` rev-list count is `41`.

Positive-control withdrawal check: the latest SLED-P4-GOV and SLTE-P4-GOV
blocks both read `status=fail proceed=no blocking_drift=yes`, proving the
extractor reads the latest errata block rather than the historic heading.

**Suite table:**

| Gate | Result | Evidence |
| :--- | :----- | :------- |
| Fifteen kanban BATS suites | **FAIL** | 375 loaded; 369 passed; 6 failed; 0 skipped; runner rc 1 |
| TAP skip scan | PASS | `RG_SKIP_COUNT=0` |
| Eleven-row mutation ledger | NOT RUN | mandatory suite STOP fired first |
| Forged proposal-marker proof | NOT RUN | mandatory suite STOP fired first |
| Zero-output advancement proof | NOT RUN | mandatory suite STOP fired first |
| SLEA doctor | NOT RUN | mandatory suite STOP fired first |
| SLET doctor | NOT RUN | mandatory suite STOP fired first |
| SLES doctor | NOT RUN | mandatory suite STOP fired first |
| SLED doctor | NOT RUN | mandatory suite STOP fired first |
| osramp offline acceptance gates | NOT RUN | no integration after suite failure |

Aggregate output captured separately from the TAP by the runner and preserved
in repository evidence:

```text
SUMMARY expected=375 executed=375 passed=369 failed=6 skipped=0 runner_rc=1
RG_SKIP_COUNT=0
```

Failing suite: `test/ajm-cline-kanban-proposal-to-card.bats`.

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
Per the governor boundary the failures return to P1-2; this governor made no
tooling fix.

**Spend and token use:**

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| EAPR-P0 | $0.00 | in 8.4M; out 32.6k; reason 15.3k; cache 3.8M | 23m23s | cpai://open?id=ses_f2f509972ffePjXyS72PeFsCb0&dir=/home/andy/.cline/worktrees/f1ef7/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |
| EAPR-P1-PRE | $0.00 | N/A — subscription | 8m | cpai-opencode-fast |
| EAPR-P1-1 | $0.00 | N/A — subscription | 3m01s | kpai://open?id=eaee6&dir=/home/andy/.cline/worktrees/eaee6/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-2 | $0.00 | N/A — subscription | 9m46s | kpai://open?id=6c8e4&dir=/home/andy/.cline/worktrees/6c8e4/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-3 | $0.00 | N/A — subscription | 11m23s | kpai://open?id=027af&dir=/home/andy/.cline/worktrees/027af/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-4 | $0.00 | N/A — subscription | 3m33s | kpai://open?id=7a512&dir=/home/andy/.cline/worktrees/7a512/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-GOV | $0.00 | in 2.9M; out 25.9k; reason 10.7k; cache 4.6M | 12m17s | cpai://open?id=ses_f2cbb798affeoneTjOXt6osxe1&dir=/home/andy/.cline/worktrees/7ce29/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| EAPR-P2-PRE | $0.00 | in 1.8M; out 18.2k; reason 8.4k; cache 2.9M | 5m | cpai://open?id=d04e1&dir=/home/andy/.cline/worktrees/d04e1/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P2-1 | $0.00 | N/A — no session | 10h29m47s | cpai://open?id=065d0&dir=/home/andy/.cline/worktrees/065d0/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P2-2 | $0.00 | N/A — no session | 5m03s | cpai://open?id=09abb&dir=/home/andy/.cline/worktrees/09abb/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P2-3 | $0.00 | N/A — no session | 1m23s | cpai://open?id=5ef56&dir=/home/andy/.cline/worktrees/5ef56/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P2-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=db6b2&dir=/home/andy/.cline/worktrees/db6b2/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=6f8d4&dir=/home/andy/.cline/worktrees/6f8d4/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-1 | $0.00 | N/A — no session | N/A | cpai://open?id=59904&dir=/home/andy/.cline/worktrees/59904/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-2 | $0.00 | N/A — no session | N/A | cpai://open?id=201c9&dir=/home/andy/.cline/worktrees/201c9/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-3 | $0.00 | N/A — no session | N/A | cpai://open?id=6e4be&dir=/home/andy/.cline/worktrees/6e4be/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-4 | $0.00 | N/A — no session | N/A | cpai://open?id=1803c&dir=/home/andy/.cline/worktrees/1803c/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-5 | $0.00 | N/A — no session | N/A | cpai://open?id=9f403&dir=/home/andy/.cline/worktrees/9f403/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P3-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=507ea&dir=/home/andy/.cline/worktrees/507ea/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=b3cf4&dir=/home/andy/.cline/worktrees/b3cf4/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-1 | $0.00 | N/A — no session | N/A | cpai://open?id=ecc1d&dir=/home/andy/.cline/worktrees/ecc1d/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-2 | $0.00 | N/A — no session | N/A | cpai://open?id=fd1cd&dir=/home/andy/.cline/worktrees/fd1cd/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-3 | $0.00 | N/A — no session | N/A | cpai://open?id=28f30&dir=/home/andy/.cline/worktrees/28f30/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-4 | $0.00 | N/A — no session | N/A | cpai://open?id=0aaf7&dir=/home/andy/.cline/worktrees/0aaf7/osramp-demo&host=fortuna&model=coding_medium |
| EAPR-P4-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=15d5e&dir=/home/andy/.cline/worktrees/15d5e/osramp-demo&host=fortuna&model=coding_medium |

The initial board snapshot already showed EAPR-P2-1 in progress. This governor
did not start, restart, approve, or alter any P2 card.

**Required remediation:** return the six failures to P1-2. Re-run this governor
from the fifteen-suite gate only after all 375 tests pass with zero skips.

Human final review required before any P2 card starts

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
