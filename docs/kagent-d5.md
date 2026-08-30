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

## OpenBao Agent Integration & Future Shaping

- **Current Seam**: Agent workloads map secrets through OpenBao SPIFFE-scoped paths (`secret/data/agents/<spiffe-id>/<key>`), declared in `d2-signalloom/infra/agent-swarm/openbao-secret-paths.yaml`.
- **OpenBao Agent Compatibility**: Kagent agent pod templates and ModelConfig definitions are designed so that an `openbao-agent` sidecar or injector can render secrets directly to `/vault/secrets/` on tmpfs `emptyDir` mounts without requiring modifications to the `Agent` CRs or MCP tool definitions.

## Tests & Verification

- `d2-signalloom/test/kagent-contract.bats` — Declarative size reduction (strictly fewer than 50 lines) & schema checks across all 5 agents.
- `test/kagent-install.bats` — CRDs, controller memory limit (≤512Mi), Postgres isolation.
- `test/kagent-agents.bats` — Declarative Agent CRs (all 5) and MCPServer discovery.
- `test/kagent-credentials.bats` — ServiceAccounts, SPIFFE labels, OpenBao secret mapping for all 5 agents.
- `test/kagent-demo-harness.bats` — End-to-end demo walkthrough.
