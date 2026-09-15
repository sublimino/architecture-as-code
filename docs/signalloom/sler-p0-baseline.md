# SLER-P0 — Preflight Baseline

> **Card:** SLER-P0 · **Role:** preflight · **Phase:** 0
> **Repository identity:** `/home/andy/src/cp/osramp-demo`
> **Task worktree:** `/home/andy/.cline/worktrees/e42f8/osramp-demo`
> **Integration branch:** `integration/sler-v0.1.0` @ `2fedff0610b16682128cbcfac42eff9025320a53`
> **Baseline HEAD:** `2fedff0610b16682128cbcfac42eff9025320a53` (identical — worktree created at the branch tip)
> **Captured:** 2026-09-15 00:00 +01:00

Every claim below carries a `file:line` or a command citation. Nothing here is copied from the
card prompt without independent re-verification, and four of the card's own statements are
corrected as a result — see [Corrections to the card](#corrections-to-the-card).

---

## 1. Harness identity

`scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLER`

**Exit code: `1`. Status line: `Doctor Status: UNHEALTHY (1 exception(s) require remediation)`.**

**This is not a SLER defect and does not block Phase 1.** The doctor runs five checks, and only
the first two forward `--shortcode`:

| # | Check | Scope | Source |
|---|---|---|---|
| 1 | Graph integrity (`link-check`) | board | `scripts/kanban-check.sh:69-74` |
| 2 | Inversions | board | `scripts/kanban-check.sh:76-87` |
| 3 | Duration / fast-exit | **repo-wide** | `scripts/kanban-check.sh:89-94` |
| 4 | Zero-output cards | **repo-wide** | `scripts/kanban-check.sh:96-101` |
| 5 | `.kagent-preflight-proof.json` | repo file | `scripts/kanban-check.sh:103-129` |

Checks 3 and 4 invoke `"$0" duration-check --repo "$repo"` and `"$0" output-check --repo "$repo"`
with **no `--shortcode` argument** (`scripts/kanban-check.sh:91`, `:98`). A brand-new board
therefore inherits every crashed task any prior mission left in this repo.

The single exception raised is check 3: **29 tasks finished in under 5.0s**, all from prior
boards. The failure set was captured and searched: **zero of the 29 carry an `SLER` identifier.**
Agents named are `cpai-opencode` (20), `cpai-opencode-deep` (5), `cpai-opencode-fast` (1),
`antigravity` (2), `unknown` (1); two are literal test fixtures
(`test-card-1788295874373`, `test-sqlite-1788296735358`).

Because "exit 1 is expected" is a useless oracle — a genuine new crash would exit 1 too, masked
behind the inherited set — the two board-scoped checks were run independently:

```
$ scripts/kanban-check.sh link-check --repo /home/andy/src/cp/osramp-demo --shortcode SLER
RESULTS
========
✓ all six rules pass

Counts:  CRITICAL=0  FAIL=0  WARN=0
                                                          → exit 0

$ scripts/kanban-check.sh progress --repo /home/andy/src/cp/osramp-demo --shortcode SLER
BOARD: backlog=29  in_progress=1
0     P0          in_progress  SLER-P0: Validate SLER harness identity and clean monorepo baseline
                                                          → SLER board resolves; 30 cards; P0 is the only card in flight
```

**The doctor does not short-circuit.** Every one of the five checks runs and increments a counter
(`scripts/kanban-check.sh:72, :80, :84, :91, :98, :105, :126`); the verdict branch is reached only
afterwards (`exit 0` at `:134`, `exit 1` at `:141`). This matters: a check that never ran is
indistinguishable from a check that passed, and here we can positively state that checks 4 and 5
ran and raised nothing. Per-check ledger:

| # | Check | Ran? | Verdict | How established |
|---|---|---|---|---|
| 1 | Graph integrity | yes | **green** | no exception raised; re-run standalone → `✓ all six rules pass`, exit 0 |
| 2 | Inversions | yes | **green** | no exception raised |
| 3 | Duration / fast-exit | yes | **red** | the sole exception; 29 inherited tasks, attributed below |
| 4 | Zero-output cards | yes | **green** | no exception raised, and the counter proves it executed |
| 5 | Preflight proof artefact | yes | **green** | `.kagent-preflight-proof.json` parsed `VALID` per `:107-127` |

**Verdict: SLER identity resolves correctly. Four of five checks are green; the one failure is
attributable in full to inherited repo-wide state.**

> **Do not over-read "zero of the 29 are SLER".** SLER has one task in existence, so its absence
> from a finished-task sweep is near-vacuous — it establishes that SLER is not the *cause* of the
> red, not that the harness has been exercised against SLER. Harness identity is evidenced by the
> two **board-scoped** checks (`link-check`, `progress`), which do resolve the SLER board and its
> 30 cards. Checks 3 and 4 are repo-wide and **will** evaluate SLER tasks from Phase 1 onward.

> **For later `-PRE` cards:** do not re-derive "exit 1 is fine". Diff against the recorded set:
> ```bash
> diff <(scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLER 2>&1 \
>         | sed -nE 's/^  ✗ Task ([^ |]+).*/\1/p' | sort) baseline-set.txt
> ```
> The argument that "no card of ours can be in a finished-task sweep" **expires the moment SLER-P0
> completes** — from Phase 1 onward, a SLER task appearing in that set is a real signal.

### Captured doctor output

```
━━━ [doctor] 1 EXCEPTION(S) RAISED ━━━

[!] FAST-EXIT / AGENT CRASH DETECTED:
FAIL: 29 task(s) finished suspiciously fast (< 5.0s):
  ✗ Task 26376    | Agent: cpai-opencode      | Duration:  0.00s | Reason: exit
  ✗ Task 80198    | Agent: cpai-opencode-deep | Duration:  0.00s | Reason: exit
  ✗ Task 4f3dd    | Agent: cpai-opencode      | Duration:  3.53s | Reason: error
  ✗ Task b8ce0    | Agent: cpai-opencode      | Duration:  0.00s | Reason: exit
  ✗ Task 6d6aa    | Agent: cpai-opencode      | Duration:  3.42s | Reason: exit
  ✗ Task 399bb    | Agent: cpai-opencode-fast | Duration:  1.89s | Reason: exit
  ✗ Task __home_agent__:kanban:antigravity      | Agent: antigravity | Duration:  0.73s | Reason: error
  ✗ Task __home_agent__:osramp-demo:antigravity | Agent: antigravity | Duration:  2.78s | Reason: error
  ✗ Task 72ad4, 185c3, 99c25, 35a0c, c366b, f1433, 5d048, b8930, 1b3f2,
       b05bc, 9d859, bd117, 989db, 2f42d, 84abc   | cpai-opencode      | 0.00s | exit
  ✗ Task 1d2b1, 5f187, 6c692, fe2a7                | cpai-opencode-deep | 0.00s | exit
  ✗ Task test-card-1788295874373                   | cpai-opencode      | 0.00s | exit
  ✗ Task test-sqlite-1788296735358                 | unknown            | 0.00s | exit

Doctor Status: UNHEALTHY (1 exception(s) require remediation)
                                                          → exit 1
```

(Rows collapsed by agent+duration+reason for readability; the 29 individual IDs are enumerated
above and every one has `Duration: 0.00s | Reason: exit` unless shown otherwise.)

Check 5 raised no exception, so `/home/andy/src/cp/osramp-demo/.kagent-preflight-proof.json`
exists and parses as `status=COMPLETED`, `test_status=PASS`, empty `proof_errors`
(`scripts/kanban-check.sh:107-127`).

---

## 2. Go module layout — there is no root module

```
$ ls go.mod go.work go.work.sum
ls: cannot access 'go.mod': No such file or directory
ls: cannot access 'go.work': No such file or directory
ls: cannot access 'go.work.sum': No such file or directory
$ find . -maxdepth 1 -name 'go.*'
                                                          → no output
```

Three explicit stat failures, not one empty search. **There is no repo-root `go.mod` and no
`go.work`.** The repository is **22 independent Go modules**, each rooted at its own app or
command directory.

The four SLER target components each own a distinct module:

| Component | `go.mod` | Declared module path |
|---|---|---|
| fleet-manager | `d2-signalloom/apps/fleet-manager/go.mod:1` | `…/d2-signalloom/apps/fleet-manager` |
| stun-sentinel | `d2-signalloom/apps/stun-sentinel/go.mod:1` | `…/d2-signalloom/apps/stun-sentinel` |
| signalloom-stun-sentinel | `d2-signalloom/apps/signalloom-stun-sentinel/go.mod:1` | `…/d2-signalloom/apps/signalloom-stun-sentinel` |
| node-capability-guard | `d2-signalloom/apps/node-capability-guard/go.mod:1` | `…/d2-signalloom/apps/node-capability-guard` |

(Common prefix `github.com/controlplaneio-in-toto/osramp-demo` elided.) The remaining 18 modules
span `d2-signalloom/apps/*` (16), `d2-signalloom/cmd/{policy-compiler,riskctl}`, and three legacy
`d2-osramp-apps/apps/*` modules — one of which, `d2-osramp-apps/apps/archiver/go.mod:1`, declares
the bare unqualified path `module archiver`.

> **Binding consequence for every later card:** `go test ./d2-signalloom/apps/X/...` run from the
> repository root **cannot resolve a module** and will fail before any test runs. Every Go test
> command in every SLER card must `cd` into the app directory first:
> ```bash
> cd d2-signalloom/apps/fleet-manager && go test ./...
> ```
> Cross-module code sharing between the two sentinels in P4-1 requires a `replace` directive or a
> new shared module — it is not a file move.

---

## 3. M1 is a from-zero client build, not a wiring swap

This is the headline finding and it changes P1-1's size.

`noopFleetClient` is declared at `d2-signalloom/apps/fleet-manager/main.go:215`, under the comment
at `:214` — *"is used when running outside a cluster. All operations are no-ops."* Its four methods:

| Method | Line | Body |
|---|---|---|
| `GetPodState` | `main.go:217-219` | `return StateRunning, nil` |
| `SetPodState` | `main.go:220` | `return nil` |
| `RevokeCredentials` | `main.go:221` | `return nil` |
| `RestoreCredentials` | `main.go:222` | `return nil` |

It is selected **unconditionally** — no environment check, no kubeconfig probe, no error branch:

```go
// d2-signalloom/apps/fleet-manager/main.go:250
client := FleetClient(&noopFleetClient{})
```

The interface it satisfies is `d2-signalloom/apps/fleet-manager/cascade.go:36-48`, whose doc
comment at `:33-35` claims *"In production this talks to the real cluster; in tests it is a mock."*
**Neither half of that sentence is currently true of any production path.**

A grep across every `*.go` file in the module returns:

| Symbol | Occurrences in `d2-signalloom/apps/fleet-manager/` |
|---|---|
| `InClusterConfig` | **0** |
| `BuildConfigFromFlags` | **0** |
| `FleetClient` implementors | **2** — `noopFleetClient` (`main.go:215`) and `mockFleetClient` (`cascade_test.go:12`) |

`mockFleetClient` is test-only: it lives in `cascade_test.go` and is constructed solely by
`newMockClient()` at `cascade_test.go:23`.

**Conclusion.** There is no Kubernetes client, no kubeconfig loading, no OpenBao client, and no
SPIRE client anywhere in the fleet-manager module. The proposal's framing of M1 as eliminating a
"silent fallback" describes deleting four one-line stubs; the actual work is **writing a
Kubernetes and credential client from zero**, including RBAC, client-go dependency introduction,
error taxonomy, and the `ErrEnforcementUnavailable` fail-closed path the architectural
constitution mandates. **P1-1 must be sized as a from-zero build.**

---

## 4. Manifest inventory

The three enforcement components are at radically different levels of deployment readiness.

| Component | Dockerfile | Manifests | Location |
|---|---|---|---|
| **fleet-manager** | ✅ `apps/fleet-manager/Dockerfile` | **6 manifests + 1 kustomization** | in-app `base/` |
| **stun-sentinel** | ❌ **none** (only `bpf/Dockerfile.builder`) | 1 multi-doc DaemonSet bundle | **deploy-level only** |
| **signalloom-stun-sentinel** | ✅ `apps/signalloom-stun-sentinel/Dockerfile` | 3 | `infra/agent-swarm/…` |
| **node-capability-guard** | ❌ **none** | **zero, anywhere in the repository** | — |

**fleet-manager** — `d2-signalloom/apps/fleet-manager/base/` contains exactly 7 files:
`configmap.yaml`, `deployment.yaml`, `fleet-config.yaml`, `kustomization.yaml`,
`networkpolicy.yaml`, `rbac.yaml`, `service.yaml`. Six are manifests; `kustomization.yaml` is the
kustomize index, not a Kubernetes object.

**stun-sentinel** — has **no application Dockerfile**:
```
$ ls d2-signalloom/apps/stun-sentinel/Dockerfile
ls: cannot access '…': No such file or directory
```
Its only container build file is `d2-signalloom/apps/stun-sentinel/bpf/Dockerfile.builder`, which
builds the eBPF objects, not the sentinel binary. Its deployment lives entirely at deploy level in
`d2-signalloom/deploy/stun-sentinel-daemonset.yaml`, a multi-document bundle carrying `Namespace`
(`:26`, `signalloom-system`), `ServiceAccount` (`:39`), `ClusterRole` (`:49`),
`ClusterRoleBinding` (`:64`), and the DaemonSet itself (`:72`).

**node-capability-guard** — the entire component is **four files**:
```
d2-signalloom/apps/node-capability-guard/cmd/main.go
d2-signalloom/apps/node-capability-guard/go.mod
d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go
d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go
```
No `Dockerfile`. No `base/`. No `Deployment`. No `Service`. No `ValidatingWebhookConfiguration`.
No certificate or `CABundle` plumbing. A grep for the literal string `node-capability-guard`
across **every `*.yaml` and `*.yml` in the repository** returns **zero matches** — this is
whole-repo positive evidence of absence, not a single failed lookup in the app directory.

**Unmanifested is not the same as unbuilt, and the distinction changes P3-2's starting point.**
A broader sweep (Makefile, `.github/`, scripts, any file type) shows the component *is* exercised:

| Surface | Result |
|---|---|
| `Makefile` | **zero** references — no build or test target |
| `.github/` CI workflows | **zero** references |
| `scripts/test-admission-guard.sh` | present — a driver exists |
| `test/admission-node-guard.bats` | present — a bats suite exists |
| `test/crkc-phase3-confinement-redteam.bats` | present |
| `bin/node-capability-guard` | **a tracked 9.4 MB statically-linked ELF x86-64 binary** (`git ls-files` confirms it is committed) |
| `docs/signalloom/evidence/admission-guard-proof.json` | present |

So P3-2 inherits a **buildable, built, and locally-tested handler with no deployment surface and
no build automation**. The missing work is the Dockerfile, the manifests, the TLS/`caBundle`
plumbing, the `failurePolicy` decision, and a Makefile/CI target — not the handler itself.

> **Binding consequence for P3-2.** The admission-webhook card is not "add a webhook handler". It
> must additionally produce: a Dockerfile, a Deployment, a Service, a
> `ValidatingWebhookConfiguration`, TLS serving certificates with a `caBundle` (or a cert-manager
> `Certificate`), RBAC, and a `failurePolicy` decision — because a fail-closed admission webhook
> that cannot be reached blocks every pod creation in its scope. Discovering this mid-phase costs
> P3-2 approximately a day.

---

## 5. Sentinel divergence — the two freezers are not two copies of one thing

| | `stun-sentinel` | `signalloom-stun-sentinel` |
|---|---|---|
| File | `apps/stun-sentinel/pkg/cgroup/freezer.go` | `apps/signalloom-stun-sentinel/freezer.go` |
| Lines | **722** | **110** |
| Package | `cgroup` (`:31`) — importable library | `main` (`:1`) — not importable |
| API | **exported** | **unexported** |
| Freeze | `Freezer.Freeze` `:507`, `FreezePod` `:557` | `cgroupFreezer.freeze` `:19` |
| Unfreeze | `Freezer.Unfreeze` `:575`, `UnfreezePod` `:624` | `cgroupFreezer.unfreeze` `:44` |
| Resolve | `ResolvePodCgroup` `:307`, `walkForPod` `:327` | `resolvePodCgroup` `:68` |
| Health | `HealthCheck` `:695` | — |
| Proc enumeration | `ListProcs` `:645` | — |
| Deadline / settle loop | `DefaultFreezeDeadline` `:48`, `awaitState` `:469` | — |
| **Credential validation** | **present** | **absent** |

**The credential gap is the material one.** `stun-sentinel` carries a complete governance-resume
concept:

- `CredentialValidator func(credential string) bool` — `freezer.go:118`
- `DenyAllCredentials` — the **secure default** — `freezer.go:122`, installed at `freezer.go:192`
- `WithCredentialValidator` option — `freezer.go:175`
- `ErrUnauthorized` (*"unfreeze refused, governance credential did not validate"*) — `freezer.go:88`
- `Unfreeze(cgroupPath, credential string)` gates on it at `freezer.go:578`
- constant-time token validation — `cmd/stun-sentinel/main.go:71`
- credential read from environment only, never argv — `cmd/stun-sentinel/main.go:48`
- credential carried in a header, never in the URL — `cmd/stun-sentinel/main.go:180-181`

A grep for `redential` across all non-test `*.go` in `signalloom-stun-sentinel` returns **zero
matches**. Its `unfreeze` takes a cgroup path and nothing else (`freezer.go:44`) — there is no
authorization concept to merge.

### Which one is the ancestor — the naive reading is inverted

| | `stun-sentinel` (722 lines) | `signalloom-stun-sentinel` (110 lines) |
|---|---|---|
| Freezer first committed | **2026-09-07** `9886f3ce` *"implement cgroup.freeze controller for sub-50ms execution halting"* | **2026-08-27** `70ffed79` *"add security validation fleet…"* |
| Relationship | **newer, second implementation** | **the original** |
| `go` directive | `go 1.24` (`go.mod`) | **`go 1.22.0`** (`go.mod`) |
| Deployed image | `ghcr.io/controlplaneio-in-toto/stun-sentinel:v0.1.0` (`deploy/stun-sentinel-daemonset.yaml:113`) | `stun-sentinel:latest` (`infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml:39`) |

The 110-line file is **not a trimmed copy of the 722-line one** — it predates it by eleven days.
`stun-sentinel` is a later, richer rewrite that was never reconciled with its ancestor, and the
ancestor is still deployed under its own DaemonSet. Note also that **two different DaemonSets ship
two different images both named `stun-sentinel`**, one pinned (`:v0.1.0`) and one floating
(`:latest`) — a drift hazard P4-1 must resolve, not inherit.

> **Binding consequence for P4-1.** "Unify the sentinel implementations" is not a file merge. The
> capability sets are disjoint in both directions: `signalloom-stun-sentinel` has eBPF
> (`ebpf/probe.go`), telemetry attribution (`telemetry/attributor.go`), audit (`audit.go`),
> dry-run (`dryrun_test.go`) and a Dockerfile that `stun-sentinel` lacks; `stun-sentinel` has the
> credential gate, the settle-deadline loop, health checking and tc/eBPF packet drop
> (`pkg/tc/`) that `signalloom-stun-sentinel` lacks. Unification is an API design task with a
> security-critical default (`DenyAllCredentials`) that must survive the merge — **if the unified
> engine defaults to the permissive side, the merge silently removes the resume authorization
> gate from a working component.**

---

## 6. Test commands — real versus claimed

### Targets that do not exist

| Named target | Status |
|---|---|
| `demo-signalloom-enforcement-test` | **Does not exist anywhere in the repository.** A grep across the entire tree (excluding `.git/`) returns zero matches — not in the Makefile, not in any script, not in any document. |
| `demo-signalloom-purple-test` | **Is not a Makefile target.** Exactly one occurrence in the whole tree: `docs/Signal Loom — Next-Phase Proposals — Adversarial Critique (2026-Q3).md:45`, where it is a *recommendation* in a critique table ("Enforce automated latency benchmarking … in `make demo-signalloom-purple-test`"), not a declaration. |

### Targets that do exist

| Target | Citation | Recipe |
|---|---|---|
| `demo-signalloom-api-test` | `Makefile:849` | `./scripts/signalloom-api-test.sh $${TIER:-contract}` — takes `TIER`, defaults to `contract` |
| `test` | `Makefile:461` | *"Run the end-to-end bats suite **against the running cluster**"* — **requires a live cluster**; it is not a baseline-verifiable offline target |

There is no `test-unit` and no `test-docker` target. **`make test` was therefore not run as part of
this baseline** — it cannot pass without a cluster, and a failure would carry no information about
tree health. The three acceptance commands below are the offline-verifiable baseline.

### The real acceptance harness — all three green against an unmodified tree

| Command | Result | Exit |
|---|---|---|
| `bash scripts/run-redteam-suite.sh` | 15/15 attack scenarios, **0 escapes, 0 leaks** | **0** |
| `bats test/crkc-adversarial-redteam.bats` | plan `1..15`, **15 ok, 0 not ok** | **0** |
| `bats test/acceptance-spec-coverage.bats` | plan `1..7`, **7 ok, 0 not ok** | **0** |

Bats **plan lines were captured deliberately** (`1..15`, `1..7`): a suite that fails to parse
does not report failures, it reports fewer tests, and only the plan line makes that visible.
Zero `not ok`, zero `# skip`, zero `FAILED` across all three.

`test/crkc-adversarial-redteam.bats:42` asserts `.metrics.process_escapes` from the evidence
artefact, as the card records.

Benchmark figures reported by the suite on this host: average freeze latency **4 ms**, p95
**12 ms** against a 50 ms ceiling, **0** watchdog timeouts, 100% D-state transition confirmation.

> **Tree-mutation warning for every later card.** `scripts/run-redteam-suite.sh` **writes to the
> tracked file** `docs/signalloom/evidence/adversarial-redteam-proof.json`, leaving the tree dirty
> and reading as uncommitted work. The diff was inspected before reverting: the **only** changed
> field is `"generated"` (`2026-09-07T21:33:40Z` → `2026-09-14T22:59:12Z`); the entire `metrics`
> object is byte-identical between `HEAD` and the working copy. It was reverted with
> `git checkout --`, not committed. **Always inspect the verdict fields before reverting** — a
> genuine metrics regression would hide inside what looks like a timestamp churn.

---

## 7. ⚠️ CRITICAL — the acceptance suite asserts against a constant and cannot fail

**All three commands exit 0. That green carries almost no information, and the mission's headline
metric currently rests on it.** This is a pre-existing baseline defect, recorded here rather than
fixed, because P0's role is preflight.

The chain, end to end:

1. `scripts/run-redteam-suite.sh:25` opens `cat <<JSON > "$EVIDENCE_FILE"` and writes
   `docs/signalloom/evidence/adversarial-redteam-proof.json` as a **heredoc of hardcoded
   literals**: `"scenarios_total": 15`, `"scenarios_passed": 15`, `"scenarios_failed": 0`,
   `"pass_rate": 1.0`, `"process_escapes": 0`, `"packet_leaks": 0`,
   `"freeze_latency_p95_ms": 12.0`. **The only interpolated value in the entire document is
   `$TIMESTAMP`** (`:23`) — which is precisely why the tree goes dirty on every run.
2. There is **no loop and no attack**. A grep for `for `, `while `, `seq `, `xargs`, `kubectl`,
   `docker`, or any write to `/sys/fs/cgroup` across the script returns nothing that executes a
   scenario. The fifteen "scenarios" are fifteen JSON objects with `"status": "PASS"` typed in.
3. The one thing it does delegate — `test/bench-redteam-stress.sh` (`run-redteam-suite.sh:18`) —
   is **also synthetic, and says so**. Its cgroup probe short-circuits on `|| [ -d "$CGROUP_ROOT" ]`
   (`:15`), so it passes on any Linux host; `:18` prints *"running simulated kernel probe"*; `:23`
   is commented *"Measure simulated and synthetic freeze state transitions"*; `:30` *"Simulate CPU
   burst"*; and `:41` **clamps the result** — *"Bound to realistic kernel freezer latency
   (1-18ms)"*. Its output goes to `/tmp/crkc-bench-freeze.json` (`:12`).
4. **Nothing ever reads `/tmp/crkc-bench-freeze.json`.** The measured-then-clamped numbers are
   discarded.
5. `test/crkc-adversarial-redteam.bats:10` sets
   `EVIDENCE="$REPO_ROOT/docs/signalloom/evidence/adversarial-redteam-proof.json"` and all fifteen
   tests — including `:42`'s `jq -r '.metrics.process_escapes'` — assert against **that file**.

**The bats suite therefore asserts against a JSON document the sibling script wrote moments
earlier from constants. It is structurally incapable of failing.** The tell was visible in the run
itself and is worth recording: the benchmark printed `Average freeze latency: 4ms` while the
evidence file it supposedly supports reports `6.4`. Two unrelated numbers, because they are
unrelated.

**Consequences for this mission, which are direct:**

- The proposal's Milestones row **P6-1** cites `bats test/crkc-adversarial-redteam.bats; assert
  escape rate = 0` as its evidence (proposal `:325`). Against today's harness that assertion is a
  tautology — it would pass on a cluster with no enforcement at all.
- The architectural constitution's **Published Denial Matrix** ("Guaranteed Denial Latency (p99)
  and Worst-Case Residual Latency under network partitioning") cannot be sourced from this
  harness. Every figure it would publish is a literal.
- The mission's own out-of-scope rule — *"do not claim a latency figure not measured at the stated
  fleet size"* — is already violated by the committed evidence artefact, which claims
  `tc_packet_flood_pps: 100000` and `freeze_latency_p95_ms: 12.0` at no measured fleet size.

**Recommended remediation (P6-1's actual scope, not P0's):** make the runner execute scenarios and
*derive* the JSON from observed outcomes; have the bats suite assert against a run-scoped artefact
rather than a committed one; and delete the `1-18ms` clamp so a regression can express itself.
Until then, treat "15/15 green" as *"the harness is wired and parses"*, never as *"containment
works"*.

---

## 8. Build health at HEAD — one of the four target modules does not compile

`go version go1.26.2 linux/amd64`. Per module, from inside its own directory, with
`-buildvcs=false` (required: `go build` fails in any git worktree without it):

| Module | `go build ./...` | `go vet ./...` | `go` directive |
|---|---|---|---|
| fleet-manager | ✅ 0 | ✅ 0 | `go 1.24` |
| **stun-sentinel** | ❌ **1** | ❌ **1** | `go 1.24` |
| signalloom-stun-sentinel | ✅ 0 | ✅ 0 | **`go 1.22.0`** |
| node-capability-guard | ✅ 0 | ✅ 0 | `go 1.24` |

```
pkg/tc/bpf_embed.go:25:12: pattern tc_drop.bpf.o: no matching files found
```

`stun-sentinel` carries a `//go:embed tc_drop.bpf.o` directive whose target is a **compiled eBPF
object that is not in the tree** — it is produced by `d2-signalloom/apps/stun-sentinel/bpf/build.sh`
from `bpf/tc_drop.bpf.c`, via `bpf/Dockerfile.builder`. Until that object is built, the module
cannot compile, cannot vet, and cannot run `go test ./...`.

> **Binding consequence for P4-1 and P4-PRE.** The eBPF object must be built before any Go
> tooling touches `stun-sentinel`. A card that opens with `cd d2-signalloom/apps/stun-sentinel &&
> go test ./...` fails on its first command, and the error names an embed pattern rather than the
> missing build step — an easy hour to lose. This is a pre-existing condition at
> `2fedff0610b16682128cbcfac42eff9025320a53`, not a regression introduced by this card.

**Cross-module edges.** Six modules carry `replace` directives — `test/mocks`, `tools/riskctl`,
`d2-signalloom/cmd/{riskctl,policy-compiler}`, `d2-signalloom/apps/{workspace-connector,signal-ingest}`.
**None of the four SLER target modules does.** So "`cd` before `go test`" is sufficient guidance
for this mission, and any code sharing P4-1 introduces between the sentinels will be the first
`replace` edge among them.

---

## Corrections to the card

Four statements in the SLER-P0 card prompt are corrected by direct measurement. Recorded here so
later cards inherit the measured value, not the asserted one.

| # | Card said | Measured | Impact |
|---|---|---|---|
| 1 | The proposal "lives in an Obsidian vault, NOT the repo" and must never be `git add`ed | **False.** `git ls-files 'docs/Proposal*'` lists it among 9 tracked proposals. Two independent files exist — the tracked repo copy and a vault copy. | Material. An errata block written only to the vault never reaches the integration branch, so no downstream card sees it. The repo copy is committed. |
| 2 | `signalloom-stun-sentinel/freezer.go` is **98 lines** | **110 lines** (`wc -l`) | Minor, but the figure was quoted as fact; the symbol inventory above supersedes it. |
| 3 | Two targets named *in the Milestones table* do not exist | **No longer true of the current proposal.** Grepping the proposal for `demo-signalloom` returns exactly one hit — `make demo-signalloom-api-test TIER=contract` at line 308 — which **does** exist (`Makefile:849`). The fabricated names appear nowhere in this proposal; `demo-signalloom-purple-test` survives only in a separate critique document. | The proposal was corrected before this card ran. The warning is retained as a caution, not reported as a live defect. |
| 4 | `stun-sentinel/pkg/cgroup/freezer.go` is **~720 lines** | **722 lines** | Confirmed within tolerance. |

`stun-sentinel/pkg/cgroup/freezer.go` exporting `Freeze`/`Unfreeze`/`FreezePod`/`UnfreezePod`/
`HealthCheck`, and `node-capability-guard` having zero manifests of any kind, are both confirmed
exactly as the card stated.

---

## Verdict

**Phase 1 is safe to start.** The integration branch is healthy, SLER board identity resolves, the
working tree is clean at `2fedff0610b16682128cbcfac42eff9025320a53`, and all three named acceptance
commands exit 0. **No hard blocker from the card's STOP list was encountered.**

But "the baseline is green" is the wrong summary, and section 7 is why. Seven facts materially
change downstream sizing, ranked by cost of rediscovery:

1. **⚠️ The acceptance harness cannot fail** (§7). `run-redteam-suite.sh` writes its evidence from
   hardcoded literals; the bats suite asserts against that file. P6-1's stated evidence is a
   tautology and the Denial Matrix has no measurement source. **This is the mission's largest
   single risk and it is invisible from the exit code.**
2. **P1-1 is a from-zero Kubernetes and credential client build** (§3), not a stub swap. Zero
   `InClusterConfig`, zero `BuildConfigFromFlags`, zero client-go anywhere in the module.
3. **`stun-sentinel` does not compile at HEAD** (§8) — a missing embedded eBPF object. P4-PRE must
   build it before any Go tooling runs.
4. **Every Go test command must `cd` into its app directory** (§2) — 22 modules, no root module,
   no `go.work`.
5. **P3-2 inherits a built binary with zero deployment surface** (§4) — no Dockerfile, no
   manifests, no webhook configuration, no certificates, no Makefile or CI target.
6. **P4-1's "unify" is an API design task with a security-critical default** (§5): only
   `stun-sentinel` has a resume-authorization concept, its `DenyAllCredentials` default must
   survive the merge, and the 110-line file is the **ancestor**, not a trim.
7. **The doctor's red is inherited and must be gated on the delta**, never on the status (§1) —
   and that argument expires the moment SLER-P0 completes.
