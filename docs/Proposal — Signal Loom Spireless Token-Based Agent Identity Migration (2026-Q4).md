---
created: 2026-10-02
reviewers:
  - "#vicente-herrera"
  - "#stefan-prodan"
  - "#francesco-beltramini"
capabilities:
  - "#cap-security-engineering"
  - "#cap-architecture"
  - "#cap-kubernetes"
  - "#cap-secrets"
  - "#cap-golang"
  - "#cap-api-design"
  - "#cap-threat-modelling"
  - "#cap-testing-pyramid"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
  - Cyber Resilience & Threat Assurance
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-07-signalloom-d2-platform-baseline/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q4-signal-loom-spireless-token-migration
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q4-signal-loom-spireless-token-migration"
shortcode: SLTM
updated: 2026-10-02T23:30
---
# Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-10-02) |
| Reviewer & Date: | Vicente Herrera, Stefan Prodan, Francesco Beltramini (pending: the 2026-10-02 adversarial review below is sensai's, not theirs) |
| Approver & Date: | Andy Martin (2026-10-02, Phase 1 scope as revised) |

> **Revision 2026-10-02 (adversarial review).** The first draft proposed an OpenBao-minted, 300-second, refreshing JWT plus the deletion of SPIRE. Andy's direction the same evening was narrower and simpler: *"keep inbound authentication as simple as possible so we can do it from lots of different places … a bearer token with a long key … I specifically don't want the SPIRE server to run in the remote signal generating endpoint. The log forwarding may only have a very simple ability to set headers, so we'll have to use a static key for now"*, and *"cross-cluster auth could be complex, and we're trying to avoid that."* This revision makes **Phase 1 a static API key for the probe in the Kusari cluster, verified in that same cluster**, and moves everything else behind measured gates. The review findings that drove each change are in [Adversarial Review](#adversarial-review-2026-10-02).

---

## Press Release

ControlPlane today announced that a Signal Loom probe authenticates with a single long API key in a standard `Authorization: Bearer` header. A Kusari workload cluster's probe needs nothing else: no SPIRE agent, no CSI socket, no token refresh loop and no trust relationship with any other cluster. The key lives in a Kubernetes Secret in the probe's own cluster, is checked in constant time by the signal-ingest service in that same cluster, and grants exactly one permission: writing observations. Anything a log forwarder can do with a static header, it can now do as a first-class Signal Loom signal source.

---

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers:**

1. **Kusari EAP pilot.** The in-sentinel probe in the Kusari workload cluster (`kind-osramp` in the pilot) must post detections to signal-ingest. Today the live signal-ingest is an image that predates authentication, so it accepts anyone, and the HEAD build cannot start without SPIRE JWKS configuration.
2. **Remote signal sources with only header control.** Log forwarders and external sensors can set a static header and nothing more. They can't run a SPIRE agent, mount a node socket or refresh a token.
3. **Every other signal-ingest caller.** The fe-signalloom proxies, demos and live suites need a credential once authentication is enforced; Phase 1 gives each its own named key.

|  |  |
| :---- | :---- |
| Our *…* | Signal Loom probes and other signal sources, starting with the Kusari pilot's in-cluster sentinel |
| Have the problem/opportunity *…* | No way to authenticate to signal-ingest without SPIRE, so the deployed ingest runs unauthenticated |
| When *…* | Deploying the probe into a customer (Kusari) cluster, or forwarding signals from anything that can only set a header |

**What's the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

**Urgency: Q4 2026 (immediate).** Phase 1 is the authentication half of the SLDC containment pilot ([[Proposal — Signal Loom Local Dual-Cluster EAP Pilot Validation and In-Sentinel Sensor Containment (2026-Q3)]]): Step 4 of its containment suite is only meaningful once the observation it reads arrived through an authenticated write. Later phases serve the SLCO onboarding flow and are not urgent.

---

## Scope Summary

**Technology Readiness Level:** Phase 1 moves from 3 (static bearer built and unit-tested, not deployed) to 6 (deployed and verified in the pilot cluster by an automated harness). Later phases stay at 2.

### In Scope Activities (Phase 1)

*Within project delivery and managed by the project team*

| Deliverable | Description | Acceptance Criteria | Validation Method |
| :---- | :---- | :---- | :---- |
| **D1: Named static keys in signal-ingest** | Generalise the existing static-bearer wrapper (`api/static_bearer.go`) into a set of named keys, each bound to one subject, one tenant scope, a least-privilege permission list and an expiry. The JWT path stays exactly as it is and becomes optional: with no JWKS configured, every JWT is refused and the static keys still work. | Missing, unknown, expired or malformed key → **401**. A valid key on a route outside its grant → **403**. Comparison is constant time over SHA-256 digests. A key under 32 bytes, or with an expiry more than 90 days after start-up, is refused at start-up. (This replaces the single global sunset date, 2026-11-12, which would have expired every key at once with no rotation path short of a code change.) The key value never appears in argv, a ConfigMap, git or a log line; the key *name* is logged on use. | Go unit and adversarial tests, each mutation-proven. The real binary started locally with keys only. |
| **D2: The probe's key** | The Kusari cluster's probe (`stun-sentinel` DaemonSet, `fe-signalloom-agents`) reads its key from Secret `stun-sentinel-ingest-token` (key `token`) through `SIGNAL_INGEST_TOKEN`, and sends it only as `Authorization: Bearer`. The binary carries no default key. | The probe's key grants exactly `observations:write`. A missing Secret is loud (`ingest_token_missing` at start-up and in the stats line) and never stops detection or freeze. | Go tests on the sentinel; live probe of the running pod. |
| **D3: Issuer script** | `scripts/sldc-ingest-bearer.sh --context <ctx>` mints a ≥32-byte random key, or reads one from stdin, and writes the probe's Secret and the verifier's Secret in the **same cluster**, idempotently. It never prints the key or passes it on a command line. Rotation is a re-run plus a restart of both workloads. | Re-run with no change is a no-op. Rotation makes the old key a 401 once both pods restart. | bats against a fake kubectl (exact exit codes); live rotation in the harness. |
| **D4: Same-cluster only** | The probe's `SIGNAL_INGEST_URL` is its own cluster's Service FQDN. No ingest key exists outside the cluster that verifies it, and the hub accepts none. | Zero Secrets holding an ingest key on `kind-signalloom-hub`; the probe's URL resolves to its own cluster's Service. | Live harness assertions. |
| **D5: Every caller has its own key, and reads are tenant-scoped** | The fe-signalloom gateway, the Signal Fusion demo, the live suites and the Step 4 evidence reader each get a named key with only what they call. An observation's tenant is its `labels.tenant_id`; a tenant-scoped key reads only its own tenant and writes only its own tenant. The gateway key holds `act_for_tenant`: fe-signalloom sends its already-verified user tenant as `X-SignalLoom-Acting-Tenant`, which signal-ingest honours only for a key holding that grant and ignores for everyone else. Actor and aggregate routes, and untenanted data, need `cross_tenant_read`, held by operator tools and by the gateway acting for a superadmin (`*`). The probe holds `cross_tenant_write`, because it observes every tenant's pods. | A tenant-A user sees no tenant-B rows on any proxied route. A forged acting-tenant header from any other key changes nothing. A tenant-scoped key on an actor or aggregate route gets 403 `cross_tenant_read_required`, never a silently filtered result. A non-superadmin can never act as `*`. | Go tests per read route, pytest on the fe side, each mutation-proven. |
| **D6: Probe API-key harness** | `make test-sltm-probe-apikey` proves D1–D4 end to end: an offline tier against the real signal-ingest binary started locally, and a live tier against the pilot cluster. | Both tiers green twice in a row. | The harness itself. |

### Out of Scope (Phase 1)

* **Removing SPIRE.** SPIRE is still load-bearing: fleet-manager's stun cascade revokes SPIRE entries (`apps/fleet-manager/spire_client.go`, `cascade.go`), the Agent Trust slice federates through it (`d2-agent-trust/`), and signal-ingest has a SPIRE collector (`collectors/spirea/`). Phase 1 adds no new dependency on SPIRE and removes none.
* **OpenBao-minted short-lived tokens, refresh loops and `/enroll` refactoring.** Deferred to Phase 2, behind the gate below.
* **Cross-cluster authentication of any kind.**
* **Human operator OIDC** (Dex) is unchanged.

### Later phases (each gated on evidence, none committed)

| Phase | Scope | Gate to start |
| :---- | :---- | :---- |
| 2 | Short-lived tokens minted by OpenBao for **remote** sources that cross a network boundary, with TLS at the edge. | A customer source outside the verifying cluster exists, and static-key rotation has been measured as an operational burden. |
| 3 | SPIRE retirement. | A measured footprint and flake rate (Phase 1 records the baseline), and fleet-manager's cascade plus Agent Trust migrated off SPIRE first. |

---

### KPIs

| Metric | Current Value (measured 2026-10-02) | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Unauthenticated observation write accepted by the pilot's signal-ingest | **Accepted** (live image predates auth) | **401** | Harness live tier |
| Credentials a probe needs | SPIRE JWT-SVID (unavailable to the probe) | **1 Secret, 1 env var** | Rendered DaemonSet |
| Ingest keys held outside the verifying cluster | n/a | **0** | Harness live tier |
| Key comparison cost | not measured | measured by `go test -bench` and recorded, no target | Go benchmark |

The first draft's memory (650 MB in the press release, 680 MB in the KPI table), 4.2% flake and 15-minute onboarding figures had no measurement behind them and are withdrawn until Phase 3 measures them.

---

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| **Key forgery, replay, truncation and timing** | Adversarial Go tests: wrong key, key prefix, key plus suffix, whitespace, case variants, empty header, `Basic` scheme, duplicate headers, expired key; each mutation-proven. | Lead Security Engineer (`#vicente-herrera`) |
| **Cross-tenant isolation** | A tenant-A key reads no tenant-B rows on every read route; only `cross_tenant_read` crosses. | Testing & QA Lead (`#francesco-beltramini`) |
| **Probe end-to-end** | `make test-sltm-probe-apikey` live tier on the pilot cluster, twice in a row. | Cloud Native Architect (`#stefan-prodan`) |

---

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| **HTTP Bearer (RFC 6750)** with a static opaque key | The only credential a probe or forwarder needs | Any client that can set one header |
| **Kubernetes Secrets** | Key storage in the probe's and verifier's own cluster | Already used across the estate |
| **Go (`signal-ingest`, `stun-sentinel`)** | Verification (constant-time digest compare) and the probe's client | Existing services |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Verifier | `d2-signalloom/apps/signal-ingest/` (`api/static_bearer.go`) | Port 8082; probes on a separate unauthenticated port 8083, not in the Service |
| Probe | `d2-signalloom/apps/signalloom-stun-sentinel/` + `apps/stun-sentinel/pkg/correlator` | Posts `POST /api/v1/observations` (a JSON array) |
| Probe manifest | `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/` + overlays | `SIGNAL_INGEST_URL` from the per-cluster ConfigMap |
| Issuer | `scripts/sldc-ingest-bearer.sh` | Same-cluster Secrets only |
| Harness | `test/sltm-probe-apikey.bats`, `make test-sltm-probe-apikey` | Offline tier + live tier (`SLTM_LIVE=1`) |

---

#### Security and Risk

**Threat model for Phase 1 (STRIDE):**

| Threat | Impact | Mitigation | Residual |
| :---- | :---- | :---- | :---- |
| **Spoofing** | Anyone holding the probe's key can write observations attributed to the probe. | Key is ≥32 random bytes, Secret-held, scoped to `observations:write`, with an expiry; tenancy on each observation comes from the probe's operator tenant map, not the payload author. | A shared static key is not workload attestation: observations written with it are **not identity-bound**. The forensic bundle already scopes itself to "integrity and signer identity, not truth". |
| **Tampering** | In-cluster traffic from probe to ingest is plain HTTP on the pod network. | Same-cluster only; NetworkPolicy admits the probe to ingest. | A pod-network attacker can read the key. TLS is a Phase 2 item for traffic that leaves the cluster. |
| **Repudiation** | A key holder denies a write. | The key *name* is logged per request. | Static keys give accountability per key, not per process. |
| **Information disclosure** | Key leaked via argv, logs or a ConfigMap. | Env from Secret only; no flag; no default; redaction tests. | Anyone with `get secrets` in the namespace can read it. |
| **Denial of service** | Invalid-key floods. | Constant-time compare over a fixed-length digest is cheap. | No rate limit in-cluster in Phase 1. |
| **Elevation of privilege** | A key reads or writes another tenant's data. | Reads tenant-scoped by key; `cross_tenant_read` only for the gateway. | The probe is a cross-tenant **writer** by design (it observes every tenant's pods), so its writes carry the tenant from operator config, not from the key. |

**SWOT Analysis:**

| Strengths | Weaknesses |
| :---- | :---- |
| • One header, any client.<br/>• No SPIRE, no refresh loop, no cross-cluster trust.<br/>• Testable end to end in one cluster. | • A static key is a long-lived bearer secret.<br/>• No per-process attestation. |
| **Opportunities** | **Threats** |
| • The same contract serves log forwarders and external sensors.<br/>• A clean place to add short-lived tokens later without changing the probe's header. | • Key leak until rotation. Every key carries an expiry no more than 90 days after the process starts, the binary warns per key in the last 14 days, and `sldc-ingest-bearer.sh --rotate` resets it, so rotation cannot be forgotten silently and an expired key never becomes a fleet-wide outage. |

---

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **M1: Named static keys + tenant-scoped reads** (D1, D5) |  |  |  |  | `#cap-golang` `#cap-security-engineering` |
| **M2: Probe key and issuer** (D2, D3, D4) |  |  |  |  | `#cap-golang` `#cap-kubernetes` `#cap-secrets` |
| **M3: Probe API-key harness, offline and live** (D6) |  |  |  |  | `#cap-testing-pyramid` |
| **M4: Deploy to the pilot cluster and pass the harness twice** |  |  |  |  | `#cap-kubernetes` |
| **Signoff** |  |  |  |  | `#cap-engagement-management` |

**Definition of Done (Phase 1):**

* The pilot cluster's signal-ingest is built from HEAD, enforces authentication, and starts with static keys and no JWKS.
* The probe posts with its key and gets 201; no key, a wrong key or an expired key gets 401; the probe's key on a read route gets 403.
* No ingest key exists on any cluster other than the one that verifies it.
* `make test-sltm-probe-apikey` passes offline and live, twice in a row from a clean start.

---

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| **Accountable** | Lead Security Architect (`#vicente-herrera`) |
| **Responsible** | Platform Engineering Team (`#stefan-prodan`, `#francesco-beltramini`) |
| **Consulted** | Technical Solutions & EAP Lead (`#francesco-beltramini`) |
| **Informed** | [Andrew Martin](mailto:andy@control-plane.io), [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

---

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| None | £0 | n/a | n/a |

The first draft's -£180/month saving depended on removing SPIRE, which is now Phase 3, so it is withdrawn.

---

## Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | :--- | :--- | :--- | :--- |
| 2026-10-02 | AJM, Vicente Herrera | ADR-01 (draft): eliminate SPIRE and standardise on bearer tokens | SPIRE blocks external agents | **Superseded by ADR-03** for Phase 1; SPIRE removal is Phase 3 |
| 2026-10-02 | AJM, Stefan Prodan | ADR-02 (draft): OpenBao as token authority with 300 s TTL | Time-bound, revocable tokens | **Deferred to Phase 2**: the probe gains nothing from it in-cluster, and reaching OpenBao from a remote probe is the cross-cluster dependency ADR-03 avoids |
| 2026-10-02 | AJM | **ADR-03: Phase 1 is a static, named, long API key per caller, header-only, verified in the probe's own cluster** | "keep inbound authentication as simple as possible … a bearer token with a long key … I specifically don't want the SPIRE server to run in the remote signal generating endpoint … cross-cluster auth could be complex, and we're trying to avoid that" | No SPIRE or OpenBao on the probe's path; one Secret per side; rotation is a script re-run |
| 2026-10-02 | AJM | **ADR-04: signal-ingest reads are tenant-scoped; the gateway acts for the user's tenant** | The review found signal-ingest's read handlers ignore tenancy, and fe-signalloom resolves the user's tenant and then never uses it (`signal_fusion.py` `get_observations`), so any dashboard user saw every tenant | Least privilege becomes real. The gateway forwards the verified user tenant, honoured only for a key holding `act_for_tenant`. Assumption, reversible by removing one grant: a superadmin's cross-tenant view is intended. |

---

## Adversarial Review (2026-10-02)

Every finding was checked against the repository at the integration line (`sldc2/base-slms`) or the live pilot cluster.

| # | Draft claim | Finding | Evidence | Disposition |
| :---- | :---- | :---- | :---- | :---- |
| 1 | Delete SPIRE entirely (D4, M5) | SPIRE is load-bearing outside identity for agents: the stun cascade's SPIRE plane, Agent Trust federation, and a signal-ingest collector depend on it. Deleting it breaks containment. | `apps/fleet-manager/{spire_client,cascade}.go`; `d2-agent-trust/spire-federation-*.yaml`; `apps/signal-ingest/collectors/spirea/` | Moved to Phase 3 with prerequisites |
| 2 | Manifests at `d2-signalloom/infra/inf-bao/spire-*` | Path does not exist; SPIRE lives in `infra/inf-bao/configs/base/spire-agent.yaml`, `controllers/base/openbao-spire.yaml` and `deploy/spiffe-csi/` | `ls d2-signalloom/infra/inf-bao` | Corrected in Phase 3 scope when it starts |
| 3 | Telemetry endpoint `POST /api/v1/telemetry` on `signal-ingest:8080`, answering 202 | No such route. The probe posts `POST /api/v1/observations` (a JSON array) to port 8082 and gets 201 | `api/auth.go` route table; `base/service.yaml` | Contract corrected |
| 4 | "Tenant ID is cryptographically bound inside the token" | The probe is a node-level, cross-tenant observer; a per-tenant token cannot describe its writes. And signal-ingest's read handlers never consulted tenancy at all. | `api/handlers.go` read handlers; sentinel tenant map (`pkg/correlator/tenancy.go`) | ADR-04; probe tenancy from operator config |
| 5 | PostgreSQL RLS protects tenants on ingest | The observation store does not apply tenancy; RLS covers the identity repository, not observations | `store/` | Replaced by key-scoped reads (D5) |
| 6 | 300 s TTL plus refresh against OpenBao | For a remote probe this needs a network path to OpenBao: the cross-cluster dependency Andy asked to avoid; for the in-cluster probe it adds a failure mode and no benefit | ADR-03 quote | Phase 2, gated |
| 7 | Tokens "never written to disk" | A Kubernetes Secret is stored in etcd; env from Secret is visible to anyone who can read the pod's Secret | Kubernetes model | Stated as residual |
| 8 | TLS 1.3 at Envoy protects the token | Probe-to-ingest traffic is in-cluster ClusterIP HTTP and never touches Envoy | `configmap.yaml` `SIGNAL_INGEST_URL` | Stated as residual; TLS in Phase 2 |
| 9 | 650 MB / 680 MB, 4.2% flakes, >15 min onboarding, -£180/month | Unmeasured, and internally inconsistent (650 vs 680) | No source in repo or vault | Withdrawn; Phase 1 measures the baseline |
| 10 | Reviewers and approver signed off on the draft | No review record exists beyond the draft itself | Vault and repo history | Reviewer row marked pending |
| 11 | The deployed ingest rejects unauthenticated requests with 401 | The live pilot signal-ingest is a 2026-09-15 image with no auth; HEAD cannot even start without SPIRE JWKS | Live pod image `signal-ingest:local`; `main.go` `AuthConfigFromEnv` | Fixed by D1 (JWKS optional) and M4 |
| 12 | Every probe health check works under auth | Every route, including `/healthz` and `/readyz`, sat behind the auth router, so any auth-on build crash-looped on kubelet probes | `api/` router | Probes moved to unauthenticated port 8083, outside the Service |
| 13 | (not in draft) fe-signalloom enforces user tenancy before proxying to signal-ingest | It resolves the tenant and discards it; `_proxy` returns signal-ingest's JSON verbatim | `fe-signalloom/src/signal_fusion.py` `get_observations` | ADR-04, D5 |

---

## Appendix

### A. Sequence: the Kusari cluster's probe authenticating with its API key

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator (sldc-ingest-bearer.sh)
  participant K8s as Kusari cluster API (Secrets)
  participant Probe as stun-sentinel (probe)
  participant Ingest as signal-ingest (same cluster)

  Op->>K8s: write stun-sentinel-ingest-token (fe-signalloom-agents)
  Op->>K8s: write signal-ingest-static-bearer (fe-signalloom)
  K8s-->>Probe: SIGNAL_INGEST_TOKEN (env from Secret)
  K8s-->>Ingest: named key set (from Secret)
  Probe->>Ingest: POST /api/v1/observations, Authorization: Bearer key
  Ingest->>Ingest: SHA-256 digest, constant-time compare, check grant
  Ingest-->>Probe: 201 Created
  Note over Probe,Ingest: no key → 401 · wrong or expired key → 401 · probe key on a read route → 403
```

### B. API contract (Phase 1)

* `POST /api/v1/observations` with `Authorization: Bearer <key>` and a JSON array of observations → `201 {"ingested": N}`.
* Missing, unknown, expired or malformed key → `401`. Valid key outside its grant → `403`.
* Health: `GET :8083/healthz` and `GET :8083/readyz` without credentials (not exposed by the Service).
