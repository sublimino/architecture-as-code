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

## Five Distinct Agent Types Built for Demonstration

1. **K8s Resource Reader (`kagent-k8s-reader`)**:
   - Single MCP tool (`k8s_get_resources` via built-in `kagent-tool-server`).
   - Declarative Go ADK runtime (~2s startup, ~128Mi footprint).
   - Anthropic ModelConfig with OpenBao-managed API key.
2. **Commit Summariser (`kagent-commit-summariser`)**:
   - Git commit and PR diff summarisation via `github-tool` MCPServer.
   - Dual credentials (OpenBao GitHub token + Anthropic LLM key).
   - Mock test scaffolding for isolated local CI execution.
3. **Security Analyst (`kagent-security-analyst`)**:
   - Multi-tool posture agent (K8s query, OSV/CVE vuln database, policy evaluation).
   - Implements Agent Card contract (`agent-card.kagent-security-analyst.v1.json`) for A2A hand-offs following Olly Sentinel patterns.
4. **Network Auditor (`kagent-network-auditor`)**:
   - Specializes in NetworkPolicy rules verification, SPIFFE trust boundaries, and Envoy Gateway route auditing.
   - Tools: `audit_netpol_rules`, `probe_spiffe_boundaries`, `inspect_envoy_routes`.
5. **Incident Responder (`kagent-incident-responder`)**:
   - SRE incident triage, pod restart correlation, and automated remediation patch proposals.
   - Implements Agent Card contract (`agent-card.kagent-incident-responder.v1.json`) for A2A hand-offs.

## The Model Credential

The Anthropic API key is supplied by the operator, stored in OpenBao under a
path scoped by each agent's own SPIFFE ID, and projected from there into the one
Kubernetes Secret the kagent controller is contractually required to read.

```bash
export ANTHROPIC_API_KEY='sk-ant-...'
make demo-kagent-credentials          # seed -> sync -> verify
make demo-kagent-credentials-verify   # evidence without disclosure
```

There is **no fallback**. With `ANTHROPIC_API_KEY` unset, empty, whitespace, the
retired placeholder, or implausibly short, `seed` refuses and names the variable.
This replaces a committed Secret containing the literal
`mock-anthropic-key-for-local-demo` — 33 bytes with which no agent can complete
a model call, and which every presence check reported as healthy.

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
