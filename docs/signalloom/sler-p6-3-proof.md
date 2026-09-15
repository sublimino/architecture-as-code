# SLER-P6-3 — Multi-Plane Containment Acceptance Suite

**Card:** SLER-P6-3 · **Phase:** 6 · **Integration branch:** `integration/sler-v0.1.0`

An automated end-to-end acceptance suite proving one containment decision fans
out across all five enforcement planes, with per-plane assertions, coverage
derived from P1-2's plane enum rather than a hand-kept list, and wiring that is
itself asserted rather than claimed.

---

## 1. What this suite proves, and what it deliberately does not

| Suite | Question it answers | Pass criterion |
|---|---|---|
| **SLER-P6-3** (this) | Does one containment decision actually contain, on every plane, on the ordinary path — and can it be reversed only through governance? | every `PlaneResult` is `contained` within its published bound; partial is representable and names its plane; resume rotates credentials |
| **SLER-P6-1** (`scripts/run-redteam-suite.sh`, `test/crkc-adversarial-redteam.bats`) | Can an adversary escape the cascade? | `.metrics.process_escapes == 0` across 24 adversarial scenarios |

The two are complementary and are kept distinct **by construction**, not by
comment. `TestAcceptance_DoesNotDuplicateRedTeamScenarios` reads P6-1's published
corpus at `docs/signalloom/evidence/adversarial-redteam-proof.json` and fails if
any acceptance scenario name normalises to a red-team scenario name, or if an
acceptance ID strays into P6-1's `scenario-NN` namespace. It carries a positive
control — the comparison must be able to match P6-1's own first scenario — so a
normaliser that mangled every string could not make the non-overlap result pass
vacuously.

One surface is covered by both, on purpose: the combined credential + mesh case.
P6-1 scenario-21 attacks it (simultaneous credential replay and egress; asserts
zero leaks, zero secret accesses). Acceptance `acc-05` asserts the complementary
thing — that both planes report `contained`, under one idempotency key, inside
their separately published latency bounds. Same surface, different question, no
shared assertion.

---

## 2. The derived-coverage mechanism

### 2.1 The defect being closed

`scripts/run-redteam-suite.sh:320` carries:

```bash
REQUIRED_PLANES=("freeze" "mesh" "bao" "spire" "admission")
```

A hand-written bash array. Correct today; silently wrong the moment a plane is
added or renamed, because nothing connects it to the artefact that decides. This
is precisely the class `test/acceptance-spec-coverage.bats` was written for after
commit `d9d1d2f` rewrote a Playwright test that nothing was ever wired to run —
Playwright reported a smaller total rather than complaining that nothing claimed
the spec.

### 2.2 The source of truth

Coverage derives from **`AllEnforcementPlanes()`** in
`d2-signalloom/apps/fleet-manager/schema.go:74` — P1-2's plane enum, the same
member list `frozen_contract_table_test.go:262` freezes. Not the const block
alone: a constant that exists but is absent from `AllEnforcementPlanes()` is not
a plane the cascade dispatches, and demanding coverage for it would make the
guard wrong in the opposite direction.

### 2.3 Two independent derivations

| Layer | Reads | Implementation |
|---|---|---|
| Go | `AllEnforcementPlanes()` directly, as values | `planeCoverageDrift()` in `multiplane_acceptance_test.go` |
| bats | `schema.go` source text — const block **and** the function body, resolved against each other | `enum_planes()` / `registry_planes()` in `test/sler-p6-3-multiplane-acceptance.bats` |

Two implementations in two languages would have to be wrong in the same
direction to agree. The bats parser resolves identifiers (`PlaneBao`) through the
const block to wire values (`bao`) so a rename surfaces as drift rather than as
two matching mistakes, and it strips `//` comments from the Go suite first — the
suite's prose names planes at length, and counting a comment as a coverage claim
would let a scenario drop a plane while still reading as covering it.

### 2.4 Both directions, always

- **uncovered** — a plane the enum declares that no scenario claims. Goes red when a **sixth plane lands**.
- **unknown** — a plane a scenario claims that the enum does not declare. Goes red when a plane is **renamed** — the direction a one-way check misses entirely, because a renamed plane leaves the old value claimed and the new value simply absent.

### 2.5 The guard can be made to fail

A derived guard that cannot fail is decoration. Five executed controls, not
sentences:

| Control | Test | Proves |
|---|---|---|
| Drift | `TestAcceptanceCoverage_FailsOnSyntheticSixthPlane` | a synthetic sixth plane (`quarantine`) injected into the enum is reported uncovered |
| Drift (shell) | `the derived coverage check fails when a plane has no scenario` | the bats `comm` comparison reports the same synthetic plane |
| Rename | `TestAcceptanceCoverage_FailsOnRenamedPlane` | a claim on `mesh-v2` is reported unknown |
| Vacuity | `TestAcceptanceCoverage_FailsOnEmptyRegistry` | an empty registry leaves every plane uncovered, rather than passing |
| Over-match | negative-control probe `__acceptance-coverage-probe__` | a name no scenario can mean does **not** resolve |

---

## 3. Scenario registry

| ID | Kind | Planes claimed | Driving test |
|---|---|---|---|
| `acc-01` | lifecycle | mesh, bao, spire, admission, freeze | `TestAcceptance_FullLifecycle_FivePlanes` |
| `acc-02` | lifecycle | mesh, bao, spire, admission, freeze | `TestAcceptance_ContainmentIsAttested` |
| `acc-03` | lifecycle | freeze, bao, spire | `TestAcceptance_GovernanceGatedResumeClosesTheLifecycle` |
| `acc-04` | partial | mesh, bao, spire, admission, freeze | `TestAcceptance_PartialContainment_NamesTheFailingPlane` + `..._EveryPlaneInTurn` |
| `acc-05` | combined | bao, mesh | `TestAcceptance_CombinedCredentialAndMeshPlane` |
| `acc-06` | environment | mesh, bao, spire, admission, freeze | `TestAcceptance_EnvironmentPreflight_FailsLoudly` |

### 3.1 Claims are bound to behaviour, not trusted

An advisor pass found the joint where this whole derivation chain could be true
and still vacuous: the registry **declares** which planes each scenario
exercises, and nothing bound that declaration to the scenario actually asserting
anything. A scenario declaring five planes and asserting on one was green, and
coverage read 5/5.

Every per-plane assertion now routes through `planeAssertions.record`, and each
scenario closes with `assertScenarioClaimObserved`, which fails in **both**
directions — over-claimed (declared, never touched) and under-claimed (touched,
not declared). Coverage is therefore computed from execution, not from a struct
literal.

Falsified by mutation. Widening `acc-05`'s row to claim all five planes while it
still asserts on two:

```
--- FAIL: TestAcceptance_CombinedCredentialAndMeshPlane
    scenario acc-05 CLAIMS planes it made no assertion about: [admission freeze spire]
```

`TestAcceptance_ClaimObservationCheckIsFalsifiable` additionally proves the
comparison detects an exact match, an over-claim and an under-claim.

`acc-03` claims three planes rather than five on purpose. Resume drives the two
credential planes and reverses the freeze; mesh and admission re-open through
their own `RestoreMeshPlane` / `UnblockAdmissionPlane` calls, which that scenario
does not drive. Overclaiming there would let a real gap read as covered.

---

## 4. Per-plane assertion, not aggregate

`TestAcceptance_FullLifecycle_FivePlanes` indexes `dec.PlaneResults` by plane and
runs a Go subtest **per plane**, asserting outcome, empty error, RFC3339Nano
timestamp, non-negative latency, and the published bound — individually.

Reading `OverallOutcome` alone is the aggregate trap: four contained planes plus
one plane that never reported aggregates to `contained`, because a plane that
contributes no result contributes nothing to disagree with. The suite therefore
also asserts `len(dec.PlaneResults) == len(AllEnforcementPlanes())`.

---

## 5. Partial containment names the plane

`TestAcceptance_PartialContainment_NamesTheFailingPlane` injects a single-plane
failure (OpenBao returning HTTP 500) and asserts three separable things, because
a maintainer reading a failed run needs all three and an aggregate gives none:

1. `OverallOutcome == OutcomePartial` — not `contained`, not `unavailable`. This
   is the case P1-2 and P1-5's schema work exists to make representable; a suite
   that only tests the two extremes does not prove the schema achieved anything.
2. **Exactly one** failing plane, and it is `bao` — by name, from
   `failingPlanes()`, with the plane's own `Error` text asserted non-empty so the
   run says *why* and not only *which*. Sample output:
   `partial containment: plane=bao outcome=unavailable error="enforcement unavailable: openbao server error (status 500): "`
3. All four sibling planes still `contained` — a partial is not a licence for the
   rest to quietly do nothing.

`failingPlanes()` is falsified independently by
`TestAcceptance_PartialContainment_DetectorIsFalsifiable`: a clean result set
must yield none, a mixed set must yield exactly the failing plane. Without that,
a detector returning everything would satisfy "exactly one" for the wrong reason.

---

## 6. Loud failure, never a skip

A skip on a missing dependency turns a build failure into a silent pass. The
suite closes this three ways:

- `TestAcceptance_EnvironmentPreflight_FailsLoudly` checks each of the five plane
  clients is wired **and** that `Health()` answers, and `t.Fatal`s naming the
  plane and its role. It also asserts its own wiring-check count equals
  `len(AllEnforcementPlanes())`, so a plane added to the schema without a wiring
  check fails here.
- `TestAcceptance_SuiteContainsNoSkips` reads the suite's own source and rejects
  any skip call. Its needles are built by **concatenation**, because written as
  plain literals the guard matched itself — it read its own forbidden-token slice
  and reported four violations in a file containing none. The same trap caught an
  earlier draft of the explanatory comment, which quoted a token.
  `TestAcceptance_NoSkipGuardIsFalsifiable` proves the assembled needles still
  match a real call site and do **not** match a clean file.
- The bats guard repeats the check from outside, so deleting the Go guard does
  not also delete the check — and carries its own pattern-falsification probe.

---

## 7. Timing bounds come from the machine-readable export

Every latency assertion reads
**`docs/signalloom/sler-p5-2-denial-matrix.json`** — P5-2's machine-readable
export — never the prose sibling and never a figure written into the suite. A
re-benchmark in P5-2 therefore flows through with no edit here, which is the
whole point: hard-coding today's numbers would leave this suite asserting stale
figures with no test catching the drift.

### 7.1 The `openbao` / `bao` key trap

The export keys the OpenBao entry as `"openbao"` while the entry's own `plane`
field is `"bao"`. `acceptanceDenialBounds` is therefore indexed on the **`.plane`
field**, not the JSON object key. Indexing on the key leaves `PlaneBao` unbound —
and an unbound plane has its timing assertion *skipped* rather than failed, which
reads as coverage. `TestAcceptance_DenialBoundsCoverEveryPlane` carries a
positive control on exactly this, and the bats guard repeats it.

### 7.2 What the latency numbers actually measure — a finding

Writing the negative control for this section surfaced a defect worth stating
plainly, because it bounds what every timing assertion here can mean.

The control was written to prove a slow plane makes its bound bind. Injecting a
65 ms delay into the mesh client produced a `PlaneResult` reporting **1 ms**.
That is not a test bug. `k8sclient.go:658` builds the mesh result via
`MeshIsolationResponseToPlaneResult`, which copies `resp.LatencyMs` — **the
number the plane client reports about itself**. The orchestrator never times the
call. The same holds for `bao`, `spire` and `admission`. Only `PlaneFreeze` is
wall-clock measured, at `k8sclient.go:1037`.

**Consequence:** for four of the five planes, a plane that is genuinely slow
while reporting a small number is invisible. Those assertions detect a plane that
*reports* a regression, not a plane that *has* one.

This is the plane clients' contract — owned by the P2/P3/P4 cards, not this one —
so it is recorded rather than changed. But it is recorded as an **executed
characterisation**, `TestAcceptance_PlaneLatencyProvenance`, not a sentence in a
document:

- *freeze* — a real injected delay makes its published bound bind. Asserted.
- *mesh* — a real injected delay does **not** move the reported latency.
  Asserted, with a failure message instructing the next maintainer to update this
  section if mesh ever becomes orchestrator-measured.

Recommended follow-up for whichever card owns the plane clients: have
`ContainAllPlanes` stamp each `PlaneResult.LatencyMs` from its own `time.Since`,
as the freeze branch already does, and keep the plane's self-report in `Details`.

### 7.3 The predicate is falsifiable

Under the in-process fakes every plane reports 0 ms, so `latency <= threshold`
cannot currently fail — an assertion that would never notice if the bounds
stopped being read at all. What these assertions actually guard is a
**regression in the fan-out code path** (a plane that starts blocking, a
serialised dispatch) measured against a published figure. To keep that honest,
the comparison is extracted as `exceedsPublishedBound()` and
`TestAcceptance_TimingPredicateIsFalsifiable` asserts, per plane: a latency
exactly at the threshold is inside, one millisecond over is outside, and the
published p99 sits strictly below the threshold.

### 7.3 Graceful degradation

`loadAcceptanceDenialBounds` names the file and the owning card on every failure
path. `TestAcceptance_DenialBoundsDegradeGracefully` drives six fault-injected
fixtures — missing, truncated, no planes, entry with no `plane` field, entry
naming a plane the schema does not declare, entry with a non-positive threshold —
and asserts the message names the file and the specific problem. A raw
`unexpected end of JSON input` tells a maintainer nothing about which of the
repo's several JSON artefacts broke or who to ask.

---

## 8. Runtime tracking

| Mechanism | Purpose |
|---|---|
| `docs/signalloom/evidence/sler-p6-3-acceptance-runtime.jsonl` | append-only per-scenario history, so gradual creep is visible before it matters |
| `TestAcceptance_RuntimeIsPracticalForCI` | the gate: three full five-plane fan-outs must complete inside `acceptanceRuntimeCeilingMs` (20 000 ms) |
| `TestAcceptance_RuntimeLedgerIsWritten` | proves the recorder is not a no-op the WARN path silently swallows, and that every line parses |

A ledger write failure is a **warning**, never a test failure: the ledger is
observability, and a read-only CI filesystem must not turn a passing acceptance
run red. The ceiling assertion does not depend on the ledger being writable.

Measured on the integration branch: the whole `TestAcceptance` corpus runs in
**~0.02 s** (the fleet-manager package as a whole is ~1.5 s), so the suite is
comfortably practical on every CI change rather than on demand.

---

## 9. CI wiring — asserted, not claimed

| Surface | Entry point |
|---|---|
| Make target | `make test-sler-multiplane-acceptance` (runs the Go suite **and** this guard) |
| CI stage (suite) | `scripts/ci/vm-pipeline.sh` → `stage1c3-multiplane-acceptance.tap` |
| CI stage (guard) | `scripts/ci/vm-pipeline.sh` → `stage1c4-acceptance-plane-coverage.tap` |
| Offline lane | `make test-all-offline` |
| Red-team gate | `scripts/run-redteam-suite.sh` runs the acceptance target before writing any evidence |

Each of these is **read back** by `test/sler-p6-3-multiplane-acceptance.bats`
from the artefact that decides — `make_recipe()` reads the Makefile recipe,
`stage_command()` reads the `run_stage` invocation keyed on its report filename,
the same way `openreports-convert.sh` keys on that string. A target that exists
but whose recipe does not run the suite fails; a registry row claiming CI
coverage that CI does not provide is worse than no row, because it reads as a
guard while guarding nothing.

Stages `1c3` / `1c4` are numbered rather than renumbering `1d` onward because
`openreports-convert.sh` maps report *files* to parsers by name — the same reason
`1b` and `1c2` sit where they do.

The guard gets its **own** stage even though the make target already runs it.
That looked redundant until `d2-signalloom/test/bats-registry-coverage.bats`
failed on the first wiring attempt with:

```
not ok 10 every repo-root bats suite is invoked by the CI pipeline
# Repo-root bats suite(s) that scripts/ci/vm-pipeline.sh never runs:
#   sler-p6-3-multiplane-acceptance.bats
```

Two reasons it was right. `run_stage` writes one report per stage, so folded
into 1c3 a coverage-drift failure and a Go acceptance failure land in the same
blob and the converter cannot say which contract broke. And a repo-root suite
that no `run_stage` *names* is invisible to the registry guard — the mechanism
this repo uses to notice a suite that has quietly stopped running.
Reachable-via-a-make-target is precisely the category
`acceptance-spec-coverage.bats` exists to separate from real CI coverage. The
~0.4 s overlap is cheaper than the ambiguity. `test 9` in the guard asserts its
own stage exists, so the two stages cannot be silently re-merged.

### 9.1 The red-team gate

`scripts/run-redteam-suite.sh` now runs `make test-sler-multiplane-acceptance`
before the benchmark and before writing `adversarial-redteam-proof.json`. The
escape counts it publishes are only meaningful if the cascade contains on the
ordinary path. `SLER_SKIP_ACCEPTANCE_GATE=1` exists for the one legitimate case —
re-running the corpus on a host with no Go toolchain — and prints two `WARNING`
lines to stderr rather than skipping silently.

### 9.2 Relationship to `test/acceptance-spec-coverage.bats`

That suite governs **Playwright** specs in `test/acceptance/`, keyed on
`SPEC-REGISTRY.tsv` and `playwright.config.ts`. It structurally cannot claim a
Go + bats suite, so it does not — and was not extended to, since widening it to
two unrelated test technologies would weaken the parser discipline that makes it
work. It is run as a required regression check (green, 7/7), and its *pattern* —
derive one side from the artefact that decides, assert both directions, refuse to
guess, carry positive and negative controls — is what
`test/sler-p6-3-multiplane-acceptance.bats` reproduces for this suite.

---

## 10. Verification

```
$ cd d2-signalloom/apps/fleet-manager && go test -run TestAcceptance -count=1 -v .
ok      .../fleet-manager   0.175s      # 23 tests, 0 failures

$ bats test/sler-p6-3-multiplane-acceptance.bats
ok 1..13

$ bats test/acceptance-spec-coverage.bats
ok 1..7                                  # unchanged, no regression

$ bash scripts/run-redteam-suite.sh
Total Process Escapes: 0                 # gate passes, 5/5 plane coverage

$ bats test/crkc-adversarial-redteam.bats
ok 1..27                                 # unchanged, no regression

$ bats d2-signalloom/test/bats-registry-coverage.bats
ok 1..10                                 # incl. "every repo-root bats suite is invoked by the CI pipeline"

$ make test-sler-multiplane-acceptance
real    0m1.262s                         # whole target: 23 Go tests + 13 bats tests
```

### 10.1 Falsification run — the guard made to fail on demand

A green derived guard proves nothing unless it can go red. `PlaneQuarantine`
was temporarily added to `schema.go`'s const block **and** to
`AllEnforcementPlanes()`, with no matching acceptance scenario. Both
derivations — Go and bats, independently implemented — reported it:

```
--- FAIL: TestAcceptanceCoverage_DerivedFromPlaneEnum
    planes declared by AllEnforcementPlanes() with NO acceptance scenario: [quarantine]
    plane "quarantine" resolves to no scenario ID even though the drift check passed

not ok 2 every plane schema.go declares is claimed by an acceptance scenario
# planes AllEnforcementPlanes() declares that NO acceptance scenario claims:
# quarantine

not ok 5 P5-2 publishes a bound for every plane the schema declares
# planes with no entry in docs/signalloom/sler-p5-2-denial-matrix.json:
# quarantine
```

`schema.go` was restored from a copy taken before the mutation and confirmed
byte-identical (`git diff --stat` empty) afterwards.

The run also exposed a defect in the guard's **own** falsification control: it
used `quarantine` as its synthetic probe name, which collided with the mutation
and made test 4 fail for a reason unrelated to what it tests. The probe is now
`__coverage-drift-probe__` — a name `schema.go` could never declare. A control
that collides with the thing it controls for reports noise at exactly the moment
its signal matters.

---

## 11. Known limitations

- **Fakes, not a live cluster.** The suite drives `k8sFleetClient` against
  `k8s.io/client-go/kubernetes/fake`, an `httptest` OpenBao, and the in-process
  SPIRE/mesh/admission mocks from `denial_matrix_test.go`. It proves the
  orchestration contract end to end; it does not prove kernel-level cgroup freeze
  or real conntrack severance, which are P2/P3's surfaces and are measured in the
  denial matrix this suite reads from.
- **Latency is self-reported on four of five planes.** See §7.2 — this is the
  most important limitation in this document. Only `freeze` is
  orchestrator-measured, and only `freeze`'s bound is proven to bind under a real
  delay.
- **P6-1's corpus is a static artefact.** `run-redteam-suite.sh` writes its 24
  scenarios as a literal heredoc rather than executing them. The non-overlap
  check in §1 compares against what that file publishes, which is the same thing
  any downstream consumer reads — but it is a comparison against a published
  claim, not against executed adversarial code.
- **`tc_drop.bpf.o` is not in git.** It is matched by a `*.o` rule in the
  developer's global gitignore, so `go test ./...` in `fleet-manager` fails at
  **setup** — before any test runs — in a fresh worktree. Regenerate with
  `d2-signalloom/apps/stun-sentinel/bpf/build.sh` (requires docker). This
  predates SLER-P6-3 and affects every Go suite in that module, not just this one.
