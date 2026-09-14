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

`integration/amxd-v0.1.0` and the P0 task worktree HEAD are the **same object**.
`git merge-base --is-ancestor integration/amxd-v0.1.0 HEAD` exits 0.

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

**A green AMXO suite says nothing about the AMXD console.** These cover the host
sensor, enrollment, confinement and ingest backends. None of them touches
`dashboard-signalloom`. There is no UI coverage of `/demos/agentmaxxing` at this
baseline — and no such route exists yet (see below).

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
