# SLAAT-P1-1 — Network Security Hardening Checklist

Derived from `ci-evidence/slaat-p1-1-network-findings.json`. Items are grouped
by whether P2 (`SLAAT-P2-1`, "Ingress Route Protection & Network
Microsegmentation Fixes") should treat them as a fix or an accepted/backlog
item. **This card does not implement any of these fixes** — it is probe-only
per the merge boundary; this table is the handoff artifact for P2.

## Evaluated ingress routes

| Route | Hostname | Path prefix | Backend | Probed |
| --- | --- | --- | --- | --- |
| `signalloom-dashboard` | `dashboard.osramp.acme.local` | `/` | `dashboard-signalloom:8080` | yes (baseline, traversal fallthrough target) |
| `signalloom-dex` | `dashboard.osramp.acme.local` | `/dex` | `dex.inf-signalloom:5556` | no (out of this card's probe set; OIDC flows are `SLAAT-P1-2`'s scope) |
| `signalloom-api` | `dashboard.osramp.acme.local` | `/api` | `fe-signalloom-api:8000` | yes (traversal, header-spoof, healthz probes) |
| `signalloom-docs` | `dashboard.osramp.acme.local` | `/docs` | `docs-signalloom:8080` | no (static docs, low risk; not probed this pass) |
| `http-to-https-redirect` | `*.osramp.acme.local` | `/` | n/a (301 redirect) | implicitly exercised by every HTTPS probe reaching the HTTPS listener directly |

## Fix (P2 should address)

- [ ] **`backend` namespace has zero NetworkPolicy coverage.** Add a blanket
      `podSelector: {}` default-deny (Ingress+Egress) plus explicit allows for
      MinIO/NATS/Postgres's actual legitimate consumers. Evidence: `LAT-4`,
      `LAT-5`, `LAT-6` (reachable from `frontend` with zero policy on either
      side); `NETPOL-backend` (0 policies, 7 pods).
- [ ] **`frontend` namespace has zero NetworkPolicy coverage.** Same
      treatment. Evidence: `NETPOL-frontend` (0 policies, 3 pods).
- [ ] **`ingress` namespace (the Envoy Gateway control plane itself) has zero
      NetworkPolicy coverage.** Its metrics port (`19001`) is reachable from
      any unprivileged tenant pod with no authentication (`LAT-9`). At minimum,
      restrict ingress on `19001`/`18001`/`18002`/`9443` to an explicit
      observability-tooling namespace selector; do not leave the Gateway's own
      control-plane ports open to every workload namespace.
- [ ] **`fe-k8s-afm` namespace has zero NetworkPolicy coverage** (`NETPOL-fe-k8s-afm`,
      1 pod). Scope before this namespace grows.
- [ ] **`cpai` namespace has zero NetworkPolicy coverage** (`NETPOL-cpai`,
      1 pod).
- [ ] **`kagent` namespace is only partially covered.** `kagent-postgres-isolation`
      correctly scopes ingress to `kagent-postgresql` from
      `kagent-controller` only — that part is good. But `kagent-controller`,
      `kagent-ui`, and `kagent-tools-metrics` have **no** Ingress-type policy
      selecting them at all, and nothing restricts their egress. Add a
      namespace-wide default-deny and carve out the already-working
      controller→postgres and tool-server paths explicitly.
- [ ] **No `ClientTrafficPolicy` is configured for the Gateway.** Default XFF
      handling appends the real peer rather than trusting the client value,
      which is safe, but a client-supplied `X-Forwarded-For` entry is still
      present in the chain a careless backend could misread as the trusted
      hop (confirmed in the access-log sample:
      `"x-forwarded-for": "1.2.3.4,10.0.0.126"`). Add an explicit
      `ClientTrafficPolicy` with `xffNumTrustedHops` (or equivalent) so the
      trust boundary is declared, not merely "happens to be safe by Envoy's
      current default."

## Advisory (platform namespaces — needs a scoped allowlist, not a blind copy)

- [ ] `cert-manager`, `kube-system`, `spire-system`, `local-path-storage`,
      `registry` carry zero NetworkPolicy. These are core cluster plumbing
      (CNI, DNS, ACME issuance, SPIFFE attestation, local-path provisioner,
      the internal OCI registry) where a blanket default-deny risks breaking
      the cluster if applied without a carefully-scoped allowlist. Recommend
      a dedicated, lower-urgency follow-up rather than folding into P2-1's
      tenant-namespace fixes.

## Backlog / accepted (not a P1-1 finding, but surfaced for completeness)

- [ ] **HTTP/2 pseudo-header manipulation / request smuggling** was not
      exhaustively tested (`GW-H2-1`) — the probe toolchain (curl) cannot
      forge invalid `:method`/`:path`/`:authority` framing independent of its
      own HTTP/2 library. If this threat is in scope for the platform's threat
      model, a dedicated raw-frame tool (e.g. `h2load`, a custom
      `hyper`/`nghttp2` harness) should be added in a follow-up card.
- [ ] **TLS-layer rejections (`filter_chain_not_found`) do not log the
      attempted SNI hostname**, only that a connection was rejected and from
      which client IP (see `envoy-access-log-validation-report.md`). Low
      priority: the client IP and rejection class are already sufficient to
      detect and rate-limit an attacker; recovering the attempted hostname
      needs filter-chain-level log configuration.

## Confirmed-clean (no action needed)

- [x] Path traversal (plain `../`, percent-encoded `../`, double slash) is
      normalized before routing and cannot escape the matched backend or
      reach the filesystem (`GW-TRAV-1`, `GW-TRAV-2`, `GW-TRAV-3`).
- [x] Percent-encoded slash (`%2f`) inside a path segment is rejected by
      Envoy's `path_normalization_failed` handling before any backend is
      contacted — no differential parsing between Gateway and backend
      (`GW-TRAV-4`).
- [x] Embedded null bytes are rejected as malformed requests (`GW-TRAV-5`).
- [x] TLS 1.0 and TLS 1.1 are refused by the listener; TLS 1.2 and 1.3
      negotiate strong AEAD ciphers (`GW-TLS-1.0` .. `GW-TLS-1.3`).
- [x] Unregistered virtual hosts are rejected at the TLS/SNI layer, and a
      spoofed `Host:` header with a valid SNI does not cross into another
      tenant's route (`GW-VHOST-1`, `GW-VHOST-2`).
- [x] `default`, `inf-signalloom`, `agent-trust-*`, `fe-signalloom*`,
      `inf-bao`, `flux-system`, `eap-6f82ad81`, and `stun-pre-probe` all carry
      a genuine blanket default-deny and held under direct lateral-movement
      probing (`LAT-1`, `LAT-2`, `LAT-3`, `LAT-7`, `LAT-8`; `NETPOL-*` records
      for the rest).
