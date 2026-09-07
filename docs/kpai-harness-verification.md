# KPAI Runtime Harness Verification

**Card:** KTEST-P1-1 · **Agent:** `kpai` · **Verified:** 2026-09-07 · **Base ref:** `integration/crkc-v0.1.0`

This document records what the KPAI runtime harness could actually do inside the git worktree
the runtime created for it, under the `nono` Landlock capability sandbox. Every figure below was
measured by `scripts/test-kpai-harness.sh` and is reproducible by re-running it; the machine-readable
form is `.kpai-harness-verified.json` at the repository root.

## Headline finding

**The harness is fully capable while confined.** `NoNewPrivs=1` and an active Landlock LSM coexist
with unrestricted read, write, execute and git access inside the worktree. Twenty-four probes,
twenty-four passes, zero permission errors.

The corollary matters more than the headline: because the confinement is invisible on every path an
agent actually uses, **its presence cannot be inferred from a successful run**. That is why the
sandbox posture is recorded as explicit fields rather than left to be deduced.

### What this does NOT prove

Stated plainly, because the gap is easy to read past and the artifact's green light is narrower than
it looks:

- **It does not prove confinement.** Every write probe here is an *allow-path* probe: it writes
  somewhere the profile permits, and it succeeds identically whether Landlock is enforcing, permissive,
  or absent entirely. An allowed path is not an enforcement control. The claim this document supports
  is "the sandbox is **present** and does not obstruct the worktree", evidenced by `NoNewPrivs=1` and
  a populated `NONO_CAP_FILE` — both of which *would* differ if the sandbox were removed. Whether the
  deny-list actually denies is a separate question this card deliberately does not ask.
- **It does not characterise the deny-list.** Recording that denials are invisible is in scope;
  probing paths outside the worktree to map what is refused is not. That belongs with `CRKC-P3-2`.
- **The canary is not tamper-evidence.** Re-deriving `SHA-256("kpai-harness-canary|v1|" + HEAD)` and
  observing repeatability are two views of the same construction. They detect accidental corruption
  and a changed derivation; they do not detect a fabricated artifact, because anyone regenerating one
  can recompute a documented seed. Treat the canary as an integrity check, never as provenance.

## Environment telemetry

| Facet | Measured value |
| :---- | :---- |
| Kernel | `Linux 7.1.3+deb13-amd64` |
| bun | `1.4.0` |
| bash | `5.2.37(1)-release` |
| git | `git version 2.54.0` |
| SHA-256 implementation | `/usr/bin/sha256sum` |
| `HOME` | `/home/andy` |
| bun directory on `PATH` | `/home/andy/.local/bin` |

## Worktree lineage

| Facet | Measured value |
| :---- | :---- |
| Runtime-supplied `pwd` | `/home/andy/.cline/worktrees/fb84b/osramp-demo` |
| Resolved real path | `/home/andy/src/.worktrees/fb84b/osramp-demo` |
| Principal checkout | `/home/andy/src/cp/osramp-demo` — **not** this tree |
| `HEAD` | `efcf52d616282464e7742d3a64f458b08c5eb74f` |
| Branch | detached (`HEAD`) — expected for a runtime checkout |
| Descends from base ref | yes (`git merge-base --is-ancestor` exit 0) |
| Linked worktree | yes — root `.git` is a regular file, and `--git-dir` differs from `--git-common-dir` |

**The runtime hands the process a symlinked path while git reports the resolved one.** `pwd` returns
`~/.cline/worktrees/...` and `git rev-parse --show-toplevel` returns `~/src/.worktrees/...`. Any check
that compares these two as literal strings fails on a correctly-configured harness. Probe `P17`
resolves `PWD` through `pwd -P` before comparing, for exactly this reason.

## Sandbox posture

| Facet | Measured value |
| :---- | :---- |
| `NoNewPrivs` | `1` — set, one-way, inherited by every child |
| Active LSMs | `lockdown, capability, landlock, yama, apparmor, tomoyo, bpf, ipe, ima, evm` |
| `NONO_CAP_FILE` | `/tmp/.nono-de1ae8d6c1ed147d.json` — present, so a nono profile is live |
| Worktree writable | yes — create, read back, delete round-trip succeeds |
| Scratch dir writable | yes — canary written under `TMPDIR` |
| Permission errors observed | none |

### The caveat that has to be structural

**A Landlock denial and an empty result are byte-identical: nothing on stdout, exit 0.** A bare `ls`,
`fd`, `find` or `which` returning empty means *either* the thing is absent *or* the process was not
allowed to look, and nothing in the output distinguishes them.

Consequently, absence recorded anywhere in the artifact is **absence-as-observed, not proven
non-existence**. The artifact carries this as the boolean field
`sandbox.denial_indistinguishable_from_absence` plus a prose `sandbox.caveat`, rather than as a note
in this document, so that a program consuming the artifact is forced to encounter it. A reader who
skips the docs cannot skip the field.

Deliberately out of scope: this card does **not** map the nono profile's deny-list. Recording that
denials are invisible is in scope; probing paths outside the worktree to characterise them is not.

## The instrument

`scripts/test-kpai-harness.sh` — 24 probes across four capability groups (locate, read git state,
write, execute tools). Three design choices are load-bearing and are enforced by tests rather than
by convention:

- **No `set -e`.** Errexit aborts at the first failing probe, so the suite would report a verdict
  about the whole having measured only a prefix. It also makes `! cmd` assertions dead and lets an
  `EXIT` trap's last command rewrite the exit status. Every probe runs; the exit code comes from the
  tally. Enforced by `ISC-33` in the execution test.
- **No `grep -q` inside a pipeline.** Under `pipefail`, `grep -q` exits on match and the upstream
  writer takes `SIGPIPE`, inverting the condition *precisely when it is true*. Every string test is a
  bash `case` or `[[ ]]` against a variable. Enforced by `ISC-34`.
- **The probe count is itself an assertion.** `DECLARED_PROBES=24` is compared against the number
  that actually executed. A suite that silently ran zero probes exits 0 and looks exactly like a
  suite that passed; counting is the only defence.

One latent defect was found and fixed during construction. Probes `P09` and `P17` were originally
written as `[[ -n "$toplevel" && "$cwd" == "$toplevel" || "$cwd" == "$toplevel"/* ]]`. Because `&&`
binds tighter than `||` inside `[[ ]]`, that parses as `(-n toplevel && cwd==toplevel) || (cwd==/*)`
— so a failed `rev-parse` leaves an empty `$toplevel` and the second disjunct matches **any** absolute
path, turning the failure into a silent PASS. The parentheses in the shipped version are load-bearing.

## Verification

```
$ bash scripts/test-kpai-harness.sh
probes: 24/24 passed (declared 24, executed 24)          exit 0

$ bun test test/unit/kpai-harness-contract.test.ts
53 pass, 0 fail, 228 expect() calls                      exit 0

$ bun test test/unit/kpai-harness-execution.test.ts
23 pass, 0 fail, 52 expect() calls                       exit 0
```

**Suite arity.** A test file that fails to load — a syntax error, a bad import, a committed conflict
marker — drops its tests out of the tally silently while the runner still exits 0. A check that never
ran is indistinguishable from a check that passed. The execution suite therefore asserts the contract
suite's arity from outside it (`>= 50` passing, `0` failing). The asymmetry is stated rather than
hidden: **nothing outside the execution suite guards the execution suite's own arity**, because a
mutual guard would recurse. The probe layer is covered by `DECLARED_PROBES`; that one link is covered
by review.

### Cross-checks against live measurement

Internal consistency is necessary and not sufficient. A committed artifact keeps satisfying every
shape assertion forever, on any machine — including one with no Landlock, no nono, a different bun and
no worktree. The suite would then be asserting "this JSON is well-formed", not "this harness is
capable", which is the actual claim.

So the contract test re-measures each recorded environment fact **at test time** and compares:
`Bun.version`, `bash --version`, `git --version`, `uname -sr`, `NoNewPrivs` from `/proc/self/status`,
`landlock` in the live LSM list, `process.env.NONO_CAP_FILE`, and `git rev-parse --show-toplevel`.

Two of those comparisons need their relation chosen carefully rather than defaulting to equality:

- **`HEAD` is checked by ancestry, not equality.** The artifact is generated *before* the commit that
  adds it, so its `HEAD` is one commit behind from the moment it lands. `git merge-base --is-ancestor`
  is the invariant that survives every later commit on the branch while still failing if the artifact
  came from an unrelated tree.
- **Freshness asserts existence first, then mtime.** A missing file makes a naive `-nt`-style
  comparison degrade into a bare existence check that silently passes, so both paths are asserted to
  exist before their mtimes are compared.

### Falsification — why the green is trustworthy

A green suite is not evidence that it asserts anything. Five mutations were applied; each was confirmed
to turn the right suite red, then restored and confirmed byte-identical by SHA-256.

| # | Mutation | Detector | Result |
| :-- | :---- | :---- | :---- |
| 1 | Artifact `schema` → `MUTANT/v0` | contract test | 38 pass / **1 fail**, exit 1 |
| 2 | Canary seed no longer derives from `HEAD` | execution test | 21 pass / **1 fail**, exit 1 |
| 3 | Probe `P24` deleted, `DECLARED_PROBES` left at 24 | script tally + execution test | script: `PROBE COUNT MISMATCH — declared 24, executed 23`, exit 1; tests 16 pass / **6 fail** |
| 4 | Probe `P22` forced to fail | script exit path + contract test | script `23/24`, **exit 1**; artifact honestly records `"status": "fail"` and `failed: 1`; tests 51 pass / **2 fail** |
| 5 | Probe `P11` neutered — records `pass` while setting `landlock_available: false`, count left at 24 | cross-check block | script **24/24, exit 0 — did not notice**; contract test 51 pass / **2 fail** |

Rows 2, 4 and 5 are the informative ones.

**Row 2.** With the seed mutated the canary was *still* perfectly deterministic — two runs produced
byte-identical files — so the repeatability assertion stayed green. Only the independent re-derivation
caught it. Repeatability alone would have been satisfied by a hard-coded constant, which is why
determinism is asserted two ways that fail independently.

**Row 4** closes the worst-case exit path: a probe that fails must not still emit a `24/24` artifact.
It does not. The script returns 1 and the artifact records the failure truthfully.

**Row 5 is the one that changed the design.** The probe-count guard proves *arity*, not *assertion* —
a probe whose body is replaced with something trivially true keeps the count at 24, and the script
reports `24/24 passed` and exits 0. Nothing in the script layer can detect a decorative probe. The
cross-check block is what catches it, and that block exists specifically because this gap was raised
at the commitment boundary and then demonstrated rather than argued about.

## Isolation

| Claim | Evidence |
| :---- | :---- |
| Principal checkout untouched | `git status --porcelain` + `HEAD` captured before and after the whole run — `diff` byte-identical |
| Sibling worktrees untouched | mtime census of all 37 sibling worktrees before and after — `diff` byte-identical |
| No residue in this worktree | `git status --porcelain` identical across a full script run (probe `P24`, and again in the execution test) |
| No remote mutation | no `push`, no `gh pr create`, no remote-writing verb issued at any point |

## Reproducing

```bash
cd <your worktree>
bash scripts/test-kpai-harness.sh                                  # human transcript
bash scripts/test-kpai-harness.sh --quiet --emit .kpai-harness-verified.json
bun test test/unit/kpai-harness-contract.test.ts
bun test test/unit/kpai-harness-execution.test.ts
```

The artifact's `worktree.head` and `canary.digest` will differ in another worktree — that is the point.
Everything else, including all 24 probe outcomes, should be identical on any correctly-provisioned
KPAI harness. A differing probe outcome is a real finding about that harness, not a flaky test.
