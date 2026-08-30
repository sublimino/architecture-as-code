# docs/kagent-d5.md — Kagent Cloud-Native AI Agents (Demo 5)

## Overview

Demonstrates the CNCF sandbox AI agent framework **Kagent** (`v0.9.9`) running on
Signal Loom, with agent identity issued through SPIRE and credentials brokered by
OpenBao.

Replaces ~120-line hand-crafted Knative Serving manifests with declarative ~30-line
Custom Resources (`Agent`, `ModelConfig`, `MCPServer` in `kagent.dev/v1alpha2`).

## Status of this demo — read this before quoting anything below

This document previously described a working Kagent control plane. It was not one.
Up to commit `f879ec4c` the "control plane" consisted of placeholders:

| Component | What was actually deployed | Consequence |
|---|---|---|
| `kagent-controller` | `python:3.12-alpine` running `while True: time.sleep(10)`, readiness probe `sh -c "echo ready"` | Nothing reconciled. All 8 `Agent` CRs sat at `status: null` indefinitely. |
| `kagent-tool-server` | `python:3.12-alpine` whose `do_POST` wrote **one hardcoded literal for every request** | Tool calls were not dispatched. A call naming `k8s_get_resources` and one naming `totally_made_up_xyz` returned byte-identical JSON. |
| `kagent-ui` | `nginx:1.27-alpine` serving a static hand-written `index.html` | No product. Deployment readiness was satisfied by nginx starting. |
| `kagent-anthropic-key` | the literal string `mock-anthropic-key-for-local-demo` | No agent could complete a single model call. |

All 36 Kagent assertions passed against that stack. That is the defect
`test/kagent-anti-stub.bats` exists to prevent recurring; its file header explains
the reasoning behind each assertion.

**Current state.** The real charts have since landed: `kagent 0.9.9` with
`cr.kagent.dev/kagent-dev/kagent/controller:0.9.9`,
`ghcr.io/kagent-dev/kagent/tools:0.2.1` and `…/ui:0.9.9`. **Twelve of the
thirteen anti-stub assertions now pass with no change to the tests.** The tool
server discriminates its input, the controller writes real status conditions,
and it materialises resources it owns — the three properties the placeholder
stack could not produce.

This section is a snapshot and dates quickly; `make demo-kagent-test` is the
current answer. At the time of writing:

- **Half the swarm reconciles.** Four agents report
  `Accepted=True / Reconciled` and 8 Agent-owned resources exist. The other four
  fail to compile because the `RemoteMCPServer` CRs they bind do not exist yet:
  `github-tool`, `incident-triage-tool`, `network-probe-tool`, `vuln-db-tool`.
  Only `kagent-tool-server` has been created so far. Note the CR kind — the
  controller resolves `RemoteMCPServer.kagent.dev`, not the `MCPServer` CRs the
  original manifests declared, which is why this failed for all eight before.
- **A placeholder credential survives in a tracked manifest** —
  `controller.yaml:12`. See "What the agents cannot yet do" below.

Claims about *declarative structure* — the Agent CRs, their tool bindings,
SPIFFE naming, the OpenBao path mapping — are verified on disk and in the
cluster today.

## Architecture & lifecycle

```
Foundation (Kind, Zot, Flux)
      │
      ├── inf-bao (SPIRE Server & OpenBao JWT Auth)
      ├── kagent namespace (Controller, Postgres state store, MCP tool server, UI)
      └── fe-signalloom-agents namespace (8 declarative Agent CRs with SPIFFE identity)
```

### Lifecycle targets

| Command | Purpose |
|---------|---------|
| `make swarm-kagent-up` | Deploy Kagent CRDs, controller, PostgreSQL, tool server, and UI |
| `make swarm-kagent-down` | Remove the Kagent control plane and CRDs |
| `make demo-kagent-up` | Deploy all 8 Kagent declarative agents to `fe-signalloom-agents` |
| `make demo-kagent-down` | Remove the Kagent declarative agents |
| `make demo-kagent-test-config` | Statically render the CRDs and agent overlays, then run the contract suite — no cluster required |
| `make demo-kagent-test` | Run every Kagent BATS suite against a live cluster |
| `make demo-kagent-demo` | Run the interactive CLI walkthrough |

`swarm-kagent-up` and `swarm-kagent-down` are each declared **twice** in the
Makefile (around lines 861 and 2490) with identical recipes. GNU make takes the
last definition and warns; behaviour is unchanged, but the duplication should go.

## The eight agents

Previous revisions of this document described five. Eight are defined on disk
(`d2-signalloom/infra/agent-swarm/kagent-*/`), deployed by
`scripts/kagent-agents.sh`, and asserted by the test suites.

Every agent uses the Go ADK runtime and the `anthropic-claude` `ModelConfig`.

**Tool bindings are deliberately not enumerated here.** They are in active flux —
five of the eight were re-pointed at real tools while this document was being
written — and a list of tool names in prose is a copy of the manifest that goes
stale silently. `kubectl get agents -n fe-signalloom-agents -o yaml` is the
answer, and `test/kagent-agents.bats` enforces that every name in it exists on
the live server.

| Agent | Role | Tools status |
|---|---|---|
| `kagent-k8s-reader` | Cluster state queries. The only agent with a `ClusterRole` (`kagent-k8s-reader-role`: get/list/watch on pods, services, deployments, namespaces, nodes, events). | real |
| `kagent-security-analyst` | Posture assessment. Publishes an A2A Agent Card. | real |
| `kagent-network-auditor` | NetworkPolicy, SPIFFE boundary and Envoy route auditing. | real |
| `kagent-incident-responder` | SRE triage and restart correlation. Publishes an A2A Agent Card. | real |
| `kagent-compliance-checker` | Policy and CIS benchmark checks. | real |
| `kagent-finops-optimizer` | Cost and waste analysis. | real |
| `kagent-commit-summariser` | Git commit and PR summarisation via `github-tool`. | **roadmap — no `github_*` tool exists on the server** |
| `kagent-chaos-prober` | Fault injection and recovery probing. | **roadmap — no chaos tool exists on the server** |

The last two are why `test/kagent-agents.bats` fails today. See "Declared tools
must exist" below.

### What the agents cannot yet do, and why

- **Agent execution requires a model API key the operator must supply**, and the
  reference to it is currently lost on apply. Three separate facts, all live:
  1. The `kagent-anthropic-key` Secret now holds a real `ANTHROPIC_API_KEY`.
     It briefly held *two* keys — the real one plus the original mock `api-key`
     — because `kubectl apply` merges, so a write that set only the new key left
     the placeholder underneath it. Resolved with `replace --force`.
  2. **`spec.anthropic.apiKeySecret` was silently pruned** — now fixed, and worth
     keeping on record because the failure mode leaves no trace. The v1alpha2 CRD
     defines `apiKeySecret` and `apiKeySecretKey` at the **top level of `spec`**;
     `spec.anthropic` admits only `baseUrl`/`maxTokens`/`temperature`/`topK`/
     `topP`. `kubectl apply` succeeded, nothing warned, and the field was
     dropped — `spec.anthropic` read back as `{}`. A pruned field fails at run
     time, not at apply time, so nothing between the manifest and the first
     model call would have told you. `test/kagent-credentials.bats` accepts the
     reference at either location and fails if it resolves at neither.
  3. `d2-signalloom/infra/kagent/base/controller.yaml:12` still carries the
     literal `mock-anthropic-key-for-local-demo`. The chart now supplies the
     Secret, so that manifest's Secret block is **dead** — the placeholder ships
     but nothing consumes it. `test/kagent-anti-stub.bats` fails on it anyway,
     because a mock credential in a tracked manifest is a hazard whether or not
     today's topology happens to read it.
- **Seven of the eight agent ServiceAccounts hold no RBAC at all.** Only
  `kagent-k8s-reader` is bound to a Role. The negative RBAC assertions in
  `test/kagent-adversarial.bats` are therefore true but weak for those seven: they
  confirm an absence of permissions rather than a drawn boundary. That file states
  the limit in its header rather than papering over it.
- **`kagent-tool-server` is referenced by five Agent CRs but is not an `MCPServer`
  CR** in `fe-signalloom-agents` — it is the control-plane MCP endpoint in the
  `kagent` namespace. `test/kagent-agents.bats` excludes it by name when resolving
  MCPServer references.

## OpenBao integration

- **Current seam.** Agent workloads map secrets through OpenBao SPIFFE-scoped paths
  (`secret/data/agents/<spiffe-id>/<key>`), declared in
  `d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml`. That ConfigMap has
  one data key per agent and is asserted key-by-key by the contract suite.
- **OpenBao Agent compatibility.** The pod templates and `ModelConfig` definitions
  are shaped so an `openbao-agent` sidecar or injector can render secrets to
  `/vault/secrets/` on a tmpfs `emptyDir` without modifying the `Agent` CRs or the
  MCP tool definitions. This is a design property of the manifests; no injector is
  deployed today.

## SPIFFE identity derivation

The dashboard builds a SPIFFE ID as `spiffe://<trust-domain>/ns/<ns>/sa/<sa>`, where
`<sa>` is **derived from the Agent CR's name** — an `Agent.kagent.dev` CR carries no
ServiceAccount field, so the value is inferred rather than observed. If an agent's
ServiceAccount ever stops being named after the agent, the governance UI renders an
identity SPIRE never issued.

Two independent assertions in `d2-signalloom/test/kagent-contract.bats` hold that
invariant on disk (Agent name == ServiceAccount name; the agent-card `spiffeId`
matches `spiffe://<domain>/ns/<ns>/sa/<that name>` in full), and
`test/kagent-credentials.bats` holds it against the cluster.

### Trust domain: `signalloom.demo`

The canonical SPIFFE trust domain is **`signalloom.demo`**, declared once in
`d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml` — the
manifest that renders the `spire-server-config` ConfigMap. The tests derive the
expected domain from that file rather than hardcoding it, so changing SPIRE's
domain automatically requires the agent cards to follow.

All 8 `agent-card.json` files previously advertised
`spiffe://osramp.acme.local/...`, which was never an identity — `osramp.acme.local`
is the Gateway DNS name (`dashboard.osramp.acme.local`, `*.osramp.acme.local`) and
had been pasted into the SPIFFE authority field. Three independent checks agreed:

- OpenBao's JWT roles bind `bound_subject` to `spiffe://signalloom.demo/...`
  (14 occurrences, none for the other domain). A card advertising
  `osramp.acme.local` therefore named a credential OpenBao would **reject** — the
  cards did not merely disagree with SPIRE, they described something that could
  not work.
- Live SPIRE registration entries are all `spiffe://signalloom.demo/...`,
  including entries in `fe-signalloom-agents` itself.
- Across tracked files, `spiffe://signalloom.demo` appears 132 times against 8 for
  `spiffe://osramp.acme.local` — and those 8 were exactly these cards.

The `/ns/fe-signalloom-agents/sa/<agent>` path was verified correct on all 8
before the change, so the authority was the only wrong segment. Fixed.

Unrelated and still outstanding: `signalloom.local` appears as `trustDomain:` in
`d2-signalloom/agents/*.yaml` and `apps/fleet-manager/base/fleet-config.yaml`.
That is a third domain, outside the kagent surface and not covered by these tests.

## Tests & verification

Run everything with `make demo-kagent-test` (wraps `scripts/kagent-test.sh`).

| Suite | Asserts | Does **not** assert |
|---|---|---|
| `d2-signalloom/test/kagent-contract.bats` | Declarative size reduction, label and runtime/ModelConfig/tool contract for all 8 agents, OpenBao path-map keys, SPIFFE name derivation, agent-card schema | Anything about a running cluster |
| `test/kagent-install.bats` | CRDs registered and serving `v1alpha2` with a status subresource; namespace label; controller/postgres/tool-server/UI scheduled with Services carrying ready endpoints; postgres NetworkPolicy selects real pods | That any component *does* anything |
| `test/kagent-agents.bats` | Exactly 8 Agent CRs; every agent's declarative shape (runtime, a server, at least one tool, a ModelConfig); every referenced MCPServer exists; **every requested tool name exists on the live MCP server** | Whether a tool call succeeds |
| `test/kagent-credentials.bats` | ServiceAccounts and their labels; Agent↔ServiceAccount name correspondence; ModelConfig names a model and an existing Secret; GitHub secret wired to the summariser | Whether credentials are usable |
| `test/kagent-adversarial.bats` | Negative RBAC probes, each gated on the subject existing, plus a **positive control** proving RBAC is evaluated; controller can write `agents/status` but cannot escalate; NetworkPolicy declares Ingress | Boundaries for the seven agents with no RBAC |
| **`test/kagent-anti-stub.bats`** | **That the control plane is real**: no generic base images, no inline-interpreter containers, no `echo` readiness probes, kagent-published image provenance, tool-server input discrimination, `tools/list` naming, UI is an application, Agent CRs reconciled to non-null status with typed conditions, controller-owned resources, no placeholder model key | — |
| `test/kagent-infra.bats` | Lifecycle command behaviour of `scripts/kagent-infra.sh` via a stubbed `kubectl` | — |

Additionally, `test/acceptance/kagent-agents.spec.ts` drives the dashboard `/agents`
page with Playwright and expects all eight agent names to render. It opts out of
demo mode (`login(page, { demoMode: false })`) because the agents exist only as
Agent CRs discovered through `fake-integration-proxy`.

### Declared tools must exist

`Ready` on an Agent CR means **compiled and running**. It does not mean the agent
can do anything. `kagent-chaos-prober` reports `Accepted=True` / `Ready=True`
while every tool it binds is unknown to the tool server — the controller does not
validate `toolNames` against the server, so a fabricated tool name is not a
startup error, it is an agent that silently cannot act.

`test/kagent-agents.bats` closes that gap by asking the live server. Measured
when the guard was written: **124 tools available, 3 of the 21 requested
(agent, tool) pairs present.** Asserted per pair, not per distinct name —
`k8s_get_resources` is requested by two agents, so a name-wise count reads
2 of 20 and hides that one satisfied name is doing double duty.

Talking to the server has three traps, all documented in `test/lib/mcp.bash`
because each returns something that looks like an answer:

1. A bare `tools/list` POST returns **HTTP 400**. The handshake is mandatory —
   `initialize`, keep the `mcp-session-id` response header, send
   `notifications/initialized`, then call `tools/list`.
2. The reply may be **SSE-framed (`data: {...}`) or plain JSON**, varying by
   call. On `kagent-tools:0.2.1`, `tools/list` answers in plain JSON; a parser
   assuming SSE reads zero tools and reports "the server offers none".
3. An empty tool list makes every presence check fail, so an unreachable or
   mis-parsed server reads as *"all 21 tools are missing"* — a true-looking
   verdict for entirely the wrong reason. The helper therefore **errors on an
   empty list** instead of returning it.

**Roadmap exemptions.** An agent may declare tools that do not exist yet, but
only out loud: annotate the Agent CR with `signalloom.ai/tools-roadmap=<reason>`
and the guard skips it while printing it on every run. A bare `true`/`yes`/`1`
is rejected — the exemption has to read as a decision, not an oversight. If
*every* agent were exempt the guard fails rather than passing, because a check
that skips everything is not a check.

### Known-red suites

- **`test/kagent-anti-stub.bats` — 13/13 failing at `f879ec4c` by design.** Every
  assertion targets a property the placeholder stack lacks. These flip green when
  the real charts and credentials land; a passing run against a stub would mean the
  suite had broken.
- **`test/kagent-infra.bats` — 4/4 failing.** It tests an interface
  `scripts/kagent-infra.sh` does not implement: a `KAGENT_INFRA_MANIFEST_DIR`
  override, `rollout status deployment/<name> --timeout=15s`, exit code 2 on an
  unknown subcommand, and a `Usage: kagent-infra.sh` string. The script uses a
  fixed manifest path, `wait_rollout`, exit 1, and `Usage: $0`. The suite was
  omitted from `scripts/kagent-test.sh`, so `make demo-kagent-test` reported green
  while it was red. It is now included: either the script grows that interface or
  the suite is rewritten against the one it has — but the mismatch is visible.

### Seven ways these suites have produced a confident wrong answer

Each of these was hit for real while building the kagent suites, the credential
wiring, and the SPIRE durability work. What they share is not that they fail —
it is that they **return a plausible verdict instead of an error**. A test that
fails tells you about itself; one that answers confidently and wrongly does not.
Most produce a false green; #1 produces a false *accusation*, which is the same
defect seen from the other side.

The one question that resolves all seven:

> **Before believing a green, ask what would have had to happen for it to be
> red, and confirm that thing was reachable.**

Worked through, it answers each of them without needing to decide what kind of
failure any of them is:

- **#1** — the test would have to be selected by the filter. It never was.
- **#4** — the mutated file would have to be reached by the loop. The suite
  failed on an earlier one first.
- **#5** — `bash -n` would have to exit non-zero. For that one fault it never
  can, at all.
- **#6** — Flux would have to reach its apply stage. It was failing before it.

An earlier draft of this section sorted these into categories — "the check never
ran" versus "the check ran but its verdict was lossy" versus "the check ran but
its stimulus never occurred". Every one of those distinctions turned out to be
arguable, and two were argued, correctly, after being written down. The
categories were doing no work that the question above does not do better, so
they are gone. If you find yourself debating which bucket a new instance belongs
in, that is the signal to ask the question instead.

1. **A test-filter that matches nothing exits 0.** A mutation harness that breaks
   a guard and runs `bats -f '<name>'` to watch it fail reads the exit 0 as "the
   test stayed green under the mutation" — i.e. *this test guards nothing* — and
   files a false accusation against a guard that works perfectly. The real cause
   was a filter reading "…retired mock **placeholder**" against a test named
   "…retired mock **literal**".

   The filter matching is a **precondition, not a result**: require
   `bats "$suite" -f "$name" --count` to equal exactly 1 before applying the
   mutation, and report anything else as INCONCLUSIVE — never as SURVIVED.
   Identical hazard in `pytest -k`, `go test -run`, `jest -t`.

2. **A stub that returns a plausible wrong value rather than failing.** Two
   instances of one family, both of which made tests fail for reasons unrelated
   to the code under test:

   - *Quoting mangled through a generated heredoc.* A kubectl stub emitted into a
     `<<'STUB'` heredoc by a Python script lost its escaping, so every query
     returned empty — and empty is indistinguishable from "the field is absent".
     The stub is now a real fixture file
     (`d2-signalloom/test/fixtures/kubectl-stub.sh`), not generated text.
   - *`-o jsonpath` caught by an `-o json` glob.* A `case` arm matching
     `*"-o json"*` sits before the jsonpath arm and matches
     `-o jsonpath={.data.X}` too, because `-o json` is a prefix of `-o jsonpath`.
     Every scalar query returned the whole Secret object, which decoded to
     nothing and read as "key present but empty". Order the jsonpath arm first
     and require the trailing space (`*"-o json "*`).

   The general rule: a stub must be **more** brittle than the real thing, not
   less. An unrecognised invocation should abort loudly; returning empty makes
   the stub agree with every hypothesis.

3. **A positional index over a map silently changes what is tested.** Reading a
   Secret with `jq '.data | to_entries[0].value'` tests whichever key sorts
   first. When `kagent-anthropic-key` grew a second key, `ANTHROPIC_API_KEY`
   (real) sorted ahead of `api-key` (still the mock, and the one the ModelConfig
   actually names) — so the assertion passed while the credential in use was a
   placeholder. **Assert over every key; never a positional index.** The general
   form: if a collection can grow, an index into it is a silent rebinding.
   Chasing this one found a second defect underneath it: `kubectl apply` MERGES,
   so a stale `api-key` survived beneath a write that only set the new key. The
   sync now uses `replace --force`, and its verify step compares the key name
   the ModelConfig *requests* against the key name sync *provides*.

4. **Mutating into an already-red suite proves nothing.** Falsifying the SPIFFE
   trust-domain assertion by pointing one card at `spiffe://wrong.example`
   produced a red — but the failure named a *different* card, because the suite
   was already failing on the first one alphabetically and never reached the
   mutation. A falsification must start from green: fix everything, confirm the
   suite passes, then break exactly one thing and check the failure names the
   thing you broke.

5. **`bash -n` misses exactly one syntax fault: the unterminated here-document.**
   Keep using it — this is a single carve-out, not a reason to distrust the tool.
   `bash -n` exits **2** on every other malformed construct. The exception is
   semantic: bash *accepts* a here-doc delimited by EOF, so to bash it is not an
   error at all but a recoverable oddity, reported as a warning at exit 0.

   Measured across nine constructs:

   | script | rc | stderr |
   |---|---|---|
   | valid | 0 | *(none)* |
   | **unterminated heredoc** | **0** | `warning: here-document at line 1 delimited by end-of-file (wanted 'ROLE')` |
   | unclosed `if` / `while` / `case` / function | 2 | `syntax error: unexpected end of file` |
   | unclosed quote | 2 | ``unexpected EOF while looking for matching `"'`` |
   | unclosed paren / arithmetic | 2 | ``unexpected EOF while looking for matching `)'`` |

   So `run bash -n "$f"; [ "$status" -eq 0 ]` passes on a script whose heredoc
   silently swallows everything after it. **Assert both channels: exit 0 AND
   `[ -z "$output" ]`** — bats folds stderr into `$output`.

   Note the discriminator is the *exit code paired with stderr being non-empty*,
   never the message text: the unclosed-quote case says "unexpected EOF while
   looking for matching" too, and does so at rc=2. Exit-0-with-stderr was unique
   to the heredoc across all nine.

   Worst where a script lives in a ConfigMap block scalar, because the
   terminator's real column is decided by YAML indent-stripping: indent it two
   spaces and it still *looks* aligned in the editor, but after extraction it is
   no longer at column 0. Corollary: extract the script the way the runtime does
   and check the extracted bytes, never the manifest.

6. **A green result from a stage that was never reached.** A conclusion that Flux
   would not revert a hand-applied Deployment field rested on an SSA dry-run plus
   two live reconciles that left the field untouched. Both reconciles were
   failing *before the apply stage* — nothing was applied, so nothing could be
   reverted. A code path that never ran reads exactly like a code path that
   passed. When the blocking error was cleared, Flux reverted the field within
   seconds and destroyed a SPIRE CA.

   **Before trusting a negative result, confirm the code path you are testing
   actually executed.** For Flux: compare `status.lastAppliedRevision` against
   `lastAttemptedRevision`, and treat a sub-second reconcile as a signal that it
   failed before doing any work.

7. **A guard matched the comment explaining the absence.** A grep for a forbidden
   token also matches the line documenting why the token is gone, so the guard
   reports the defect it was just told had been fixed — and the obvious way to
   make it pass is to delete the explanation. `test/kagent-anti-stub.bats` and
   `bats-registry-coverage.bats` both strip whole-line comments before matching.

   Only *whole-line* comments. The fourth case below is what makes that correct
   rather than merely convenient — and it is the case a naive `sed 's/#.*//'`
   gets wrong, laundering a live assignment because someone appended a `# TODO`:

   | manifest state | verdict |
   |---|---|
   | literal present as a real assignment | red |
   | literal replaced by an explanatory comment | **green** |
   | that comment *plus* a restored assignment | red |
   | live assignment with trailing `# TODO replace` | red |

   Whole-line stripping also removes `#` lines *inside* a YAML block scalar,
   where they are shell comments in data rather than YAML comments. For a
   forbidden-literal scan that is the wanted behaviour either way; it would only
   matter to a guard needing to assert something *about* an embedded script's
   comments.

### The proof artefact

`scripts/kagent-harness-exec.sh` writes `.kagent-preflight-proof.json`, which is
git-tracked. Because it is committed, a stale copy answers for runs it never
observed — the committed version recorded commit `ef483f3e`, four pod names that no
longer existed, five Agent CRs out of eight, and `test_assertions_passed: 23`, a
figure that was a hardcoded literal in the harness and never matched any run.

`test/kagent-demo-harness.bats` now asserts freshness: the artefact must still
describe the current tree, its `agent_crs` must equal the live set exactly, and
its pass count must be consistent with what the runner measured. Regenerate with
`scripts/kagent-harness-exec.sh` after any run whose evidence you intend to quote.

**Expect the artefact to record one failure more than a fresh run reports**, and
do not chase it. The freshness test is evaluated *during* the run, at which point
the artefact on disk is still the previous one — so if any kagent file changed
since, that test is legitimately red and gets counted. Committing the new
artefact then makes it green. The artefact therefore cannot record its own
freshness assertion as passing; it is a self-reference, not a regression. If the
counts differ by more than that one test, something real has changed.
