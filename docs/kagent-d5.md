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

## The Model Credential

The Anthropic API key is supplied by the operator, stored in OpenBao under a
path scoped by each agent's own SPIFFE ID, and projected from there into the one
Kubernetes Secret the kagent controller is contractually required to read.

```bash
# 1. put the key in .env at the MAIN checkout root (gitignored, never committed)
cp .env.example .env      # then set ANTHROPIC_API_KEY=sk-ant-...
# 2.
make demo-kagent-credentials          # seed -> sync -> verify
make demo-kagent-credentials-verify   # evidence without disclosure
```

`ANTHROPIC_API_KEY` exported in the environment takes precedence over `.env`;
the provenance is printed either way, so the source is never a guess.

**`.env` is resolved from the MAIN checkout, not from `$PWD`.** It is gitignored,
so it is never checked out into a linked worktree — and a `$PWD`-relative read
from a worktree finds nothing, reports "no key configured", and exits 0 while
the operator's key sits in the main checkout. `scripts/lib/env-file.sh` resolves
it through `git rev-parse --git-common-dir`. `SIGNALLOOM_ENV_FILE` overrides,
for CI and the GCP lanes where there may be no git repo. All four `.env` readers
in this repo (`kagent-credentials`, `olly-llm-secret`, `olly-pdi-secret`,
`security-sandbox`) now share that resolver.

**Two different behaviours, deliberately.** `make demo-kagent-credentials`
**no-ops with guidance** when no key is configured, matching
`scripts/olly-llm-secret.sh`: a missing optional credential must not break
`make up`. `make demo-kagent-invoke` **fails loudly**, because there the key is
required and quietly doing nothing is the fake-success mode being removed.

This replaces a committed Secret containing a 33-byte placeholder with which no
agent could complete a model call, and which every presence check reported as
healthy.

**No key may ever be tracked by git.** `d2-signalloom/test/no-tracked-secrets.bats`
fails the build if an Anthropic- or OpenAI-shaped key reaches the git index. It
scans `git ls-files`, not the working directory — `.env` holding a real key is
the intended state and must never trip it.

| Layer | What holds the credential |
|---|---|
| System of record | OpenBao kv-v2, `secret/data/agents/ns/<ns>/sa/<sa>/anthropic/api-key` |
| Authorisation | Per-agent policy over that prefix only; per-agent JWT role with `bound_subject` = that agent's exact SPIFFE ID, `token_ttl` 15m |
| Projection | `Secret/kagent-anthropic-key`, key `ANTHROPIC_API_KEY`, in every namespace holding a `ModelConfig` |

**Per-agent roles, not one shared role.** A single role over `secret/data/agents/*`
would let any agent's SVID read any other agent's credential — credential
mediation in the diagram, none of its isolation in practice. Verified: a token
carrying `signalloom-agent-kagent-k8s-reader` reads its own path, and is denied
both a sibling's path and enumeration of the prefix.

**The Secret must exist in the ModelConfig's own namespace.** Upstream, verbatim:
*"Must be a reference to the name of a secret in the same namespace as the
referencing ModelConfig."* Hence two namespaces, not one.

The key never enters `git`, a manifest, argv, or `set -x` output. It crosses
process boundaries only on stdin, and is staged to a `umask 077` temporary file
that is removed on exit. `verify` prints path, presence, byte count and a
truncated SHA256 — never the value.

> **Limit worth stating:** presence and length cannot distinguish a real key from
> a well-formed fake. The only proof that the credential works is a successful
> invocation — which is what `make demo-kagent-invoke` exists for.

## Invoking an Agent

```bash
make demo-kagent-invoke AGENT=kagent-k8s-reader \
     PROMPT="List every namespace in this cluster, then tell me how many there are."
```

Uses kagent's own A2A surface, nothing bespoke: the controller serves
`GET /api/a2a/{namespace}/{agent}/.well-known/agent.json` and
`POST /api/a2a/{namespace}/{agent}/` (JSON-RPC `message/send`) on port 8083 of
`svc/kagent-controller` — the same surface the `kagent` CLI and the dashboard
use. Implemented as a dependency-free client so the kagent CLI need not be
installed.

Four distinct failure modes are treated as failures, three of which arrive as
HTTP 200: a JSON-RPC `error` object; `result.status.state == "failed"`; an HTML
gateway page served with a 200; and a completed task carrying no text. Checking
only the status code, or only `.error`, reports the other three as success.

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

### Known gap: silent re-pointing between real tools

Nothing detects an agent being re-pointed from one **real** tool to another
real one. That is deliberate, and it is worth stating why so it is not "fixed"
by reintroducing what used to be here.

Eight tests once pinned each agent's exact `toolNames`. They compared the
manifest to a copy of the manifest — circular, and green whether or not a
single named tool existed. Worse, such a test cannot detect the thing it
appears to: it fails on every *legitimate* re-point until someone edits it to
match, which trains people to update the expectation without thinking. That is
ceremony, not detection.

The honest control for "should this agent have that tool" is code review. The
tests hold the properties a test can actually hold: the tool exists on the
server, the MCPServer resolves, and the shape is usable.

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

**Presence is not callability, and this guard only checks presence.** A tool can
appear in `tools/list` and fail every time it is called. On this cluster
`kubescape_*`, `prometheus_*` and `istio_*` are all advertised and all
non-functional — no Kubescape operator (the `vulnerabilitymanifests` CRD is
absent), no Prometheus (hardcoded `localhost:9090`), no Istio (`istioctl` exits
64), and `prometheus_promql_tool` additionally wants an `OPENAI_API_KEY`. An
earlier re-pointing plan aimed four agents at exactly those tools; it would have
traded "tool does not exist" for "tool exists and always errors", **and this
guard would have passed it**. The agents were pointed at the verified-working
`k8s_*` set instead. Closing the gap properly means a `tools/call` probe, which
needs a per-tool judgement about which calls are safe to make against a live
cluster — deliberately not attempted here.

**Deferred agents.** `kagent-chaos-prober` and `kagent-commit-summariser` are
deferred by ruling: no `chaos_*` tool and no `github_*` tool exist on the server.
They are named in `DEFERRED_AGENTS` in the test, with a recorded reason each.

A hardcoded allowlist normally rots into a permanent hole, so it carries an
anti-rot clause: **a deferral asserts that the tools do not exist, and fails the
moment they do.** If a `chaos_*` tool ever appears, the deferral is stale and the
suite fails until the agent is removed from the list and re-enforced. A deferral
naming an agent that no longer exists fails too, as does one with no reason. The
list can only shrink by itself.

An earlier draft put this in an Agent CR annotation, so the decision would live
in the manifest rather than the test. That was the better shape, but neither
branch owning those manifests was adding annotations, so it would have meant the
guard staying red on a decision that had in fact been made. Reversed
deliberately; the anti-rot clause is what makes the static form safe.

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

   "A stub should be more brittle" was the first attempt at a rule here, and it
   is the wrong axis — it also fails to describe the second instance at all.
   Two rules, because these are two mechanisms:

   1. **A stub's failure value must not be something the real thing could
      legitimately return.** `""`, `0`, `null`, `[]` are almost always legal
      answers, so a stub that returns one on failure collides with a real state
      the caller is entitled to observe. Fail loudly instead.
   2. **A stub must reject queries it does not understand, not fall through.**
      A `*)` arm returning success is where a *well-formed answer to the wrong
      question* gets manufactured. The `-o jsonpath` case was a dispatch error,
      not a fallback-value one; no amount of brittleness would have caught it.

   Applying rule 2 to that stub immediately found two more defects in the same
   family. `create --dry-run=client -o yaml` was unhandled, so it emitted
   nothing and the pipeline into `replace --force -f -` carried an **empty
   manifest** while every test passed — they asserted on argv and never on the
   pipe having content. Fixing that exposed a fourth: the stub never drained
   stdin for `-f -`, harmless while it emitted nothing, but once it emitted a
   real manifest the producer died of **SIGPIPE**, surfacing under `pipefail` as
   exit **141** with no message. That is now asserted specifically, because a
   bare non-zero check cannot tell SIGPIPE from a real failure.

   **And the fix can be worse than the bug.** Draining stdin unconditionally
   hung an entire bats file — `cat` blocks on a terminal or any inherited
   descriptor that never closes. A silent failure had been traded for a loud
   one. Drain only genuine pipes (`[ -p /dev/stdin ]`).

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
