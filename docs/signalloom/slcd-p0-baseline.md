# SLCD-P0 — Detective monorepo baseline

Recorded 2026-09-15 00:01:57+01:00 by SLCD-P0 (preflight) at commit `2fedff0610b16682128cbcfac42eff9025320a53`.

Every fact below was produced by running the command shown, in this repository, at that
commit. Later SLCD cards **cite this document** rather than re-deriving these facts. Where a
fact is point-in-time rather than permanent, it says so explicitly.

---

## 1. Mission identity

| Field | Value |
| :--- | :--- |
| Canonical repository | `/home/andy/src/cp/osramp-demo` |
| Shortcode | `SLCD` |
| Integration branch | `refs/heads/integration/slcd-v0.1.0` = `2fedff0610b16682128cbcfac42eff9025320a53` |
| Default branch | `origin/main` = `df65bb2e767fe5f0585e23da57a7756d876c98cc` |
| Board state at P0 | 30 cards — 29 backlog, 1 in_progress (P0). `HEALTH: ✓ healthy` |

**Provenance of the integration branch is confirmed, not assumed.** After `git fetch origin
--prune`, `git merge-base --is-ancestor origin/main integration/slcd-v0.1.0` exits 0 — the
branch descends from the fetched remote tip, so it did not silently drop commits merged by
other missions. The branch is **local-only**; `git rev-parse origin/integration/slcd-v0.1.0`
returns `fatal: Needed a single revision`. It was not pushed, because the SLCD card contract's
Safety Rules (`never push to a remote`) outrank the Deliverables line that asked for a push.
See the SLCD-P0 errata block in the proposal.

## 2. Target components — all three present

```
PRESENT  d2-signalloom/apps/agentmaxxing-host-sensor
PRESENT  d2-signalloom/apps/signal-ingest
PRESENT  d2-signalloom/apps/dashboard-signalloom
```

The four canonical locations the proposal names are **absent**, as expected — this mission
creates them. Recorded so a later card does not mistake absence for a lost merge:

```
ABSENT   d2-signalloom/apps/agentmaxxing-host-sensor/detective.py
ABSENT   d2-signalloom/apps/signal-ingest/telemetry_handler.go
ABSENT   d2-signalloom/apps/dashboard-signalloom/src/components/CodingAgentsTab.tsx
ABSENT   d2-signalloom/test/coding-agent-telemetry.bats
```

Host-sensor tests are flat `test_*.py` in the package root. There is no `tests/` subdirectory.

## 3. Acceptance commands — run, not read

Each was executed at this commit. Exit status is the recorded evidence.

| Command | Result |
| :--- | :--- |
| `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLCD` | **exit 1** — see §4 |
| `bats test/acceptance-spec-coverage.bats` | **exit 0** — `1..7`, 7/7 ok |
| `cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py'` | **exit 0** — `Ran 41 tests … OK` |
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **exit 0** — 24 packages ok, 1 `[no test files]` |
| `make demo-agentmaxxing-host-test` | **exit 2 first run, exit 0 on re-run** — see §6 |

### 3.1 Go commands MUST `cd` into the module

There is **no root `go.mod` and no `go.work`.** `d2-signalloom/apps/signal-ingest/go.mod`
declares `module github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest`
(`go 1.24.1`). There are 20 separate `go.mod` files under `d2-signalloom/`.

The control was run rather than argued. From the repository root:

```
$ go test ./...
pattern ./...: directory prefix . does not contain main module or its selected dependencies
FAIL	./... [setup failed]        # exit 1
```

**Every Go test command in this mission must `cd d2-signalloom/apps/signal-ingest` first.**
Note also that `make demo-agentmaxxing-ingest-test` sets `GOPATH=/tmp/gopath
GOMODCACHE=/tmp/gomodcache`; a bare `go test` inherits the user cache instead.

## 4. The doctor gate — exit 1 is correct here, and is not SLCD's to fix

The doctor exits 1. **Both board-scoped checks are green**; the single exception is
workspace-wide and inherited.

| # | Check | Scope | Result |
| :--- | :--- | :--- | :--- |
| 1 | Graph integrity (`link-check --shortcode SLCD`) | board | ✓ all six rules pass — `CRITICAL=0 FAIL=0 WARN=0` |
| 2 | Inversions (`--shortcode SLCD`) | board | ✓ no inverted edges detected |
| 3 | Duration / fast-exit | **workspace-wide** | ✗ 29 tasks (the only exception) |
| 4 | Zero-output cards | repo-wide | ✓ PASS |
| 5 | `.kagent-preflight-proof.json` | repo file | ✓ (no exception raised) |

`scripts/kanban-check.sh:90` invokes `"$0" duration-check --repo "$repo"` — **it does not
forward `--shortcode`.** `duration-check` reads
`~/.cline/kanban/workspaces/osramp-demo/sessions.json` (302 entries) and inspects every task in
state `awaiting_review|completed|trash|done`, across all missions that ever ran in this
workspace. Positive evidence that none of them is ours:

- Session keys matching `/SLCD/`: **0** (of 302).
- Fast-exit entries matching `/SLCD/`: **0**.
- The fast-exit population spans `2026-09-01T21:56Z` → `2026-09-13T12:06Z`, all predating SLCD.
- Between the doctor run and a re-derivation minutes later the count moved **29 → 32**, because
  sibling missions are running concurrently. The set is not under SLCD's control.

**Do not treat "exit 1" as the oracle** — a genuine new SLCD crash would also exit 1, masked
behind the inherited ones. Test *containment* against this baseline set instead:

```bash
diff <(scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLCD 2>&1 \
        | sed -nE 's/^  ✗ Task ([^ |]+).*/\1/p' | sort) \
     docs/signalloom/slcd-p0-fast-exit-baseline.txt
```

The baseline set as of this commit is committed alongside this document at
`docs/signalloom/slcd-p0-fast-exit-baseline.txt`. **This argument expires the moment the first
SLCD card reaches a finished state** — from then on, a new ID in the set may genuinely be ours.

Two further traps in the same script: options parse only *after* the subcommand; absent
`--repo` it defaults to the script's own checkout and absent `--shortcode` to `KAGENT`
(`scripts/kanban-check.sh:38-39`) — a mis-ordered call silently audits the wrong board rather
than erroring.

## 5. Export-surface baseline — numeric-only, and this is point-in-time

`filter.py:33-47` allow-lists **bounded integers and enums only**. There are **zero free-text
fields** on the export surface today:

```python
ALLOWLISTED_PROCESS_ATTRIBUTES = {health_state, cpu_time_ms, resident_memory_bytes,
                                  exit_code, restart_count}
EXTENDED_PROCESS_ATTRIBUTES    = ALLOWLISTED ∪ {cpu_percent, pid, ppid}
```

**This is a starting condition, not a property of the collector.** SLCD is about to invalidate
it: `harness`, `session_id`, `comm`, `inference_endpoint`, `task_id` and `shortcode` in the
proposal's record shape are all string-carrying. P1-1 must cite this section as the baseline it
is changing, and P1-2's leak falsification must assume a string-carrying surface, not this one.

Note the two enforcement layers are **not** equivalent:

- `proc.py:103-110` (`_safe_proc_path`) is a genuine **pre-collection** chokepoint — it raises
  `SecurityException` *before* `open()`.
- `filter.py` is **post-hoc** — `collector.py` reads into objects first and filters on export.

So `filter.py` alone cannot stop a payload that was already read into memory.

## 6. `make demo-agentmaxxing-host-test` — a real flake, with a named cause

First run: **exit 2**, failing `test/signalloom/file-validator-anti-escape.bats` test 9
(`pytest suite for file validator …`). Re-run at the same commit: **exit 0**. The bats
assertion is `[ "$status" -eq 0 ]` and does not echo `$output`, so the failing run leaves no
pytest detail in the log — the reproduction had to be done separately.

Root cause, from the direct pytest run:

```
PytestCacheWarning: cache could not write path
  /home/andy/src/.worktrees/<id>/osramp-demo/.pytest_cache/v/cache/nodeids:
  [Errno 13] Permission denied
```

`.pytest_cache` in every task worktree is a **symlink to
`/home/andy/src/cp/osramp-demo/.pytest_cache`** — the principal checkout. Roughly forty
concurrent worktrees write the same cache directory, so the `Errno 13` is cross-worktree
contention, not a repository defect and not a permissions bug to "fix" by chmod. The bats test
invokes pytest **without** the `-o cache_dir=…` override that the sibling Makefile recipes use
(`-o cache_dir=/tmp/pytest_cache_fe`).

**Guidance for downstream cards:** a single red run of this target is not evidence of a
regression. Re-run once, and if it reproduces, capture pytest output directly before
concluding. P6 may wish to add `-o cache_dir=/tmp/pytest_cache_slcd` to that bats invocation —
that is a P6 decision, out of scope for P0.

## 7. Test side effect — one tracked file is mutated

`cd d2-signalloom/apps/signal-ingest && go test ./...` (package `correlation`, ~16.6s) rewrites
the **git-tracked** fixture `d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json`
(12 insertions / 12 deletions). A dirty tree after a Go test run is expected. Inspect the
verdict fields, then `git checkout --` the file before staging. P0 did exactly this; the
committed tree excludes it.

---

## 8. Two architectural contradictions found at P0 — escalated, not resolved

Both were falsified by running the guard, not by reading it. Full detail and the STOP-and-report
rationale are in the SLCD-P0 errata block in the proposal. Summarised here because later cards
will hit them:

**(a) Socket Inode Attribution cannot be built through `ProcReader`.** The Shared Patterns
constitution specifies detecting outbound model traffic "by matching local socket inodes from
`/proc/net/tcp` to process file descriptors under `/proc/<pid>/fd/`". `proc.py:14-32` lists
`fd`, `fdinfo` **and** `net` in `PROHIBITED_PROC_ENTRIES`, and `_safe_proc_path` raises on each:

```
BLOCKED  fd      -> SecurityException: reading /proc/[pid]/fd is strictly prohibited …
BLOCKED  net     -> SecurityException: reading /proc/[pid]/net is strictly prohibited …
BLOCKED  fdinfo  -> SecurityException: reading /proc/[pid]/fdinfo is strictly prohibited …
```

Removing an entry from that set is a declared hard blocker. **P4-2 owns this; it must not
resolve it by editing the prohibited set.**

**(b) The `cmdline` basename carve-out does not exist in code.** The constitution permits
reading `/proc/<pid>/cmdline` "for bounded binary basename resolution". `cmdline` is in the
prohibited set and `_safe_proc_path` raises on it unconditionally. Harness identification at
P2-2 therefore has only `comm` from `/proc/<pid>/stat`, which is read back successfully
(`ProcReader().read_stat(pid).comm`) but carries only the short binary name — enough to
distinguish `claude` from `codex`, not enough to recover an invocation. P0 did **not** probe
the kernel's `comm` length cap; P2-2 must establish empirically whether the harnesses it needs
to tell apart remain distinguishable after truncation. **P2-2 owns this.**

Neither contradiction is P0's to fix. P0's job was to find them before 29 cards committed to a
shape that assumes them away.
