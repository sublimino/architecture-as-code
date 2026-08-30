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

**Current state.** The real upstream Helm charts and real credential wiring are
being landed separately. Until they merge, treat every claim below about *runtime
behaviour* as pending. Claims about *declarative structure* — the Agent CRs, their
tool bindings, SPIFFE naming, the OpenBao path mapping — are verified on disk and
in the cluster today.

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

- **Agent execution requires a model API key the operator must supply.** The
  `anthropic-claude` `ModelConfig` reads `kagent-anthropic-key`. Until that Secret
  holds a real Anthropic key, agents can be created and reconciled but cannot
  complete a model call. `test/kagent-anti-stub.bats` fails while the placeholder
  is in place, deliberately.
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
invariant on disk (Agent name == ServiceAccount name; agent-card `spiffeId` ends in
`/sa/<that name>`), and `test/kagent-credentials.bats` holds it against the cluster.

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
