# SLER Final Delivery Report — SLER-P6-GOV

**Verdict: certification WITHHELD (`status=fail`).**

| Field | Value |
| :--- | :--- |
| Card | `SLER-P6-GOV` (Acceptance Governor) |
| Branch | `integration/sler-v0.1.0` |
| Tree certified against | `3310bcf7803c64058dec41f4dac27b9fa065c35d` |
| Branch advanced mid-run to | `62c12747a4ea3c38ef981e1f5671a1537e12b87f` — sibling merged AMXD-P6-2; 4 files, **no SLER surface touched**; all three loop-until-green suites re-run on it, exit 0. Every finding holds. |
| Governor worktree | `/home/andy/src/.worktrees/osramp-demo/sler-v0.1.0/governor` |
| Board state at entry | `done=29  in_progress=1` (this card) |
| Report generated | 2026-09-15 11:05:31+01:00 |

This report exists because per-phase sign-off cannot catch what a full-surface run on the
final merged tree catches. Two of the six phase Governors — **P3-GOV** and **P4-GOV** — already
withheld certification, and each named an explicit precondition. Neither precondition was met.
This card independently re-ran the whole surface and reached the same conclusion from new evidence.

---

## 1. Test surface — run end to end on `3310bcf7`

| Required command | Result | Notes |
| :--- | :--- | :--- |
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **PASS** | 2 packages `ok` (1.696s) |
| `cd d2-signalloom/apps/stun-sentinel && go test ./...` | **PASS** | 8 packages `ok` |
| `cd d2-signalloom/apps/node-capability-guard && go test ./...` | **PASS** | `pkg/webhook ok` |
| `bash scripts/run-redteam-suite.sh` | exit 0 | 24 scenarios, 0 escapes — **see §2, this is not a measurement** |
| `bats test/crkc-adversarial-redteam.bats` | exit 0 | 27/27 — asserts against the file the runner just wrote |
| `bats test/acceptance-spec-coverage.bats` | exit 0 | 7/7 |
| `make demo-agentmaxxing-docs-test` | **PASS** | 23 pages, 788 internal links, 0 unresolved, 8/8 Chromium render tests |

Two directly re-run as the card requires:

| Test | Result |
| :--- | :--- |
| `TestConcurrentBatchAttestationLoad` (P5-1 batch-load) | **PASS** — 100 events, total 9.11 ms, avg 3.06 ms/event, max 8.69 ms |
| `TestAcceptance_CombinedCredentialAndMeshPlane` (P6-1 combined-plane) | **PASS** |

**Environmental prerequisite.** `make demo-agentmaxxing-docs-test` fails `astro: command not found`
on a fresh worktree; `bun install` in `d2-signalloom/apps/docs-signalloom` is required first
(`node_modules` is gitignored). Once installed the target is genuinely green. This is a worktree
setup step, not a code defect, and is recorded so the next runner does not read it as a P6-2 failure.

---

## 2. Scenario-to-plane matrix — every plane, with its exercise status named

The card requires that a plane with no scenario behind it appear as **unexercised** rather than
absent. This is that table. "Scenarios claimed" is what `scripts/run-redteam-suite.sh` prints;
"Executed?" is what actually runs.

| Plane | Scenarios claimed by P6-1 runner | Executed adversarially? | Denial figure published by P5-2 | P5-2's own corpus status | Latency provenance in merged code |
| :--- | ---: | :--- | :--- | :--- | :--- |
| `freeze` | 14 | **Partly** — `test/bench-redteam-stress.sh` runs a real 10-cycle cgroup-v2 freeze benchmark under CPU load. The other 13 scenarios are literals. | 18 ms p99 / 0 ms residual | `active` | **orchestrator-measured** (`k8sclient.go:1047`) |
| `mesh` | 6 | **NO — unexercised.** No scenario executes. | 10 ms p99 / 0 ms (IPv4) · 120,000 ms (IPv6) | `unexercised_in_redteam_runner` | plane-self-reported |
| `bao` | 3 | **NO — unexercised.** No scenario executes. | 15 ms p99 / 300,000 ms residual | `unexercised_in_redteam_runner` | plane-self-reported |
| `spire` | 2 | **NO — unexercised.** No scenario executes. | 2 ms p99 / 300,000 ms residual | `unexercised_in_redteam_runner` | plane-self-reported |
| `admission` | 4 | **NO — unexercised.** No scenario executes. | 3 ms p99 / 0 ms residual | `unexercised_in_redteam_runner` | plane-self-reported |

**One plane of five is exercised, and only in part.** The published escape rate of zero across five
planes is therefore not a measured result. It is a constant.

### 2.1 Why: the runner writes its own answer

`scripts/run-redteam-suite.sh` executes exactly two things — the P6-3 acceptance gate (line 42)
and the freeze benchmark (line 47). Lines 54–337 are a single `cat <<JSON` heredoc containing
24 pre-authored `"status": "PASS"` records with `"escapes": 0`, and every latency literal the
runner later prints (`10.38`, `1.23`, `2.28`, `18`). Lines 344 and 355–360 then `jq`-read that same
file back and echo it as a result. There is no code path in the script that computes an escape.

`bats test/crkc-adversarial-redteam.bats` asserts against that generated file, so its 27 green
tests assert the script's literals back at the script.

### 2.2 The falsification run — the loud-failure guarantee does not hold

The card requires deliberately removing one plane client's configuration and confirming both
suites fail clearly. Run on `3310bcf7`: `d2-signalloom/apps/fe-signalloom/base/cilium-isolation-policy.yaml`
— the mesh plane's only deployed configuration artefact — was deleted, all three suites run, then
the file restored and the tree verified clean.

| Suite | Exit with mesh config deleted | Output |
| :--- | :--- | :--- |
| `scripts/run-redteam-suite.sh` | **0** | `Total Process Escapes: 0` · `[mesh] Scenarios: 6 \| Escapes: 0 \| Denial p99: 10ms` · `Zero coverage regression gate: PASSED.` |
| `bats test/crkc-adversarial-redteam.bats` | **0** | 27/27, including test 27 `redteam anti-regression: runner fails loudly if any plane is missing` |
| `bats test/acceptance-spec-coverage.bats` | **0** | 7/7 |

The test named "fails loudly if any plane is missing" passed while the mesh plane's configuration
was missing from the tree.

**Positive control, to be fair to the guard.** Retagging the two `admission` scenarios inside the
heredoc literal to `freeze` produced `FATAL: Coverage regression detected! Missing scenarios for
plane(s): admission`, exit 1. The coverage guard is live — **against the script's own literal, and
blind to the system it claims to test.**

---

## 3. Blocking findings

### B1 — Mesh and admission enforcement still have zero production callers (P3-GOV's finding, unclosed)

`ContainAllPlanes` (`k8sclient.go:990`) is the only function that fans out to all five planes.
Every reference to it outside its own definition is in `multiplane_acceptance_test.go` or
`denial_matrix_test.go`. **It has no non-test caller.**

The production path is `POST /api/v1/fleet/stun/{agentId}` → `handleStun` (`main.go:180`) →
`orchestrator.Stun` (`main.go:198`) → `CascadeOrchestrator` → the `FleetClient` interface, which at
`cascade.go:150–169` still declares five methods — `GetPodState`, `SetPodState`, `RevokeCredentials`,
`RestoreCredentials`, `Health`. Mesh and admission are not among them, and `cascade.go` contains no
`PlaneMesh`/`PlaneAdmission` reference at all.

P3-GOV handed forward a recommended card `P3-3` to wire these planes. **`P3-3` was never created**;
phase 3 holds only P3-PRE, P3-1, P3-2, P3-GOV. P4-GOV recorded the same gap as its finding 5.
P6-3's acceptance suite is well built but exercises `ContainAllPlanes` directly — a function the
deployed HTTP surface never invokes.

### B2 — A production containment attests one plane, not five

Traced end to end, as the card requires. `CascadeOrchestrator.Stun` does reach the attestation
engine (`cascade.go:385`, `:435` → `AttestContainment`), and the engine is wired at `main.go:534–551`.
But the attestation loop reads `result.Planes` (`cascade.go:386–387`), and **`CascadeResult.Planes`
is declared at `cascade.go:117` and never assigned anywhere in non-test code.**

Empirically confirmed by driving the real orchestrator:

```
PROBE len(result.Planes) = 0   (attestation reads THIS)
PROBE len(result.Targets) = 4
PROBE result.Planes JSON = null
```

So the `len(planeEvidences) == 0` fallback at `cascade.go:398–406` fires on every production
containment and synthesises a single `"freeze"` plane evidence per target, stamped with
`result.DurationMs` — the whole-cascade wall time, not a plane measurement. **The attested forensic
record for a real containment declares one plane.** Structured logging from P2/P3 never reaches it.

The attestation machinery itself is sound and its batch-load test passes; the defect is the
disconnect between the cascade's output and the attestation's input — precisely the failure mode
isolated unit tests cannot see.

### B3 — P5-2's JSON export and P6-1's runner contradict each other on the final tree

Both were built in parallel phases and have drifted, as the card anticipated:

- `docs/signalloom/sler-p5-2-denial-matrix.json` marks **four of five planes**
  `"redteam_corpus_status": "unexercised_in_redteam_runner"`.
- `scripts/run-redteam-suite.sh` prints scenario counts for all five and a
  `Zero coverage regression gate: PASSED`.

P5-2 is the honest artefact. Anyone reading the runner's output, or the runbook that cites it,
gets the opposite claim.

A second inconsistency inside P5-2 itself: it publishes `denial_provenance: "measured"` for mesh,
spire and admission. On the merged tree `LatencyMs:` is assigned exactly **once** in `k8sclient.go`
— line 1047, the freeze branch, from orchestrator-measured `elapsed`. Mesh routes through
`MeshIsolationResponseToPlaneResult`, which copies the plane's self-report. Four of five published
"measured" figures are **plane-self-reported**. P6-3 found this independently and pinned it with
`TestAcceptance_PlaneLatencyProvenance`; this card confirms it at source.

### B4 — Six cards have no errata block at all

Present: 24 blocks. Missing entirely: **`P5-1`, `P5-2`, `P5-GOV`, `P6-1`, `P6-2`, `P6-GOV`**. Their
Work Decomposition rows read `Pending`. The board shows all six `done` and their commits are on the
branch, so the delivered state and the documented state disagree for a fifth of the mission.

This card deliberately did **not** author the five absent blocks. Writing another card's errata from
a governor seat would manufacture evidence for work this card did not perform, which is the
misrepresentation the requirement exists to prevent. They are recorded here as owed.

### B5 — P4-GOV's blocking finding 3 is still open at source

`/quarantine/snapshots` and `/quarantine/snapshots/` (`stun-sentinel/cmd/stun-sentinel/main.go:510–511`)
carry **no `requireBearer`**, while the sibling `/quarantine/prune` at `:512` does. Those endpoints
return `ProcessQuarantineState` — `Cmdline`, `FileDescriptors`, `Sockets`, `MemoryRegions`,
`StoragePath` — from a `hostPID`, privileged, root daemon. Unchanged since P4-GOV recorded it.

P4-GOV finding 2 also stands: `STUN_RESUME_TOKEN` is still read at `main.go:72`, still required at
`:546`, and still set by both `deploy/stun-sentinel-daemonset.yaml:129` and
`infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml:54`.

### B6 — The runbook names an intermediate commit

`containment-runbook.mdx:10` declares **Base Commit `de2c326a`** (`docs: record Controller Tick #132`).
The certified tree is `3310bcf7` — **16 commits later**. The card requires the versioning note to
name the final certified commit before sign-off.

### B7 — SPEC-REGISTRY carries zero SLER rows

`test/acceptance/SPEC-REGISTRY.tsv` matches `sler` **0 times**. The card's required evidence is
"SPEC-REGISTRY updated". `acceptance-spec-coverage.bats` passes 7/7 because it governs Playwright
specs keyed on `playwright.config.ts`, and P6-3's suite is Go + bats — outside its scope, a
reasonable and documented P6-3 decision. The consequence stands regardless: no tracking artefact
records the 30 SLER cards as delivered with a pointer to each card's proof.

---

## 4. What genuinely passes, and should not be lost in the above

- **The no-op path is retired.** `noopFleetClient` is no longer reachable by default or from the
  environment. `fleetclient_select.go` requires the exact literal `--fleet-client=noop-test-only`
  **on the command line only**; `FLEET_CLIENT=noop-test-only` in a manifest is rejected
  (`k8sclient_test.go:808`), and 14 near-miss spellings are pinned as non-matching. The fail-closed
  case is `unavailableFleetClient`, not the no-op. This Definition-of-Done clause is **met**.
- **P6-3's derived coverage is real, and is the best-engineered artefact in the mission.** It
  derives the plane set from `schema.go`'s `EnforcementPlane` constants twice, independently — once
  in Go, once via a python parser in the bats guard that resolves identifiers through the const
  block — asserts both directions, and exits with a named `PARSE:` error rather than passing
  vacuously. It handles the `openbao` key / `bao` value trap explicitly. Both its own guards were
  falsified before being trusted.
- **The docs pipeline is genuinely green** and the runbook correctly links to P5-2's canonical
  denial-matrix page rather than duplicating it.
- **Attestation is wired into the production `Stun` path** and signs correctly under concurrent
  load. B2 is a plumbing gap upstream of it, not a defect in it.
- **The three Go suites are green** on the merged tree with no local build artefact needed.

---

## 5. Latency — recomputed on the merged tree, each figure with its fleet size

The card forbids summing per-phase figures. These are from one run of
`TestDenialMatrix_CombinedMultiPlaneContainment_FleetSizes` on `3310bcf7`:

| Fleet size | Planes × agents | Wall-clock |
| ---: | ---: | ---: |
| 1 agent | 5 ops | 1.93 ms |
| 5 agents (demo fleet) | 25 ops | 0.94 ms |
| 64 agents (scale fleet) | 320 ops | 42.93 ms |
| 256 agents (max fleet) | 1280 ops | 16.87 ms |

**These must not be published.** They are non-monotonic in fleet size — 256 agents completes in
40% of the time 64 agents takes, and 5 agents beats 1 agent. That is scheduling noise in an
in-process mock fan-out, not a scaling characteristic. They also never contact OpenBao, SPIRE,
Cilium or the webhook.

The one defensible published figure remains **freeze: p95 12 ms, p99 18 ms, mean 6 ms, at fleet
size 1, on a single node**, from 10 real cgroup-v2 freeze cycles under 100% CPU load. Stated with
its scale, as the card requires. Every other plane's figure is self-reported (§B3) and should
carry that qualification.

---

## 6. Definition of Done — assessed against merged code, not the proposal's claims

| DoD clause | Verdict |
| :--- | :--- |
| One containment decision enforces across mesh + OpenBao + SPIRE + admission + freeze | **NOT MET** — the production cascade reaches freeze and credentials; mesh and admission have no production caller (B1) |
| The no-op path is retired | **MET** |
| Purple-team escape rate = 0 on the named attack set | **NOT ESTABLISHED** — the figure is a literal, not a measurement (§2) |
| Per-plane denial matrix published (guaranteed + worst-case-residual) | **MET as an artefact, with a correction owed** — published for all five planes, but four "measured" figures are plane-self-reported (B3) |
| Stun is reversible with governance approval | **PARTIAL** — Ed25519 path implemented and tested; the symmetric `STUN_RESUME_TOKEN` bypass remains in both manifests (B5) |
| Every containment emits an attested forensic record | **PARTIAL** — a record is emitted and signed, but it declares one plane, not five (B2) |

---

## 7. Residuals published, and scope explicitly excluded

**Residuals, carried forward honestly:**
- **Credential residuals** — OpenBao 300,000 ms (5 min, bounded by downstream `token_ttl`);
  SPIRE 300,000 ms JWT-SVID / 3,600,000 ms X.509-SVID (upstream default TTLs). Both
  `config-derived`, not measured. P2-GOV's "zero residual token leakage" was correctly recorded as
  **not met and unachievable**.
- **IPv4-only mesh scope** — conntrack `FlushIP` is IPv4-only; IPv6 falls back to a 120,000 ms
  residual bounded by TCP keepalive. `MeshIsolationResponseToPlaneResult` hardcodes
  `ipv4Scoped := true` and never reassigns, so an IPv6 target emits `ipv4_scoped: true` beside
  `conntrack_flushed: false` (P3-GOV residual 5, still open).
- **SPIFFE revocation limits** — entry eviction is immediate; an already-issued SVID remains valid
  to its TTL. There is no revocation path short of expiry. Recorded, not worked around.
- **Kernel floor Linux ≥ 5.2** — an n=1 claim from one Kind node sharing the developer host's
  kernel, not a fleet check.

**Out of scope per the proposal, and untouched:** cloud-runtime agent enforcement
(Bedrock/Vertex/Foundry) — no in-cluster primitive exists; denylist + short-TTL is the interim.
Also out of scope and untouched: the resolver/graph/attestation spine itself, and multi-tenancy
isolation (Proposal 2). No live customer infrastructure was contacted and no production workload
was enforced against.

**Key material:** no witness or operator private key material appears in any committed file, log or
test fixture. `git ls-files | rg 'PRIVATE KEY-----|BEGIN OPENSSH PRIVATE'` returns only secret-scrubber
and redactor implementations plus their test corpora — detection patterns, not keys.

---

## 8. Unresolved stopAndReport conditions open at sign-off

Both are hard blockers under this card's own terms and neither is this card's to decide.

1. **P3-GOV's precondition on P4-GOV is unmet** — mesh and admission remain unwired (B1); the
   recommended card `P3-3` was never created. P4-GOV explicitly refused to certify reversible
   stun/unstun until it closed. It has not closed.
2. **An enforcement result whose attested record cannot represent the planes it claims** (B2). The
   card names "any enforcement of a production workload without an attested record of the deciding
   evidence" as a stop condition. The record exists but is not faithful to the multi-plane decision
   it purports to describe.

Additionally, **the webhook blocks its own restart once wired** (P3-GOV residual 8): `failurePolicy: Fail`
plus a `namespaceSelector` covering the guard's own `fe-signalloom` namespace, no `objectSelector`,
`replicas: 1`, no PDB. Inert only while B1 holds. **This must be fixed in the same change that wires
the kustomization**, or the first guard eviction denies its own replacement pod.

---

## 9. What must happen before SLER can be certified

1. Create and land the missing **`P3-3`**: add mesh and admission to the `FleetClient` interface so
   `CascadeOrchestrator.Stun` dispatches all five planes, and wire `node-capability-guard/base/`
   into the `fe-signalloom` kustomization — scoping the webhook off its own namespace in the same
   change.
2. Populate `CascadeResult.Planes` from the cascade's per-plane results so the attested record
   carries five planes rather than a synthesised `freeze` (B2). Delete the
   `len(planeEvidences) == 0` fallback once it does — a fallback that fabricates a plane is worse
   than an empty field.
3. Convert `scripts/run-redteam-suite.sh` from a heredoc into a runner that executes its scenarios,
   or rename the artefact and every claim derived from it to state plainly that four planes are
   unexercised. Either is acceptable; publishing the present output as a zero-escape proof is not.
4. Reconcile P5-2's `denial_provenance` to `self-reported` for mesh, bao, spire and admission, and
   have `ContainAllPlanes` stamp each `PlaneResult.LatencyMs` from its own `time.Since` as the
   freeze branch already does.
5. Add `requireBearer` to the two quarantine read endpoints (B5) — two lines.
6. Author the five missing errata blocks from their owning cards, update the runbook's provenance
   note to the certified commit, and add the SLER rows to a tracking artefact.

---

## 10. Provenance of this report

Every figure above was produced by a command run in this worktree on `3310bcf7`. The falsification
run in §2.2 and the probe in §B2 both mutated the tree temporarily and both restored it;
`git status --porcelain` returned zero lines before the report was written. No file outside
`docs/signalloom/` was modified by this card. No remote was pushed.
