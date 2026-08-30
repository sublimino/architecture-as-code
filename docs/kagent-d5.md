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
"Tools" below are the `toolNames` each `Agent` CR binds through an `MCPServer`.

1. **`kagent-k8s-reader`** — MCPServer `kagent-tool-server`; tools
   `k8s_get_resources`, `k8s_get_available_api_resources`. The only agent with a
   `ClusterRole` (`kagent-k8s-reader-role`: get/list/watch on pods, services,
   deployments, namespaces, nodes, events).
2. **`kagent-commit-summariser`** — MCPServer `github-tool`; tools
   `github_list_commits`, `github_get_commit`. Reads a GitHub token from the
   `kagent-github-key` Secret.
3. **`kagent-security-analyst`** — three MCPServers (`kagent-tool-server`,
   `vuln-db-tool`, `policy-eval-tool`); tools `k8s_get_resources`, `lookup_cve`,
   `query_advisories`, `evaluate_rbac_policy`, `evaluate_netpol`. Publishes an A2A
   Agent Card (`agent-card.kagent-security-analyst.v1.json`).
4. **`kagent-network-auditor`** — MCPServer `network-probe-tool`; tools
   `audit_netpol_rules`, `probe_spiffe_boundaries`, `inspect_envoy_routes`.
5. **`kagent-incident-responder`** — MCPServer `incident-triage-tool`; tools
   `triage_alert_events`, `correlate_restarts`, `propose_remediation`. Publishes an
   A2A Agent Card (`agent-card.kagent-incident-responder.v1.json`).
6. **`kagent-compliance-checker`** — MCPServer `kagent-tool-server`; tools
   `compliance_check_policies`, `compliance_audit_cis`.
7. **`kagent-finops-optimizer`** — MCPServer `kagent-tool-server`; tools
   `finops_query_metrics`, `finops_identify_waste`.
8. **`kagent-chaos-prober`** — MCPServer `kagent-tool-server`; tools
   `chaos_probe_recovery`, `chaos_simulate_latency`.

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
| `test/kagent-agents.bats` | Exactly 8 Agent CRs; each agent's MCPServer bindings and callable tool names; every referenced MCPServer exists | Reconciliation, execution |
| `test/kagent-credentials.bats` | ServiceAccounts and their labels; Agent↔ServiceAccount name correspondence; ModelConfig names a model and an existing Secret; GitHub secret wired to the summariser | Whether credentials are usable |
| `test/kagent-adversarial.bats` | Negative RBAC probes, each gated on the subject existing, plus a **positive control** proving RBAC is evaluated; controller can write `agents/status` but cannot escalate; NetworkPolicy declares Ingress | Boundaries for the seven agents with no RBAC |
| **`test/kagent-anti-stub.bats`** | **That the control plane is real**: no generic base images, no inline-interpreter containers, no `echo` readiness probes, kagent-published image provenance, tool-server input discrimination, `tools/list` naming, UI is an application, Agent CRs reconciled to non-null status with typed conditions, controller-owned resources, no placeholder model key | — |
| `test/kagent-infra.bats` | Lifecycle command behaviour of `scripts/kagent-infra.sh` via a stubbed `kubectl` | — |

Additionally, `test/acceptance/kagent-agents.spec.ts` drives the dashboard `/agents`
page with Playwright and expects all eight agent names to render. It opts out of
demo mode (`login(page, { demoMode: false })`) because the agents exist only as
Agent CRs discovered through `fake-integration-proxy`.

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

Within that, one sub-shape recurs often enough to name on its own:

> **A check that did not really run is indistinguishable from a check that
> passed.**

That is #1 at the harness level (the filter selected nothing), #5 at the tool
level (`bash -n` had a complaint but no exit code for it), #6 at the controller
level (the apply stage was never reached), and #4 is its close cousin — the
check ran, but against an already-failing baseline, so its result was
pre-determined.

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

5. **`bash -n` exits 0 on an unterminated here-document.** It reports it as a
   *warning on stderr* and returns success:

   ```
   script.sh: line 52: warning: here-document at line 39 delimited by
     end-of-file (wanted `ROLE')
   $ echo $?
   0
   ```

   So `run bash -n "$f"; [ "$status" -eq 0 ]` passes on a script whose heredoc
   silently swallows everything after it. **Assert both channels: exit 0 AND
   `[ -z "$output" ]`** — bats folds stderr into `$output`. (Reproduced
   independently while writing this entry; the behaviour is as described.)

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

   Only *whole-line* comments: a trailing `# …` after a live assignment must not
   rescue the line. Falsified all four ways — literal present (red), literal
   replaced by a comment (green), comment plus a restored assignment (red), and
   a live assignment with a trailing comment (red).

### The proof artefact

`scripts/kagent-harness-exec.sh` writes `.kagent-preflight-proof.json`, which is
git-tracked. Because it is committed, a stale copy answers for runs it never
observed — the committed version recorded commit `ef483f3e`, four pod names that no
longer existed, five Agent CRs out of eight, and `test_assertions_passed: 23`, a
figure that was a hardcoded literal in the harness and never matched any run.

`test/kagent-demo-harness.bats` now asserts freshness: the artefact must name the
current `HEAD`, its `agent_crs` must equal the live set exactly, and its pass count
must match what the runner measured. Regenerate with
`scripts/kagent-harness-exec.sh` after any run whose evidence you intend to quote.
