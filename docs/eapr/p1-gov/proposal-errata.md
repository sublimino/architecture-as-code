#### Errata — EAPR-P1-GOV Phase 1 Governor

**Created:** 2026-09-23 20:44:10-05:00
**Last Updated:** 2026-09-23 20:50:08-05:00
**Result:** Blocked at Step 0; Phase 1 not certified
**Predecessors:** none
**Repository evidence:** `c5ec8dcb30ba6bf928edb521ac8a482e18323141` followed by `c3b76989` (no amend)

**Decision:** `status=fail`, `proceed=no`. No integration merge was attempted.
The card's explicit STOP condition fired because `refs/heads/EAPR-P1-2` does
not exist in osramp-demo, while the authoritative `~/.andy_sync` commits could
not be inspected live from this sandbox. The directory itself was positively
verified to exist; this is a visibility denial, not an absence claim.

**Step 0 dependency evidence:**

| Dependency | Proposal marker | Recorded osramp-demo evidence | Branch check |
| :--------- | :-------------- | :---------------------------- | :----------- |
| EAPR-P1-1 | `status=pass proceed=yes` | `36302b49fe304ddf6c6093ec8445d036e1dbfbda` | reachable from `EAPR-P1-1` |
| EAPR-P1-2 | `status=pass proceed=yes` | proposal records unchanged osramp tip `844afa5acd2bef019641bb915bc8a63aa9c6e0d4` plus eleven `~/.andy_sync` commits | `EAPR-P1-2` ref missing |
| EAPR-P1-3 | `status=pass proceed=yes` | `1d15a906bcb4632d148f2f56468f3caefa336454` | reachable from `EAPR-P1-3` |
| EAPR-P1-4 | `status=pass proceed=yes` | `4621df93ed63e085abb90478a544e1904bad1ad4` | reachable from `EAPR-P1-4` |

Verbatim prerequisite probes:

```text
EAPR-P1-1 36302b49fe304ddf6c6093ec8445d036e1dbfbda
EAPR-P1-2 fatal: Needed a single revision
EAPR-P1-3 1d15a906bcb4632d148f2f56468f3caefa336454
EAPR-P1-4 4621df93ed63e085abb90478a544e1904bad1ad4
integration/eapr-v0.1.0 844afa5acd2bef019641bb915bc8a63aa9c6e0d4
```

```text
$ git -C /home/andy/.andy_sync rev-parse --show-toplevel
fatal: not a git repository (or any of the parent directories): .git
$ stat -c 'mode=%A type=%F inode=%i' /home/andy/.andy_sync
mode=drwxr-xr-x type=directory inode=88867206
```

**Suite table:**

| Gate | Result | Reason |
| :--- | :----- | :----- |
| Fifteen kanban BATS suites | NOT RUN | authoritative merged skill could not be constructed |
| Eleven-row mutation ledger | NOT RUN | Step 0 STOP condition forbids certification continuation |
| Forged proposal-marker proof | NOT RUN | merged P1-2 gate unavailable for authoritative proof |
| Zero-output advancement proof | NOT RUN | merged P1-2 gate unavailable for authoritative proof |
| SLEA doctor | NOT RUN | certification stopped before Step 4 |
| SLET doctor | NOT RUN | certification stopped before Step 4 |
| SLES doctor | NOT RUN | certification stopped before Step 4 |
| SLED doctor | NOT RUN | certification stopped before Step 4 |
| osramp offline acceptance gates | NOT RUN | certification stopped before integration |

No mutation ledger, impossibility output, doctor return code, acceptance tail,
rev-list count, constituent reachability certification, or integration tag is
claimed. Recording invented or stale values would recreate the hollow-governor
defect Phase 1 exists to remove.

**Independent review:** Cato was unavailable on PATH. A cross-vendor Gemini
reviewer was run once and independently recommended fail-closed. It classified
the missing osramp P1-2 branch as technically plausible for cross-repository
delivery but procedurally blocking under the literal contract, and rejected
creating a cosmetic branch.

**Spend and token use:**

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| EAPR-P0 | $0.00 | in 8.4M; out 32.6k; reason 15.3k; cache 3.8M | 23m23s | cpai://open?id=ses_f2f509972ffePjXyS72PeFsCb0&dir=/home/andy/.cline/worktrees/f1ef7/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |
| EAPR-P1-PRE | $0.00 | N/A — subscription | 8m | cpai-opencode-fast |
| EAPR-P1-1 | $0.00 | N/A — subscription | 3m01s | kpai://open?id=eaee6&dir=/home/andy/.cline/worktrees/eaee6/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-2 | $0.00 | N/A — subscription | 9m46s | kpai://open?id=6c8e4&dir=/home/andy/.cline/worktrees/6c8e4/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-3 | $0.00 | N/A — subscription | 11m23s | kpai://open?id=027af&dir=/home/andy/.cline/worktrees/027af/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-4 | $0.00 | N/A — subscription | 3m33s | kpai://open?id=7a512&dir=/home/andy/.cline/worktrees/7a512/osramp-demo&host=fortuna&model=claude-3-7-sonnet |
| EAPR-P1-GOV | $0.00 | in 2.9M; out 25.9k; reason 10.7k; cache 4.6M | 12m17s | cpai://open?id=ses_f2ef651ffffeg3X5cuALsY4uY1&dir=/home/andy/.cline/worktrees/7ce29/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |

**Required remediation:** provide repository-scoped provenance for P1-2 using
full commit SHAs, object-resolution evidence, ancestry from the intended
`~/.andy_sync` master, and an explicit ruling that direct-to-master delivery
satisfies the reviewed branch gate. Then rerun this governor from Step 0 in an
environment permitted to inspect and test `/home/andy/.andy_sync`.

Human final review required before any P2 card starts

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
