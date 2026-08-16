# Signal Loom application components

## fe-signalloom (API and discovery portal)

API compatibility layer for the Signal Loom agent-governance dashboard.
30 authenticated endpoints serve live data from PostgreSQL (agents, compliance,
audit, NHI, settings, consent) and in-cluster Kubernetes queries (agent
discovery, crypto proofs). Source: `fe-signalloom/src/`. Schema:
`fe-signalloom/src/db/`. Manifests: `fe-signalloom/base/`.
See `fe-signalloom/README.md` for full documentation.

## dashboard-signalloom (React SPA)

Signal Loom dashboard. React, Vite, TypeScript, served by nginx on port 8080.
Dex OIDC login through a single-origin nginx proxy for `/dex` and `/api`.
Pages: Agents, Compliance, Audit Trail, NHI Discovery, Settings, Cryptography
(bao-spire proofs), Onboarding wizard. Demo-data toggle (bottom-right corner)
switches to client-side fixtures for offline rendering.

## fake-integration-proxy (mock and discovery proxy)

Deterministic fixture proxy for demo integrations (`/llm`, `/crm`,
`/notification`) and live Kubernetes queries (`/agents` for agent discovery,
`/crypto-proofs` for bao-spire proofs). Runs in `inf-signalloom`. Only
outbound connection: kube-apiserver (SA-token HTTPS, scoped egress
NetworkPolicy).

## fe-signalloom-agents (agent inventory namespace)

Inert podinfo pods that represent AI agents. The fake-proxy `/agents` endpoint
reads their labels and annotations, then surfaces them in the dashboard.
Managed with `make demo-signalloom-agents-up/down`. Label schema follows
kagent conventions (`signalloom.ai/agent=true` selector plus
`app.kubernetes.io/*`).
