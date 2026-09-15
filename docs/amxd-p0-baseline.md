# AMXD-P0 — Mission Baseline

The AgentMaxxing Interactive Demo Console (AMXD) mission starts from the commit
recorded here. Every later AMXD card cites this note instead of re-deriving the
baseline.

## Baseline commit

| Field | Value |
| :--- | :--- |
| Commit SHA | `2fedff0610b16682128cbcfac42eff9025320a53` |
| Authored | `2026-09-14T23:15:04+01:00` |
| Subject | `feat(stun-sentinel): enforce governance credential validation on stun route and record P6-2 ledger` |
| Integration branch | `refs/heads/integration/amxd-v0.1.0` → `2fedff0610b16682128cbcfac42eff9025320a53` |
| Working tree at capture | clean (`git status --porcelain` → 0 lines) |

**Baseline-of-record vs current tip — two distinct hashes, stated explicitly.**
At capture time `integration/amxd-v0.1.0` and the task worktree HEAD were the
same object, `2fedff06`. P0 then committed two commits onto its detached task
HEAD; **the `integration/amxd-v0.1.0` ref itself has not moved** — the phase
Governor advances it.

| Hash | What it is | Downstream cards |
| :--- | :--- | :--- |
| `2fedff0610b16682128cbcfac42eff9025320a53` | **baseline-of-record** — the pre-AMXD tree every measurement below was taken against | what the mission started from |
| `caa8f4c5d109f6d6e7077f744694ff7cabf13a1f` | P0 commit 1 — this note | — |
| `1d847ac6ee8645891cd39bbbc95e0c120461c6e3` | **current P0 tip** — proposal errata + P0 row | **branch from here once merged** |

`git merge-base --is-ancestor integration/amxd-v0.1.0 HEAD` exits 0.

**Every measurement in this note was re-run at the P0 tip `1d847ac6` and is
unchanged from the baseline-of-record** — doctor still 1 exception / 29
fast-exit tasks, `link-check` still `✓ all six rules pass` / `CRITICAL=0
FAIL=0 WARN=0`, contract 6/6, host suites 26/26 bats ok with 0 `not ok`. P0's
own commits perturbed nothing. (`link-check` counts the six DAG rules, not
documents, so adding a doc cannot move it.)

**This baseline is shared with two sibling missions.** `2fedff06` is
simultaneously the tip of `refs/heads/integration/sler-v0.1.0` and
`refs/heads/integration/slcd-v0.1.0`. SLER and SLCD cards are branching from the
identical commit, so concurrent edits to `docs/Proposal — *.md` files and to
`test/acceptance/` helpers are a live collision risk for the whole AMXD mission,
not just between AMXD siblings.

## Harness identity — resolved

`scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode AMXD`
exits **1** (`Doctor Status: UNHEALTHY`), raising exactly **one** exception.

**That exception is not an AMXD defect.** Read the doctor's five checks
(`scripts/kanban-check.sh:69-129`):

| # | Check | Board-scoped? | Result |
| :--- | :--- | :--- | :--- |
| 1 | Graph integrity (`link-check`) | yes — passes `--shortcode` | **pass** |
| 2 | Inversions | yes — passes `--shortcode` | **pass** |
| 3 | Duration / fast-exit | **no — `--repo` only** | **fail (29 tasks)** |
| 4 | Zero-output cards | no — `--repo` only | **pass** |
| 5 | `.kagent-preflight-proof.json` | repo file | **pass** (VALID) |

Only check 3 failed, and check 3 is repo-scoped, not board-scoped: it sweeps the
kanban runtime's whole task history for `/home/andy/src/cp/osramp-demo` across
every mission that has ever run there. The 29 fast-exit tasks it names
(`26376`, `80198`, `4f3dd`, `1d2b1`, `2f42d`, `test-card-*`, …) are historical
crashes from prior boards.

**Proof that none of them is AMXD:** the AMXD board holds 28 tasks —
`backlog=27, in_progress=1` — and the single `in_progress` task is P0 itself.
No AMXD task other than P0 has ever been started, so no AMXD task can appear in
a completed-task duration sweep.

The AMXD-scoped evidence is green:

```
$ kanban-check.sh link-check --repo /home/andy/src/cp/osramp-demo --shortcode AMXD
RESULTS
=======
✓ all six rules pass

Counts:  CRITICAL=0  FAIL=0  WARN=0

$ kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode AMXD progress
BOARD: backlog=27  in_progress=1
HEALTH: ✓ healthy
```

### The acceptance rule for later cards is set-containment, NOT "exit 1 is expected"

"Doctor exits 1" is one bit, and it is a **useless oracle**: if an AMXD card
crashes a task, check 3 still exits 1, masked behind the 29 pre-existing
failures. The full baseline failure set is therefore committed at
`docs/amxd-p0-baseline/doctor-fastexit-baseline-set.txt` (29 task IDs, sorted).

> **Rule for every later AMXD card:** the run is clean iff the check-3 failure
> set is a **subset** of that file. A task ID not in it is a real regression,
> whatever the exit code says.

```bash
diff <(scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode AMXD 2>&1 \
        | sed -nE 's/^  ✗ Task ([^ |]+).*/\1/p' | sort) \
     docs/amxd-p0-baseline/doctor-fastexit-baseline-set.txt
# lines starting '<' are NEW failures. Anything else is inherited.
```

**This reasoning has an expiry date.** The proof that no AMXD task can appear in
check 3 rests on no AMXD task having ever finished. **The moment AMXD-P1
completes, check 3's scope includes AMXD** and the "not our defect" argument
stops holding. From P1 onward, use the set-containment rule above — do not cite
the P0 argument.

**Flag order matters.** `doctor` parses `--repo` / `--shortcode` only after the
subcommand (`scripts/kanban-check.sh:33-60`); with no `--repo` it defaults to
`REPO_ROOT`, the script's *own* checkout (line 38), and with no `--shortcode` it
defaults to `KAGENT` (line 39) — so a mis-ordered invocation silently audits the
wrong board rather than erroring.

## Dashboard build — clean on the baseline

`d2-signalloom/apps/dashboard-signalloom`, at `2fedff06`, before any AMXD change:

| Command | Exit | Result |
| :--- | :--- | :--- |
| `npm ci` | 0 | 342 packages installed from `package-lock.json` |
| `npx vite build` | 0 | `✓ built in 2.66s`, largest chunk `index-C4WCu_e2.js` 438.92 kB (gzip 135.83 kB) |
| `npm run typecheck` (`tsc --noEmit`) | 0 | clean |
| `npm run lint` (`eslint src/ --max-warnings 0`) | **1** | **83 errors, 6 warnings across 42 files — pre-existing** |

### Toolchain identity — so the install is reproducible, not just "342 packages"

| Field | Value |
| :--- | :--- |
| `node -v` | `v26.8.1` |
| `npm -v` | `11.19.0` |
| `package.json` sha256 | `697e9200ffc375b8268dbfee919111dbafb905f2df1a59e42bae8996c8822559` |
| `package-lock.json` sha256 | `277cb04ef23263510b6adfd3334ff5e0cadc0b1e3944f6c823cca8a9350fefc6` |
| Exact install command | `npm ci --cache /tmp/amxd-p0-npm-cache` (see hazard 2 below — the `--cache` is not optional) |
| Resolved tool versions | `vite 5.4.21`, `vitest 3.2.7`, `tsc 5.9.3`, `eslint 9.39.5` |

### Pre-existing lint debt (NOT caused by AMXD)

Recorded so a later card's red `lint` is not misattributed to AMXD work:

```
 47  @typescript-eslint/no-unused-vars
 32  @typescript-eslint/no-explicit-any
  5  react-hooks/exhaustive-deps
  2  @typescript-eslint/no-require-imports
  1  react-hooks/rules-of-hooks
  1  no-empty
```

`npm run lint` **cannot pass on this baseline.** Any AMXD card that gates on a
green `lint` must either scope eslint to its own new files or accept the
83-error floor. Clearing the debt is out of scope for AMXD and would touch files
owned by other cards.

A count is not an identity — a card that removes one error and adds another
leaves 83 unchanged. The full inventory is committed as
`docs/amxd-p0-baseline/eslint-baseline.txt` (89 sorted
`path:line:severity:rule` rows). Compare against it, not against the number:

```bash
diff <(cd d2-signalloom/apps/dashboard-signalloom && npx eslint src/ -f json 2>/dev/null \
        | python3 -c "import json,sys,os
for f in json.load(sys.stdin):
    p=os.path.relpath(f['filePath'],os.getcwd()+'/../../..')
    for m in f['messages']: print(f\"{p}:{m['line']}:{m['severity']}:{m.get('ruleId')}\")" | sort) \
     docs/amxd-p0-baseline/eslint-baseline.txt
```

**Good news for P1-5:** the `lint` script is `eslint src/`, scoped to the
dashboard's own source. `test/acceptance/helpers.ts` — the file P1-5 edits — is
**outside that scope** and carries none of the 83 errors, so P1-5's work cannot
be confused with the inherited debt.

### Documented `package.json` scripts — all resolve as written

| Script | Definition | Verified |
| :--- | :--- | :--- |
| `dev` | `vite` | `vite/5.4.21` resolves |
| `build` | `tsc && vite build` | both halves run clean |
| `typecheck` | `tsc --noEmit` | exit 0; `tsc 5.9.3` |
| `lint` | `eslint src/ --max-warnings 0` | runs; exit 1 on pre-existing debt; `eslint v9.39.5` |
| `test` | `vitest` | `vitest/3.2.7` resolves |

**`npm run test` enters watch mode and will hang a non-interactive agent** —
bare `vitest` has no `--run`. The estate target avoids this:
`make demo-agentmaxxing-ui-test` runs `bun x vitest run …`. Use `--run`.

**The dashboard carries two lockfiles** — `package-lock.json` (248 KB) and
`bun.lock` (117 KB), plus `bunfig.toml`. P0's build path is npm; the mission's
declared test path (`demo-agentmaxxing-ui-test`, and the phase constitution's
`bun run test --run` / `bun run typecheck`) is bun. Nothing keeps them in sync.

## AMXO foundation — still certified

The AgentMaxxing backend this mission builds on, re-run on the baseline:

| Target | Exit | Detail |
| :--- | :--- | :--- |
| `make demo-agentmaxxing-contract-test` | 0 | `test/signalloom/operator-identity.bats` — 6/6 ok |
| `make demo-agentmaxxing-host-test` | 0 | 73 assertions, 0 failures (see below) |

`demo-agentmaxxing-host-test` is five suites:

```
python3 -m unittest (agentmaxxing-host-sensor)      Ran 41 tests … OK
pytest test_audit_ingest.py -k nono/process/…        6 passed, 31 deselected
bats agentmaxxing-host-confinement.bats             11/11 ok
bats file-validator-anti-escape.bats                 9/9  ok
bats hasher-toctou.bats                              6/6  ok
```

Counts are not identities here either — the **test names** are committed at
`docs/amxd-p0-baseline/amxo-test-names.txt` so a card that deletes one test and
adds another cannot hide behind an unchanged `6/6`.

**A green AMXO suite says nothing about the AMXD console.** These cover the host
sensor, enrollment, confinement and ingest backends. None of them touches
`dashboard-signalloom`. There is no UI coverage of `/demos/agentmaxxing` at this
baseline — and no such route exists yet (see below).

## The proposal exists twice, and both copies are real files

Worth knowing before any card edits the proposal. There are **two independent
files** (distinct inodes, neither a symlink, no hardlink):

| Copy | Path | Role |
| :--- | :--- | :--- |
| Repo | `docs/Proposal — Signal Loom AgentMaxxing Interactive Demo Console (2026-Q3).md` | git-tracked; **89 commits** already touch `docs/Proposal*` |
| Vault | `~/Documents/Obsidian/v1/2. Areas/CEO/Enhancement Proposals/Proposal — … .md` | Andy's reading surface; Obsidian rewrites its frontmatter |

At the baseline they differ in **exactly two frontmatter lines** — YAML quoting
of `obsidianProject:`, and `updated:` (vault `2026-09-14T22:54` vs repo
`2026-09-13T22:00`). **The body is byte-identical.** Same document, two homes,
drifting only in frontmatter.

Consequence for later cards: an errata block written only to the vault copy
never reaches `integration/amxd-v0.1.0` and no card branching from it will see
it. Write the repo copy and commit; mirror to the vault through the bridge
(`obsidian-modify` / `obsidian-append`), never by a direct `Write` — Obsidian
has the note buffered and a direct write races its auto-save.

## Card premises — re-verified on the baseline

The AMXD card asserts four repository facts. All four hold at `2fedff06`:

| Premise | Probe | Result |
| :--- | :--- | :--- |
| `nginx.conf` contains **zero** `location /v1/` blocks | `grep -c 'location /v1/'` | **0** (of 24 `location` blocks total) — confirmed |
| `/demos/agentmaxxing` route does not exist yet | `grep -rn 'demos/agentmaxxing' src/` | **0 hits** — confirmed; arrives at P2-1 |
| Acceptance harness defaults to fixtures | `test/acceptance/helpers.ts:108` | `const demoMode = opts?.demoMode ?? true;` — confirmed |
| Spec-coverage gate exists | `ls test/acceptance-spec-coverage.bats` | present — confirmed |

## Environment hazards found during preflight

Two host-level traps that will bite any later card that runs the dashboard
build. Neither is a repository defect.

### 1. `node_modules` is a symlink into the principal checkout — shared mutable state

A task worktree ships
`d2-signalloom/apps/dashboard-signalloom/node_modules` as a **symlink** to
`/home/andy/src/cp/osramp-demo/d2-signalloom/apps/dashboard-signalloom/node_modules`
— the principal checkout's directory, shared by the principal working tree and
by sibling task worktrees (confirmed identical on `00043` and `01c2d`). It is
gitignored via `.git/info/exclude:316`, so it never shows in `git status`.

**`npm ci` deletes `node_modules` before reinstalling.** Run as literally
specified, it mutates the principal checkout's dependency tree — which is
exactly the "never edit a sibling worktree" boundary, and would hand a
concurrently-building sibling card a half-deleted `node_modules`.

P0 therefore `unlink`ed the symlink (removing the link, never the target;
target verified intact at 342 packages afterwards) and installed a **real,
worktree-local** `node_modules`. Later cards that need `npm ci` should do the
same:

```bash
cd d2-signalloom/apps/dashboard-signalloom
test -L node_modules && unlink node_modules     # NEVER rm -rf: it follows the link
npm ci --cache /tmp/<card>-npm-cache
```

### 2. `npm ci` fails with a misleading "root-owned files" error

The first `npm ci` died at exit **243**:

```
npm error Your cache folder contains root-owned files, due to a bug in previous
npm error versions of npm which has since been addressed.
npm error To permanently fix this problem, please run:
npm error   sudo chown -R 1000:1000 "/home/andy/.npm"
```

**The diagnosis is wrong and the suggested fix is a no-op.** `/home/andy/.npm`
is `drwxr-xr-x andy:andy`, and a sweep for non-`andy`-owned files under it
returns **zero**. The real cause is the agent sandbox denying writes to that
path — `touch /home/andy/.npm/<probe>` returns `Permission denied` against a
directory the user owns and has `w` on. npm reports EACCES as an ownership bug.

Fix without sudo, and without touching the shared cache:

```bash
npm ci --cache /tmp/<card>-npm-cache      # exit 0, 342 packages
export npm_config_cache=/tmp/<card>-npm-cache   # for the npx/vite calls that follow
```

## Reproduction

```bash
cd <task-worktree>
git rev-parse HEAD                      # 2fedff0610b16682128cbcfac42eff9025320a53
git status --porcelain                  # empty
scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode AMXD
cd d2-signalloom/apps/dashboard-signalloom
test -L node_modules && unlink node_modules
npm ci --cache /tmp/amxd-npm-cache && npx vite build
cd - && make demo-agentmaxxing-contract-test && make demo-agentmaxxing-host-test
```
