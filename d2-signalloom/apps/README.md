# Signal Loom application components

## fe-signalloom (API + Discovery Portal)

The API compatibility layer for the Signal Loom Agent-Governance dashboard.
28 authenticated endpoints serving live data from PostgreSQL (agents, compliance,
audit, NHI, settings, consent) + in-cluster k8s queries (agent discovery, crypto
proofs). Source in `fe-signalloom/src/`, schema in `fe-signalloom/src/db/`,
k8s manifests in `fe-signalloom/base/`. See `fe-signalloom/README.md` for full docs.

## dashboard-signalloom (React SPA)

The Signal Loom dashboard — React/Vite/TypeScript, served by nginx on port 8080.
Dex OIDC login (single-origin nginx proxy for `/dex` and `/api`). Features:
Agents, Compliance, Audit Trail, NHI Discovery, Settings, Cryptography (bao-spire
proofs), Onboarding wizard. Demo-data toggle (bottom-right corner) for offline
rendering with client-side fixtures.

## fake-integration-proxy (mock + discovery proxy)

Deterministic fixture proxy for demo integrations (`/llm`, `/crm`, `/notification`)
plus live k8s queries (`/agents` for agent discovery, `/crypto-proofs` for bao-spire
proofs). Runs in `inf-signalloom`. No outbound connections except the kube-apiserver
(via SA-token HTTPS, scoped egress NetworkPolicy).

## fe-signalloom-agents (agent inventory namespace)

Inert podinfo pods representing AI agents. Metadata (labels/annotations) is read
by the fake-proxy `/agents` endpoint and surfaced in the dashboard. Managed via
`make demo-signalloom-agents-up/down`. Label schema follows kagent conventions
(`signalloom.ai/agent=true` selector + `app.kubernetes.io/*`).
