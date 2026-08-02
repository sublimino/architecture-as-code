# Policy as versioned code in `osramp-demo` — integration and iteration

How this lands on the platform that already exists here, what it consumes from upstream, what it
contributes back, and the order the pieces have to arrive in.

Read `docs/breach-cost-talk/TALK.md` first for the mentality this obeys.

---

## 1. What we consume, and what we contribute

This is the single most important boundary in the whole design. Getting it wrong means two
divergent FAIR engines, two policy mechanisms, and a split narrative.

### Consumed from `policy-as-versioned-flux` (the reference hub)

The hub owns the **mechanism**, and it is already built or specified. We take it as given and do not
re-litigate it:

| Mechanism | Where it is settled |
| --- | --- |
| Policy distributed as semver git tags, gitsign-keyless signed | hub ADR-0001 |
| Adoption by exact pin + reviewed Renovate PR; never a live range | hub ADR-0002 |
| Kyverno CEL `ValidatingPolicy`; `Audit` = lane-keeping, `Deny` = gate | hub ADR-0003 |
| One engine across workload and cloud planes | hub ADR-0004 |
| Multi-version coexistence via Flux Operator `ResourceSet` matrix | hub ADR-0005 |
| Deterministic policy — no time conditions in a policy body | hub ADR-0006 |
| Advisory metadata carried, never consumed by the engine | hub ADR-0007 |
| Layered ground-truth compliance measurement | hub ADR-0008 |
| OSCAL attestation via C2P | hub ADR-0009 |
| Sunset as scheduled *proposal*, never scheduled *application* | hub ADR-0010 |
| FAIR risk engine shape; TCoR; graded cages; war-gamer | hub `talk-spec/build/{01,10,13,22}` |

Its ancestor, [`example-policy-org`](https://github.com/example-policy-org) (Appvia R&D, Chris
Nesbitt-Smith, 2022), proved the core: semver policy in git tags, one string serving as both
Renovate pin and Kyverno selector, multi-version coexistence on one cluster, Renovate auto-PRs, a
KiND e2e. We inherit the idea and the naming ergonomics; we do not inherit its bespoke bash
`policy-checker`, which the hub PRD explicitly deletes rather than ports.

**We do not fork the hub's six-org estate** (`-nist`, `-ico`, `-platform`, `-driftwood`,
`-tuppence`, `-ludlow`). That estate stays upstream. Copying it here would duplicate the build,
split the story, and create a second FAIR implementation to keep in sync.

### Contributed by `osramp-demo`

The hub prices workloads, humans, devices and cloud resources as posture carriers. It does not price
an **AI agent**. `osramp-demo` is the only estate that can, because it already runs two governed
agents with mechanically enforced, attested guardrails:

- the Phase-4 remediation agent — nono/Landlock sandbox, credential proxy, human approval gate,
  closed change vocabulary, no path to `main`, Witness-attested steps, explicit prohibited actions;
- Olly Sentinel — `llm-guard`, `authz`, `security-sandbox`, an `eval-harness`, and a planted
  prompt-injection corpus.

That is a richer control surface than a workload has, and every one of those controls is evidenced
by an artefact in this repository. **The agent as the sixth posture carrier, priced in pounds, is
this repo's contribution to the thesis.** It is also the contribution with the most commercial
pull, because "how do I trust AI inside my business" is the question every board is currently
asking — and this answers it with a number rather than a framework.

---

## 2. What now exists here

```
risk/
  packs/agent-policy/{2.0.0,2.1.0}/    versioned policy pack — a complete tree per semver tag
    pack.yaml                          controls, rationale, risk triples, actions, cages
    cel/*.yaml                         Kyverno CEL ValidatingPolicy bodies (incl. the conditional)
  posture/agent-*.yaml                 what is actually true about each agent, with evidence paths
  org/{acme,ludlow-health}.yaml        loss magnitude + appetite + transfer, per institution
  out/                                 generated baseline + £ report (committed, regenerable)

tools/riskctl/                         Go CLI: baseline | risk | compare. Offline, deterministic.

docs/breach-cost-talk/                 transcript, frames, contact sheets, TALK.md
docs/policy-as-versioned-code/         this document
```

The load-bearing split, which is what makes proportionality arithmetic rather than opinion:

```
pack  -> loss event FREQUENCY   (a property of the control environment)
org   -> loss MAGNITUDE         (a property of the institution)
```

Multiply one pack by two org files and the same control produces different enforcement without
anybody having a view. That is slide 04/05 of the talk, reduced to multiplication.

### Two modelling decisions worth knowing about

**Weakest link, not sum.** Several controls defend the same loss scenario — `AGT-001`, `AGT-002`,
`AGT-007` and `AGT-010` all bear on secret exfiltration. Summing their frequencies counts one
incident four times and inflates the number into fantasy. An attacker needs one way in, so a
scenario's frequency is set by its weakest remaining control. The honest consequence, which the
report shows rather than hides: **tightening a control that is not the weakest link in its scenario
buys nothing until the weakest link is fixed.**

**Tail-dominated residual is a signal, not an error.** Once controls are tight enough that more than
5% of simulated years contain no loss event, VaR₉₅ sits at zero while ALE stays positive. The first
version of the self-check asserted `VaR₉₅ ≥ ALE` and failed exactly when the estate became well
governed. It now asserts only what always holds (`TVaR ≥ VaR₉₅`, `TVaR ≥ ALE`) and *reports*
tail-domination as the risk-financing signal it is: the regime where transfer starts to beat further
control spend.

---

## 3. Integration with what is already here

### 3.1 The existing policy surface becomes an input, not a casualty

Nothing currently enforcing changes behaviour. The existing surface is absorbed as evidence:

| Existing artefact | Current action | Role after integration |
| --- | --- | --- |
| `policy/cel/require-image-digest.yaml` | `Warn` | A lane-keeping control in the *workload* pack; its residual becomes priceable |
| `policy/cel/require-trusted-registry.yaml` | `Warn` | Same |
| `policy/kyverno-verify-images.yaml` | Deny on missing cosign signature | A gate control; feeds `SCN-SUPPLY-TAMPER` |
| `policy/out/promotion-policy.signed.json` | Witness promotion gate | Evidence for `AGT-006` |
| `agent/` guardrails | Harness-enforced | The evidence base for `AGT-001..006, 011, 012` |
| `olly-replica/apps/{llm-guard,authz,security-sandbox,eval-harness}` | Runtime components | Evidence for `AGT-007..010` |

The migration is: **wrap, do not replace.** Phase 2 lifts these into a versioned `platform-policy`
pack alongside `agent-policy`, at their current enforcement actions, so the version bump is a no-op
in behaviour and a step change in measurability.

### 3.2 Make targets

`riskctl` is a static Go binary with a per-tool `go.mod`, matching `tools/demo-console`. It needs no
cluster and no network, so it slots in beside the existing check targets rather than the demo
lifecycle ones:

```make
risk-baseline:   ## Baseline an agent's compliance posture against the versioned policy pack.
risk-report:     ## Regenerate risk/out/ (baseline + £ exposure + proportionality comparison).
risk-check:      ## CI gate: artefacts validate, engine self-checks, report is reproducible.
risk-compare:    ## Same agent, same pack, two institutions — the proportionality demo.
```

`risk-check` is the one that belongs in CI, because it is fast, hermetic and it fails loudly.

### 3.3 Shift-left — failures move left

The existing `scripts/ci/` path gains a compatibility check with the same shape the hub uses for
workloads: the cluster advertises which pack versions it accepts (the `ResourceSet` array), CI reads
that array, and runs the *target version's real admission action* offline against the agent's
posture. An `Audit → Deny` flip is caught before merge, not at deploy. This is where the laggard
case above surfaces as a red CI job with a number attached rather than a deploy-time surprise.

### 3.4 Where the £ surfaces

`tools/demo-console` already serves the interactive architecture map and streams action output, and
`ui/` renders it. `riskctl … --json` is the integration seam: the console gains a risk panel showing
residual, TCoR, enforcement tier, and the "what tightening this buys" table per agent. No new
service, no new datastore — the console shells out exactly as it does for the other demos.

### 3.5 Provenance

Every artefact under `risk/` is a file in git, so it inherits the estate's existing signing story
unchanged: gitsign-keyless commits, Witness attestation of the generating step, Archivista as the
queryable record. When the war-gamer arrives (phase 4) its PRs are signed the same way, and
`actor: war-gamer[bot], from: <feed>@<version>, verdict: signed` is answerable from the same
transparency log the rest of the estate already uses.

---

## 4. How it iterates

Five phases. Each one ends with something demonstrable; none of them requires the next one to exist.

| Phase | What lands | What it proves | Depends on |
| --- | --- | --- | --- |
| **1 — Priced agent posture** *(done)* | `risk/` pack + posture + org; `tools/riskctl`; committed report | An agent's compliance posture has a cash value, and tightening a control moves it | — |
| **2 — Platform pack** | Existing `policy/` lifted into a versioned, signed `platform-policy` pack at current actions; version label on workloads; `±1` skew contract | Policy is a versioned dependency here, not a pile of loose YAML — with no behaviour change on day one | 1 |
| **3 — Live admission + graded cages** | Packs reconciled by Flux; Kyverno `ResourceSet` matrix for multi-version coexistence; `mutate`/`generate` cages so a behind-posture agent is *caged*, not denied | Consequence is a spectrum; the cage's run-cost lands in TCoR | 2 |
| **4 — War-gamer** | `governance-agent` evolved: consumes CVE / EOL / penalty feeds, re-runs `riskctl`, and on proportionality drift opens a **signed PR** proposing an action promotion | Propose, never dispose. The estate re-tunes itself on existing rails | 3 |
| **5 — Balance sheet + honesty layer** | OSCAL `risk` objects generated from the conditional-policy ledger via C2P; back-testing of the £ against real incidents; the platform priced under its own model | Residual risk as economic capital, and an apparatus that passes its own test | 4 |

Phase 1's escalation output is already the phase-4 input: the report emits

```
→ AGT-008: enforcing buys GBP 96913/yr against a tolerance band of GBP 25000 — promote audit -> deny
```

which is precisely the diff the war-gamer will open as a pull request. Phase 4 is therefore
automation of a decision the tool already makes and a human already reviews — not a new capability
that has to be trusted from scratch. That sequencing is deliberate: by the time an agent is opening
policy PRs, the humans have spent two phases reading the same recommendations by hand and know what
good looks like.

---

## 5. Honest limits

- **The triples are calibrated estimates, not measurements.** Every one carries a named anchor class
  and a provenance string so it can be argued with. They must be re-calibrated against real incident
  history before any external, board, or underwriter use. The apparatus is real; the inputs are
  illustrative.
- **The agent postures are hand-asserted.** Each cites a repository artefact, but nothing yet
  *derives* the assertion from the artefact. Phase 2 should replace hand-written `met: true` with a
  collector that reads the sandbox profile, the harness config and the eval results directly —
  otherwise the baseline rots the moment the code moves.
- **The cage multipliers are stipulated.** `constrained: 0.55`, `caged: 0.25` are engineering
  judgement, not measurement. They should be back-tested in phase 5.
- **Only two agents and two institutions.** Enough to prove proportionality; not enough to claim a
  general model.
- **No live enforcement yet.** Phase 1 changes nothing in the running demo by design.

---

## 6. CONVERGENCE REQUIRED — a parallel implementation landed on this branch

**Discovered 2026-08-02, after this design was committed.** Three commits from a concurrent effort
landed on `feat/signal-loop-and-bootstrap-refactor` while `risk/` was being built:

| Commit | What it added |
| --- | --- |
| `bb25470` | Policy posture & risk window module |
| `b1bcae5` | `policy/frameworks/{eu-ai-act,nist-800-53}/{v1.0,v2.0,v2.1}` — versioned regulatory framework packs at three strictness tiers |
| `2b30460` | `d2-signalloom/apps/policy-engine/` (incl. a second `fair/fair.go`) plus dashboard pages `AgentPosturePage`, `RiskExposurePage`, `CompliancePolicyPage` |

**There are now two FAIR engines in this repository.** That is precisely the divergence §1 argues
against for the upstream relationship, occurring internally instead. It must be resolved before
either is shown to a client, because two engines will eventually disagree and the first person to
notice will be in the audience.

### What each side has

| | `tools/riskctl` (this work) | `d2-signalloom/apps/policy-engine` |
| --- | --- | --- |
| Engine | 273 LOC; scenario-level weakest-link aggregation, graded cage tiers, per-control marginal deltas, one-way sensitivity tornado, external premium anchor, enforcement friction in TCoR, tail-dominated detection | 159 LOC; single loss×frequency pair → ALE/VaR₉₅/TVaR/carried. 10k iterations, `math/rand/v2` PCG, 10% fixed risk load |
| Data | **Real** — agent posture asserted against repo artefacts, org magnitudes with mandatory provenance | **`fakeComplianceData.ts`** |
| Regulatory frameworks | None | **EU AI Act + NIST 800-53, versioned at three strictness tiers** |
| Surface | CLI + JSON + committed report | **Dashboard pages, already wired into the Signal Loom UI** |

### Recommended convergence

They are complementary rather than competing, and each holds the piece the other lacks. The other
effort built the *consumer surface and the regulatory content*; this one built the *engine and the
evidence model*. §3.4 of this document predicted the dashboard as the integration seam before
knowing it already existed.

1. **One engine.** Promote `tools/riskctl/internal/fair` to the shared implementation and retire
   `d2-signalloom/apps/policy-engine/fair`. It is the more complete of the two on every axis that
   survived adversarial review — the weakest-link aggregation, the friction term, the sensitivity
   analysis and the premium anchor all exist because a reviewer attacked the model, and re-deriving
   them in a second engine is pure waste. Keep the other engine's `math/rand/v2` PCG seeding if
   preferred; that choice is orthogonal.
2. **Keep both content sets.** `policy/frameworks/{eu-ai-act,nist-800-53}` and
   `risk/packs/agent-policy` answer different questions — regulatory control catalogues versus
   agent-specific operational controls. Map agent controls to framework controls rather than
   merging the files.
3. **Replace `fakeComplianceData.ts` with `riskctl … --json`.** The dashboard pages are the exact
   surface this design named; pointing them at real, evidence-backed output turns three fake pages
   into a live demo, and is the cheapest high-value move available.
4. **One risk-load figure.** The two engines currently disagree (10% vs the org file's 15%/25%).
   The load belongs in the org risk posture, not in the engine.

Until this converges, treat `risk/out/baseline-report.md` as the authoritative number and the
dashboard as illustrative.

## 7. Upstream contribution path

The agent-as-posture-carrier extension is a natural upstream contribution to
`policy-as-versioned-flux`:

1. Raise an issue against the hub proposing `agent` as a posture-carrier subject alongside workload,
   human and device, citing this implementation.
2. Offer the pack schema (`scenarios` + `controls` with paired `lef_audit`/`lef_enforced` triples,
   frequency here and magnitude in the org file) as the shape for `talk-spec/build/01`'s consumers.
3. Offer the weakest-link scenario aggregation and the tail-dominated signal as corrections to the
   FAIR engine spec — the hub's stated self-check (`TVaR ≥ VaR₉₅ ≥ ALE`) fails on well-governed
   estates and should be relaxed as described in §2.

Keeping the mechanism upstream and the agent extension here is what stops the two efforts diverging.
