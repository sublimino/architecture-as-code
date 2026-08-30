# docs/kagent-d5.md — Kagent Cloud-Native AI Agents (Demo 5)

## Overview

Demonstrates CNCF sandbox AI agent framework **Kagent** (`v0.9.9`) running on Signal Loom with full SPIFFE identity issuance and OpenBao ephemeral credential management.

Replaces ~120-line hand-crafted Knative Serving manifests with declarative ~30-line Custom Resources (`Agent`, `ModelConfig`, `MCPServer` in `kagent.dev/v1alpha2`).

## Architecture & Lifecyle

```
Foundation (Kind, Zot, Flux)
      │
      ├── inf-bao (SPIRE Server & OpenBao JWT Auth)
      ├── kagent namespace (Controller, Postgres 18 state store, MCP Tool Server, UI)
      └── fe-signalloom-agents namespace (5 Declarative Agent CRs with SPIFFE identity)
```

### Lifecycle Targets

| Command | Purpose |
|---------|---------|
| `make swarm-kagent-up` | Deploy Kagent CRDs, controller, PostgreSQL, tool server, and UI |
| `make swarm-kagent-down` | Remove Kagent control plane and CRDs |
| `make demo-kagent-up` | Deploy all 5 Kagent declarative agents to `fe-signalloom-agents` |
| `make demo-kagent-down` | Remove Kagent declarative agents |
| `make demo-kagent-test` | Run BATS test suites across all 5 verification phases |
| `make demo-kagent-demo` | Run interactive CLI walkthrough of all 5 agents |

## The Agent Swarm

Eight Agent CRs in `fe-signalloom-agents`, all `runtime: go`, all sharing one
`anthropic-claude` ModelConfig and one namespace-local `RemoteMCPServer`
(`d2-signalloom/infra/agent-swarm/remotemcpserver.yaml`) pointing at the chart's
built-in tool server at `http://kagent-tools.kagent:8084/mcp`.

**Every tool name below has been verified by calling it against that server.**
That sentence is the whole point of this section — see "How this list got wrong"
at the end.

### Operational (6)

1. **K8s Resource Reader (`kagent-k8s-reader`)** — `k8s_get_resources`,
   `k8s_get_available_api_resources`. Declarative Go ADK runtime, ~128Mi.
2. **Incident Responder (`kagent-incident-responder`)** — `k8s_get_events`,
   `k8s_get_pod_logs`, `k8s_describe_resource`, `k8s_get_resources`. Correlates
   restarts, exit codes and log tails into a timeline. Read-only: proposes
   remediation, never applies it. Agent Card contract
   (`agent-card.kagent-incident-responder.v1.json`) for A2A hand-offs.
3. **Security Analyst (`kagent-security-analyst`)** — `k8s_get_resources`,
   `k8s_get_resource_yaml`, `k8s_describe_resource`, `k8s_get_events`. Reports
   Kubernetes posture from workload security contexts, RBAC and NetworkPolicies.
   **No CVE or advisory lookup** (see Deferred). Agent Card contract
   (`agent-card.kagent-security-analyst.v1.json`).
4. **Network Auditor (`kagent-network-auditor`)** — `k8s_get_resources`,
   `k8s_get_resource_yaml`, `k8s_describe_resource`. Reports the *declared*
   network posture: missing default-deny, selectors matching nothing, broad
   ingress. **Does not probe live reachability, SPIFFE boundaries or Envoy
   routes** (see Deferred).
5. **Compliance Checker (`kagent-compliance-checker`)** — `k8s_get_resources`,
   `k8s_get_resource_yaml`, `k8s_describe_resource`. Reads RBAC, NetworkPolicy
   and workload manifests and reports policy posture. **Does not run CIS
   benchmarks** (see Deferred).
6. **FinOps Optimizer (`kagent-finops-optimizer`)** — `k8s_get_resources`,
   `k8s_get_resource_yaml`, `k8s_describe_resource`. Reads *declared* requests,
   limits and PVC inventory and flags unset or implausible values. **Does not
   measure observed utilisation** (see Deferred).

### Deferred (2) — declared, NOT working

Kept in the repo deliberately rather than deleted. Both reference tools that do
not exist. **They fail in two different ways, and the difference is the single
most important thing on this page:**

- `kagent-commit-summariser` names a `RemoteMCPServer` that does not exist
  (`github-tool`), so it does not compile: `Accepted=False`, no workload. Loud.
- `kagent-chaos-prober` names the tool server that DOES exist and asks it for
  two tools that do not. It compiles, reports **`Accepted=True, Ready=True`,
  and runs a pod** — while being able to do nothing at all. Silent.

Do not read this section's agents as "the broken ones you can see". One of them
is green on every dashboard in the repo. That is why the count that matters is
"agents whose tool names were verified against `tools/list`" — currently 6 of 8
— and not the Ready column.

7. **Chaos Prober (`kagent-chaos-prober`)** — wants `chaos_simulate_latency`,
   `chaos_probe_recovery`. **Blocker:** the tool server has no chaos tooling of
   any kind — not a missing backend, no such tool. The nearest real capability
   is `k8s_delete_resource`, which the tool server's ServiceAccount is denied by
   design (`kagent-tools.rbac.readOnly: true`). Needs a chaos MCP server that
   nobody has written, plus a deliberate decision to grant it write access.
   **Currently `Accepted=True, Ready=True` with a Running pod and zero working
   tools** — see the warning above.
8. **Commit Summariser (`kagent-commit-summariser`)** — wants
   `github_list_commits`, `github_get_commit` via the `github-tool` MCPServer.
   **Blocker:** no `github_*` tool exists on the built-in server. Needs an
   external GitHub MCP server wired in as its own `RemoteMCPServer`. The
   OpenBao-managed GitHub token plumbing is already in place and is not the
   blocker.

## Deferred capabilities

Capabilities removed from an agent's declaration rather than approximated with
a tool that does something weaker. Each is blocked on a component that is not
installed, **not** on agent configuration.

| Capability | Tool that would provide it | Blocker |
|---|---|---|
| CIS benchmark scanning | `kubescape_get_configuration_scan`, `kubescape_list_configuration_scans` | Tool exists; **Kubescape operator absent**. Calling it returns `workloadconfigurationscans.spdx.softwarecomposition.kubescape.io` not found. |
| CVE / advisory lookup | `kubescape_list_vulnerabilities` | Tool exists; **Kubescape operator absent** (`vulnerabilitymanifests` CRD missing). No other CVE/OSV tool on the server. |
| Observed resource utilisation | `prometheus_query_range_tool`, `prometheus_query_tool` | Tool exists; **no Prometheus reachable** — hardcoded `http://localhost:9090` from the tool pod. |
| PromQL query generation | `prometheus_promql_tool` | Tool exists; needs an **`OPENAI_API_KEY`** in the tool server (it is LLM-backed). Doubly blocked. |
| Envoy route inspection | `istio_proxy_config`, `istio_ztunnel_config` | Tools exist; **no Istio installed** (`istioctl` exits 64). |
| SPIFFE boundary probing | — | **No tool exists** on the server at all. |
| Live reachability probing | `k8s_check_service_connectivity` | Tool exists; execs a curl pod, which the **read-only tool-server RBAC denies**. |

Installing Kubescape unblocks two rows and re-points two agents; a reachable
Prometheus unblocks one. Both are cluster-capacity decisions, not agent work.

### How this list got wrong, so it does not happen again

The tool server was a stub until 2026-08-30: `python:3.12-alpine` running
`http.server`, returning **one hardcoded literal to every POST**. Posting
`k8s_get_resources` and `totally_made_up_xyz` produced byte-identical output.
So no tool name in this repo had ever been checked against an implementation,
and 18 of the 21 requested across the swarm were fictional — including six
requested from the tool server that genuinely exists.

Two properties of kagent 0.9.9 kept that invisible:

- The controller validates that a `RemoteMCPServer` **exists**, never that the
  `toolNames` are served by it. An agent requesting nothing but fictional tools
  still reports `Accepted=True, Ready=True` with a Running pod. **`Ready` means
  "compiled and running", not "can do anything."**
- The hand-written CRDs it replaced declared
  `x-kubernetes-preserve-unknown-fields: true`, so nothing validated.

`d2-signalloom/test/kagent-chart.bats` and the tool-existence contract test now
guard this. Verify by hand with `tools/list` against the tool server; a missing
tool returns JSON-RPC `-32602 tool 'x' not found`.

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

## OpenBao Agent Integration & Future Shaping

- **Current Seam**: Agent workloads map secrets through OpenBao SPIFFE-scoped paths (`secret/data/agents/<spiffe-id>/<key>`), declared in `d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml`.
- **OpenBao Agent Compatibility**: Kagent agent pod templates and ModelConfig definitions are designed so that an `openbao-agent` sidecar or injector can render secrets directly to `/vault/secrets/` on tmpfs `emptyDir` mounts without requiring modifications to the `Agent` CRs or MCP tool definitions.
- **Note**: `openbao-agent-sidecar.yaml` still names a shared `signalloom-agent-generic` role. `kagent-credentials.sh` creates per-agent roles instead, which are strictly narrower; the sidecar template needs its `role =` line updated per agent before it is applied anywhere.

## Tests & Verification

- `d2-signalloom/test/kagent-contract.bats` — Declarative size reduction (strictly fewer than 50 lines) & schema checks across all 5 agents.
- `test/kagent-install.bats` — CRDs, controller memory limit (≤512Mi), Postgres isolation.
- `test/kagent-agents.bats` — Declarative Agent CRs (all 5) and MCPServer discovery.
- `test/kagent-credentials.bats` — ServiceAccounts, SPIFFE labels, OpenBao secret mapping for all 5 agents.
- `test/kagent-demo-harness.bats` — End-to-end demo walkthrough.
