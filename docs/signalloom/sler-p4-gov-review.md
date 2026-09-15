# SLER-P4-GOV — Phase 4 Completion Report and Certification Review

**Card:** SLER-P4-GOV (governor) · **Phase:** 4 — Runtime Containment & Memory Forensics
**Integration branch:** `integration/sler-v0.1.0`
**Reviewed tree:** `ddf624f9da10e302def49303714337a995558d0f`
**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/sler-v0.1.0/governor`
**Date:** 2026-09-15 06:39:38+01:00

---

## 0. Verdict

**CERTIFICATION WITHHELD — `status=fail`.**

Phase 4's *code* is in better shape than its *deployment*. The freeze engine is genuinely
unified, the forensic capture is real and survives workload death, the resume token
cryptography is sound, and all required suites are green on the merged tree — including a
new end-to-end `stun → snapshot → unstun` cycle test written for this review, which no card
previously had.

What fails certification is the gap between what the three cards *built* and what the
merged tree would *deploy*. Four findings below are blocking. The central one is short
enough to state in a sentence: **neither deployed DaemonSet manifest wires P4-2's snapshot
storage or P4-3's operator keys**, so on the merged tree as it stands, forensic snapshots
would be written to a `readOnlyRootFilesystem: true` container and attributable resume would
be structurally impossible — the exact "paper claim rather than a demonstrated one" failure
mode this card was told to look for.

Phase 4 should not be declared attestation-ready for P5-1, and P5-2 must not publish the
freeze plane's numbers as fleet figures, until F1–F4 are resolved.

| # | Finding | Severity | Blocks |
| :-- | :--- | :--- | :--- |
| F1 | Neither manifest wires quarantine storage or operator keys | **Blocking** | P5-1, P5-2 |
| F2 | Legacy symmetric resume fallback defeats attribution, rotation and replay protection | **Blocking** | P5-1 |
| F3 | Forensic snapshot read endpoints are unauthenticated | **Blocking** | P5-1 |
| F4 | Redundant `signalloom-stun-sentinel` DaemonSet and RBAC were not removed | **Blocking** (explicit card requirement) | phase close |
| F5 | Hardcoded universal-accept token in the unification adapter | High | — |
| F6 | P4-PRE §7.2 and §7.3 unification steps not executed | Medium | — |
| F7 | Kernel floor is an n=1 claim, not a fleet check | Medium | P5-2 |
| F8 | Rotation is proven against stubs, never against P2-1/P2-2's real clients | Medium | P5-1 |
| F9 | P4-3 proof §5.2 documents an event name the code does not emit | Low | — |

---

## 1. What genuinely passes

These were checked independently, not accepted from the cards' own proofs.

### 1.1 The sentinels are genuinely unified, not co-located — with one caveat

`d2-signalloom/apps/signalloom-stun-sentinel/freezer.go` is now 70 lines (was 111) and
contains no freeze algorithm at all. It declares `cgroupFreezer{engine *cgroup.Freezer}`
and its three methods each delegate one call deep into
`stun-sentinel/pkg/cgroup`. The dependency is real, not aspirational: `go.mod` carries

```
require github.com/…/apps/stun-sentinel v0.0.0-unpublished
replace github.com/…/apps/stun-sentinel => ../stun-sentinel
```

Every capability P4-PRE §2.2 listed as missing from the naive freezer is now reachable from
both call sites because both call the same engine: the emptiness gate against vacuous
success, the geometric-backoff convergence poll, the process census, the ancestor-freeze
diagnostic, and boundary-safe pod-UID matching. I confirmed the ancestor diagnostic fires
for real — it is what made the first draft of the cycle test fail, correctly, against a
fixture whose `cgroup.events` could not flip.

P4-PRE's function-by-function diff listed five gaps. Four are closed by delegation. The
fifth — "No Credential / Governance Gate" — is **not** closed; see F5.

### 1.2 One event shape across all three cards

This was the requirement most likely to have been fudged, and it holds. P4-1's
`StunExecution*`, P4-2's `QuarantineSnapshot*`, and P4-3's attribution fields all serialise
through a single `telemetry.Event` struct (`pkg/telemetry/emitter.go:56`). `operator_id`,
`operator_ids` and `token_id` are fields on that same envelope, not a sidecar record.
`TestP4GovFreezePlaneEmitsOneConsistentEventShape` asserts every emitted line carries
`timestamp`, `event`, `tier`, `frozen`, `latency_ms`, `pids`, `pid_count` and a `tier-0-*`
tier value. P5-1 has one shape to attest, not three.

**Caveat for P5-1:** the sentinel is internally consistent, but `fleet-manager` emits
`governance_resume_decision` in a *different* shape (snake_case event name, no `tier`).
There are two shapes across the freeze plane as a whole — one within the sentinel, one in
the orchestrator. P5-1 must reconcile those two, not three.

### 1.3 Load-bearing privileges were not narrowed, and not widened

P4-PRE §5 named `hostPID: true`, `privileged: true` (or `SYS_ADMIN`+`NET_ADMIN`), and a
read-write `hostPath: /sys/fs/cgroup` as load-bearing. On the merged tree:

- Manifest A (`deploy/stun-sentinel-daemonset.yaml`): `hostPID: true` (103),
  `privileged: true` (145), `/sys/fs/cgroup` with `readOnly: false` (156) and the comment
  "NOT readOnly. This is the whole point of the DaemonSet."
- Manifest B (`infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml`): `hostPID: true`
  (33), `privileged: false` (77) with `SYS_ADMIN`/`NET_ADMIN` (80-81), `/host-cgroup` with
  `readOnly: false` (87).

Nothing was narrowed by P4-1 through P4-3. **P4-2's snapshot addition did not widen the
privilege footprint** — it added no capability, no mount and no `privileged` escalation to
either manifest, consistent with that card's own finding. That is recorded here explicitly
as the card required.

### 1.4 P1-4's `/stun` authentication survived the unification unchanged

`main.go:507`: `mux.HandleFunc("/stun", requireBearer(s.freezeValidate, s.handleStun))`.
`freezeValidate` is `constantTimeTokenValidator(cfg.freezeToken)` (557), which denies on
empty-expected, denies on empty-supplied, compares over fixed width, and XOR-accumulates —
no early return. The startup fail-fast checks are intact: empty `STUN_FREEZE_TOKEN` refuses
to start (524), and freeze/resume tokens must be distinct (550). The existing negative tests
(`TestStunRefusesWithoutCredential`, `…WrongCredential`, `…RefusesResumeToken`,
`…RefusesUnauthenticatedBeforeParsing`) all pass on the merged tree. **Unchanged and intact.**

### 1.5 Required suites, run on the merged tree

| Command | Result |
| :--- | :--- |
| `cd d2-signalloom/apps/stun-sentinel && go test ./...` | **PASS** — 8 packages ok |
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **PASS** — ok 1.427s |
| `cd d2-signalloom/apps/signalloom-stun-sentinel && go test ./...` | **PASS** — 3 packages ok |
| `bash scripts/run-redteam-suite.sh` | **PASS** — 15/15 scenarios, 0 escapes, 0 leaks |
| `bats test/crkc-adversarial-redteam.bats` | **PASS** — 15/15 |
| `grep -rn 'STUN_RESUME_TOKEN' d2-signalloom/` | 20 hits — see F2 |

---

## 2. The end-to-end cycle test

The card's core deliverable, and the thing no card had: a single test that freezes an agent,
snapshots it while frozen, loses the workload, and resumes it under a valid Ed25519 token.
Added at `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/cycle_p4gov_test.go`.

It drives the real HTTP surface (`routes()`, `requireBearer`, `handleStun`, `handleResume`)
against a **real live process**, so the snapshot reads a genuine `/proc/<pid>` tree rather
than a fixture — a snapshot test against a synthetic PID proves nothing.

| Test | What it proves |
| :--- | :--- |
| `TestP4GovCycleStunSnapshotUnstunEndToEnd` | Full cycle. Snapshot is captured *by the stun path*, contains the frozen PID, survives `kill` of the target, reloads by `CaptureID`, and resume returns attributed `operator_ids` + `token_id` in both the HTTP response and the telemetry event. |
| `TestP4GovCycleUnderOverBudgetSnapshotReportsPartialAndCompletes` | With a 1-byte / 1-ns budget the cycle completes in bounded time (30 s guard), returns 200, persists a snapshot marked `Partial` with a machine-readable `PartialReason`, emits `QuarantineSnapshotPartial`, and **resume still succeeds afterwards**. Graceful partial, not a hang. |
| `TestP4GovConcurrentMultiNodeFreezeAndSnapshot` | Four simulated nodes released simultaneously each freeze-and-snapshot. 90 s convergence guard; asserts every node got exactly one snapshot and that no `CaptureID` collided across nodes. |
| `TestP4GovFreezePlaneEmitsOneConsistentEventShape` | §1.2 above. |

**The suite was falsified before being trusted.** Two mutations were injected into
`main.go` and both were killed:

```
mutation: obs.OperatorIDs = nil
  → FAIL cycle_p4gov_test.go:311: resume telemetry is unattributed: <nil>
mutation: captureQuarantine := false
  → FAIL cycle_p4gov_test.go:224: want exactly 1 forensic snapshot captured by the stun path, got 0
```

`main.go` was restored byte-identical (`git diff --stat` empty) and the suite returned green.

**Known fixture limitation, stated rather than hidden.** `cgroup.events` is kernel-maintained;
a file on tmpfs never flips `frozen 1` → `frozen 0` when `cgroup.freeze` is written. The test
calls `emulateKernelThaw()` before the resume step to model that transition. This is a
property of the mock, not a waiver: the un-emulated run produced a *correct* `ErrAncestorFrozen`
from the engine, which is itself evidence the ancestor diagnostic works.

---

## 3. Denial matrix numbers for P5-2

**Read the caveats before quoting any of these.** All figures were measured on a single
host, not a fleet.

### 3.1 Guaranteed denial latency — freeze plane

| Measure | Value | How measured | n |
| :--- | :--- | :--- | :--- |
| Freeze latency, p95, under 100% CPU load | **12 ms** | `scripts/run-redteam-suite.sh`, real host cgroup-v2 freezer, 10 cycles under stress, 2026-09-15T05:32:18Z | 10 cycles, 1 node |
| Freeze latency, mean, under 100% CPU load | **13 ms** | same run | 10 cycles, 1 node |
| Watchdog timeouts under load | **0** | same run | 10 cycles |
| Thread D-state transition | **100%** | same run | 10 cycles |
| Freeze, engine-only microbenchmark | **25.96 µs/op** (3496 B/op, 45 allocs) | `go test ./pkg/cgroup -bench BenchmarkFreeze -benchtime 2000x`, AMD Ryzen 9 7900X | 2000 iters |
| Unfreeze, engine-only microbenchmark | **26.15 µs/op** (3501 B/op, 45 allocs) | same | 2000 iters |
| Pod cgroup resolution | **6.51 µs/op** | same | 2000 iters |

The microbenchmarks run against a mock hierarchy on tmpfs; they measure the engine's own
cost, **not** kernel freeze convergence. The 12 ms p95 is the number that belongs in a
denial matrix. The µs figures do not — quoting them as denial latency would overstate the
control by three orders of magnitude.

### 3.2 Forensic capture cost (added to the freeze critical path when enabled)

| RSS | Captured | Wall | Partial |
| :--- | :--- | :--- | :--- |
| 1 MB | 79.7 MB | 57.71 ms | no |
| 10 MB | 89.2 MB | 97.25 ms | no |
| 50 MB | 104.9 MB | 108.09 ms | **yes** (hit 64 MB default budget) |

Capture is post-freeze, so it does not delay denial — but it does delay the containment
*call's* return. With `capture_quarantine: true` the caller waits freeze + capture.

### 3.3 Unfreeze-to-rotation latency — NOT MEASURED

**This figure does not exist and must not be fabricated.** The sentinel's `/resume` handler
performs no rotation at all (see F2); rotation lives in `fleet-manager`, and every
`fleet-manager` rotation test drives a **mock** client (`cascade_test.go:20,70`), never
OpenBao or SPIRE. The `latency_ms: 2` in P4-3's proof §5.1 is a stub-path figure.

P5-2's denial matrix should carry `unfreeze→rotation: unmeasured` for the freeze plane until
F8 is closed. The mission's own out-of-scope rule forbids "claiming a latency figure not
measured at the stated fleet size", and that applies here with full force.

### 3.4 Kernel-version floor

**Floor: Linux ≥ 5.2**, the release in which `cgroup.freeze` landed on the cgroup-v2 unified
hierarchy. The engine has no other kernel-version dependency for the freeze path.

**Caveat P5-2 must carry.** P4-1 calls this a "fleet check"; it is not. P4-PRE §4.1 probed
exactly **one** node — `osramp-control-plane` in the `kind-osramp` Kind cluster, Debian 13
(trixie), kernel `7.1.3+deb13-amd64`, containerd 2.3.1, `stat -f /sys/fs/cgroup` =
`cgroup2fs`. That node is the developer host itself (confirmed: `uname -r` on this machine
also returns `7.1.3+deb13-amd64`). n=1, and the 1 is not a production node pool.

Cross-reference filed alongside this report at
`docs/signalloom/sler-p4-kernel-floor-crossref.md`.

---

## 4. Blocking findings

### F1 — Neither deployed manifest wires quarantine storage or operator keys · **Blocking**

This is the finding that withholds certification.

**Manifest A** (`deploy/stun-sentinel-daemonset.yaml`) — the one that runs the unified
daemon — contains **zero** references to `quarantine`, `/var/log/signalloom`, or any
`OPERATOR_KEY*` variable. It sets `readOnlyRootFilesystem: true` (148) with only an
`emptyDir` at `/tmp` (158).

Two consequences follow directly:

1. **P4-2's snapshots would not survive pod deletion in deployment.** The capturer defaults
   to `/var/log/signalloom/quarantine/`, which is not a hostPath in this manifest. On a
   read-only root the capture fails outright; were it redirected to the `/tmp` emptyDir it
   would die *with* the pod — inverting the card's central claim. `TestSnapshotSurvivesPodDeletion`
   passes because it writes to `t.TempDir()` on the test host, which is not the deployed path.
2. **P4-3's attributable resume is undeployable.** `run()` loads the operator key registry
   only from `cfg.operatorKeyPath` or `cfg.operatorKeysJSON` (main.go:530-542). Neither
   manifest sets `OPERATOR_KEY_DIR`, `OPERATOR_KEY_BUNDLE_FILE` or `OPERATOR_KEYS_JSON`, and
   there is no ConfigMap and no volume for them. `registry` is therefore `nil` in deployment,
   Ed25519 verification cannot succeed, and the daemon falls through to the symmetric token —
   which is F2.

P4-3's proof §3 describes three distribution mechanisms in detail. All three are implemented
in Go and none is wired into a manifest. That is design-only, exactly as the card warned.

### F2 — Legacy symmetric resume fallback defeats attribution, rotation and replay protection · **Blocking**

`ed25519ResumeValidator(registry, policy, fallbackToken)` (main.go:114) accepts a plain
shared secret whenever `fallbackToken != ""`:

```go
if fallbackToken != "" {
    return constantTimeTokenValidator(fallbackToken)(got)
}
```

`fallbackToken` is `cfg.resumeToken` = `STUN_RESUME_TOKEN`, which **both** manifests set
(A:129, B:54). So in the deployed configuration the pre-P4-3 shared secret still unlocks
`/resume`.

Trace what happens on that path in `handleResume`. `req.Token` is nil and the header is not
a parseable resume token, so `tokenParsed` stays `false`. Therefore:

- `operatorIDs` stays empty and `tokenID` stays `""` — the emitted `StunExecutionResumed`
  event carries **no attribution**;
- the `if tokenParsed` block is skipped entirely, so **`s.replayLedger.CheckAndRecord` is
  never called** — no single-use enforcement, no idempotency;
- the handler then calls `s.freezer.UnfreezePod(...)` and returns 200.

And the handler performs **no credential rotation at any point** — there is no OpenBao or
SPIRE call in the sentinel's resume path. Rotation is orchestrated by `fleet-manager`, which
then calls this endpoint.

Net effect: a caller who can reach the sentinel with `STUN_RESUME_TOKEN` unfreezes a
contained agent with **no operator attribution, no credential rotation, and no replay
protection**, and the action is logged as a successful resume. "Attributable resume" and
"mandatory rotation" are properties of the *fleet-manager route*, not invariants of the
freeze plane. Since the cluster-wide shared secret is exactly what P4-3's own executive
summary identifies as making attribution "structurally impossible", the defect it set out
to fix is still reachable in the shipped configuration.

**Remediation shape:** once F1 distributes operator keys, pass `""` as the fallback (as the
test harness already does) and delete `STUN_RESUME_TOKEN` from both manifests, keeping the
startup check satisfied by the registry arm of main.go:545.

### F3 — Forensic snapshot read endpoints are unauthenticated · **Blocking**

```go
mux.HandleFunc("/quarantine/snapshots", s.handleListSnapshots)   // no requireBearer
mux.HandleFunc("/quarantine/snapshots/", s.handleGetSnapshot)    // no requireBearer
mux.HandleFunc("/quarantine/prune", requireBearer(s.freezeValidate, s.handlePruneSnapshots))
```

The mutating endpoint is gated. The two that *read forensic data* are not. They return
`QuarantineManifest`, which embeds `Processes []ProcessQuarantineState`, and that type
carries `Cmdline []string`, `FileDescriptors []FDInfo`, `Sockets []SocketInfo`,
`MemoryRegions []MemoryRegion`, `HeldLocks []LockRecord` and `StoragePath`.

The card asked me to check the deployed storage location's *actual* access controls rather
than trust P4-2's documentation of intended policy. The documented policy is real — I
confirmed `0700` directories and `0600` artifacts are created as described, and
`TestSnapshotPermissionsAreStrict` passes. **But POSIX mode is not the access control that
governs the deployed system**, because the daemon itself runs as root, reads those exact
files, and serves their contents over HTTP with no credential. The intended control is
bypassed by the product that implements it.

Severity is raised by what the fields contain: process argv routinely carries API keys and
tokens; socket tables expose peer addresses; memory-region layout defeats ASLR on a
privileged, `hostPID` daemon. The mission's out-of-scope list says this work must not
collect "customer file contents, prompt text or credentials" — serving agent argv
unauthenticated sits close enough to that line to warrant a stop.

Only Manifest A's NetworkPolicy stands in front of this, and Manifest A is not the manifest
Flux deploys (§F4). Manifest B uses `hostNetwork: true`, where pod-level NetworkPolicy does
not apply.

**Remediation:** wrap both read handlers in `requireBearer`. One line each.

### F4 — The redundant DaemonSet and RBAC were not removed · **Blocking (explicit card requirement)**

The card required confirmation that "the redundant `signalloom-stun-sentinel` DaemonSet and
its RBAC were actually removed from the cluster manifests, not merely deprioritised in
documentation." **They were not removed.** All four files are present:

```
d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml
d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac.yaml
d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/service-account.yaml
d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/kustomization.yaml
```

Flux still reconciles them: `d2-osramp-fleet/tenants/base/agent-swarm.yaml:559-576` declares
Kustomization `agent-signalloom-stun-sentinel` with `path: ./signalloom-stun-sentinel`.
P4-1 *added 12 lines* to that DaemonSet rather than deleting it. Two Go modules, two
Dockerfiles and two binaries remain.

**However — do not simply delete them, and this is the part the card's framing did not
anticipate.** P4-PRE §3.2 established that Manifest B is the **only** sentinel Flux actually
deploys; Manifest A's namespace `signalloom-system` does not exist in `kind-osramp`.
Deleting the "redundant" DaemonSet today removes the cluster's *only* running containment
DaemonSet. The correct sequence is: deploy Manifest A (which runs the unified daemon and
carries the `/stun` API the Fleet Manager dispatches to), verify it, migrate the Flux
Kustomization, and only then delete Manifest B and its RBAC.

I have **not** confirmed post-merge DaemonSet count in a live or Kind cluster. No cluster
was reachable from this worktree, and the card forbids enforcing against live infrastructure.
That confirmation remains outstanding and is listed in §6.

---

## 5. Non-blocking findings

### F5 — Hardcoded universal-accept token in the unification adapter · High

`signalloom-stun-sentinel/freezer.go:14,34`:

```go
const defaultInternalToken = "internal-controller-reconcile-token"
...
return got == expected || got == defaultInternalToken
```

Two problems. The disjunction makes the configured token decorative — the hardcoded constant
always passes. And the comparison is `==`, not constant-time, in an adapter whose whole
purpose was to inherit the mature engine's constant-time validation.

P4-PRE §2.2 item 3 recorded "No Credential / Governance Gate" as a capability gap in this
sentinel. The adapter now *appears* to close it while accepting a compile-time constant, so
the gap is disguised rather than fixed — which is worse than leaving it visibly open.

Severity is High rather than Blocking because this binary exposes no HTTP freeze surface
(only `/healthz` on :8081); it is driven by the informer. The constant is not remotely
reachable today. It is one route addition away from being so.

### F6 — P4-PRE §7.2 and §7.3 were not executed · Medium

P4-PRE's unification plan had four steps. Step 1 (adopt `pkg/cgroup` as the sole engine) and
step 4 (preserve permissions) were done. Steps 2 and 3 were not:

- **§7.2 — integrate both dispatch models into one daemon.** `apps/stun-sentinel` contains no
  informer (`grep -rn 'informer\|signalloom.ai/state'` over its Go sources returns only a
  comment in `cmd/stun-tcctl/main.go:8`). HTTP dispatch and informer dispatch remain in two
  separate binaries.
- **§7.3 — retire fork/exec `tc` calls.** `signalloom-stun-sentinel/network.go` still shells
  out via `exec.Command` at eight sites (lines 212, 215, 218, 228, 231, 241, 245) and does
  not import `pkg/tc`. The eBPF path was ported *into* `stun-sentinel/pkg/ebpf` but the old
  caller was never switched over.

"Unified" is therefore accurate for the freeze engine and inaccurate for the daemon. P4-1's
proof says "comprehensive unification of the two previously fragmented containment
implementations", which overstates what shipped. F4 cannot be closed until F6 is.

### F7 — Kernel floor is an n=1 claim · Medium

See §3.4. Recorded so P5-2 can caveat the node pool rather than inherit a fleet claim.

### F8 — Rotation is proven against stubs only · Medium

Every `fleet-manager` rotation test injects a mock (`cascade_test.go:20 revokeErr`,
`:70 return m.revokeErr`). The negative path is well covered — `cascade_test.go:286`
explicitly guards "regression: a cascade whose credential revoke failed reported contained",
which is good discipline. But no test exercises P2-1's OpenBao client or P2-2's SPIRE client
against a real server, so a misconfigured client in a test environment would let the cycle
pass while rotation never occurred. This is the failure mode the card named; it is present.

### F9 — P4-3's proof documents an event name the code does not emit · Low

Proof §5.2 shows `"event": "stun_execution_resumed"` (snake_case). The code emits
`EventStunExecutionResumed = "StunExecutionResumed"` (PascalCase). Anyone building a P5-1
attestation parser from the proof document will not match a single event.

---

## 6. Outstanding confirmations

Items the card asked for that I could not close, stated rather than glossed:

1. **Live/Kind confirmation that exactly one sentinel DaemonSet runs post-merge.** No cluster
   reachable from this worktree; enforcing against live infrastructure is out of scope for
   this card.
2. **Canary rollout for this phase's own merge.** P4-1's proof does not in fact contain a
   canary recommendation — the card's premise that it does is not borne out by
   `docs/signalloom/sler-p4-1-proof.md`. Given `hostPID` + `privileged` on every node, a
   canary is still the right call, and §7 records it as a recommendation rather than a
   confirmation of one.
3. **Unfreeze-to-rotation latency.** Not measured; see §3.3.

---

## 7. Recommendation

Do not close phase 4. The remediation is small relative to what was built — F3 is two lines,
F2 is one argument plus two manifest deletions, F1 is a hostPath and a ConfigMap volume, F5
is one boolean expression. F4 needs the migration sequence in §4, not a deletion.

When the freeze plane is redeployed, roll it as a canary: one node, verify `/healthz`
reports a writable hierarchy and a non-zero `operator_keys_enrolled`, run the cycle test
against that node, then widen. A `hostPID`, `privileged` DaemonSet that fails open on every
node simultaneously removes the cluster's entire containment capability in one step.

---

## 8. Evidence index

| Artefact | Path |
| :--- | :--- |
| End-to-end cycle test | `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/cycle_p4gov_test.go` |
| Kernel floor cross-reference | `docs/signalloom/sler-p4-kernel-floor-crossref.md` |
| Red-team scenario evidence | `docs/signalloom/evidence/adversarial-redteam-proof.json` |
| P4-PRE capability diff | `docs/signalloom/sler-p4-pre-freezer-diff.md` |
| P4-1 / P4-2 / P4-3 proofs | `docs/signalloom/sler-p4-{1,2,3}-proof.md` |
