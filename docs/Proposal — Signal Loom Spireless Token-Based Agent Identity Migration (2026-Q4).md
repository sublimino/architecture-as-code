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
  - "#cap-python"
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

> **Revision 2026-10-03 (second draft appraised).** Andy's 01:00 update to the original draft added partition tolerance (8-hour leases, 4-hour sliding refresh, local buffering), a 0600 credential file instead of `keyctl`, an explicit acceptance of bearer-exfiltration risk with compensating controls, and an L7/L3 decoupling that rejects kTLS. Each was appraised against the code and Andy's ADR-03 direction. The resilience, risk and decoupling ideas are integrated as **Phase 1b** (D7–D10, ADR-08 to ADR-10) on static keys. Lease length and refresh move into the gated Phase 2 at 8 h/4 h instead of 300 s. The SPIRE-deletion and 650 MB claims stay withdrawn. Dispositions are in [Second Draft Appraisal](#second-draft-appraisal-2026-10-03).

> **Status 2026-10-03.** Phase 1 D1–D6 are built and merged on the integration line: named keys (one Secret per key, `signal-ingest-key-<name>`, value plus `.expires`), JWKS optional, tenant-scoped reads and writes, the probe's key from `stun-sentinel-ingest-token`, the issuer script, and `make test-sltm-probe-apikey` (offline tier 10/10 against the real binary). The Definition of Done is **not yet met**: the live tier passes only after the deploy, twice in a row. The same named-key pattern now also guards fleet-manager (ADR-05).

---

## Press Release

ControlPlane today announced that a Signal Loom probe authenticates with a single long API key in a standard `Authorization: Bearer` header. A Kusari workload cluster's probe needs nothing else: no SPIRE agent, no CSI socket, no token refresh loop and no trust relationship with any other cluster. The key lives in a Kubernetes Secret in the probe's own cluster, is checked in constant time by the signal-ingest service in that same cluster, and grants exactly one permission: writing observations. Anything a log forwarder can do with a static header, it can now do as a first-class Signal Loom signal source. Detections survive an ingest outage: the probe spools them on its own node and replays them in order when the link returns, and a revoked key stops working without restarting anything.

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
| **D5: Every caller has its own key, and reads are tenant-scoped** | The fe-signalloom gateway, the Signal Fusion demo, the live suites and the Step 4 evidence reader each get a named key with only what they call. An observation's tenant is its `labels.tenant_id`; a tenant-scoped key reads only its own tenant and writes only its own tenant. The gateway key holds `act_for_tenant`: fe-signalloom sends its already-verified user tenant as `X-SignalLoom-Acting-Tenant`, which signal-ingest honours only for a key holding that grant and ignores for everyone else. An actor belongs to a tenant only when every observation it was built from carries that tenant; mixed or untenanted actors, and the risk/fleet catalogue (which carries no tenant), need `cross_tenant_read`, held by operator tools and by the gateway acting for a superadmin (`*`). Aggregates count only rows the caller may read. The probe holds `cross_tenant_write`, because it observes every tenant's pods. | A tenant-A user sees no tenant-B rows on any proxied route. A forged acting-tenant header from any other key changes nothing. Another tenant's actor is a 404 identical to a missing one; risk/fleet without cross-read is 403 `cross_tenant_read_required`; an actor whose evidence becomes mixed disappears from the tenant's view on the next read. A non-superadmin can never act as `*`. | Go tests per read route, pytest on the fe side, each mutation-proven. |
| **D6: Probe API-key harness** | `make test-sltm-probe-apikey` proves D1–D4 end to end: an offline tier against the real signal-ingest binary started locally, and a live tier against the pilot cluster. | Both tiers green twice in a row. | The harness itself. |

### In Scope Activities (Phase 1b: resilience and revocation on static keys)

| Deliverable | Description | Acceptance Criteria | Validation Method |
| :---- | :---- | :---- | :---- |
| **D7: Partition-tolerant spool in the probe** | When signal-ingest is unreachable or answers 5xx, the probe appends each observation batch to a bounded on-node spool (`/var/lib/signalloom/spool`, hostPath, directory `0700`, files `0600`), then replays it in order once ingest answers again. Today a failed dispatch is counted and the observation is lost. | No observation is lost across an ingest outage of up to 8 h, within a configured size cap. When the cap is hit, the oldest batches go first, counted and logged. Replay preserves order and is idempotent, because the observation ID is deterministic. 401/403 are not retried and are loud. Detection and freeze never wait on the spool. | Go tests with an injected outage, restart and cap; live partition-injection test (deny egress to ingest for N minutes, then restore). |
| **D8: Revocation without a restart** | signal-ingest re-reads its key directory when the projected Secret changes. Deleting or rotating a key's Secret revokes it with no restart and no new infrastructure (no Redis). | A deleted key is a 401 within the kubelet's projection sync, ≤ 90 s measured. A rotated key's old value is a 401 and the new one a 201. A malformed update keeps the last good key set and is loud. | Go tests on the reloader; live revoke-and-measure in the probe test. |
| **D9: Per-key rate limiting** | A token bucket per key name in signal-ingest. Over the limit the answer is 429 with `Retry-After`, which the probe's spool honours. | A flood from one key cannot starve another key. 429 carries `Retry-After`, and the probe backs off without losing data. | Go tests; adversarial flood in the offline probe test. |
| **D10: Per-key batch sequence and hash chain** | Each sender numbers its batches and chains them (`seq`, `prev` = SHA-256 of the previous batch). signal-ingest verifies continuity per key and records gaps, replays and reordering as audit events, without rejecting late spool replays. | A replayed or reordered batch is detected and audited. A spool replay after an outage is accepted as a contiguous continuation. A chain that restarts after a probe restart is recorded as a new epoch, not a forgery. | Go tests over replay, reorder, gap and epoch cases. |

### Out of Scope (Phase 1)

* **Removing SPIRE.** SPIRE is still load-bearing: fleet-manager's stun cascade revokes SPIRE entries (`apps/fleet-manager/spire_client.go`, `cascade.go`), the Agent Trust slice federates through it (`d2-agent-trust/`), and signal-ingest has a SPIRE collector (`collectors/spirea/`). Phase 1 adds no new dependency on SPIRE and removes none.
* **OpenBao-minted short-lived tokens, refresh loops and `/enroll` refactoring.** Deferred to Phase 2, behind the gate below.
* **Cross-cluster authentication of any kind.**
* **Human operator OIDC** (Dex) is unchanged.

### Later phases (each gated on evidence, none committed)

| Phase | Scope | Gate to start |
| :---- | :---- | :---- |
| 2 | Session tokens minted by OpenBao for **remote** sources that cross a network boundary, with TLS at the edge: 8-hour leases with a proactive 4-hour sliding refresh (not 300 s, which loses data across partitions), `telemetry:write` scope, revocation by token accessor. Headless hosts keep the credential in a `0600` file (ADR-10). | A customer source outside the verifying cluster exists, and static-key rotation has been measured as an operational burden. |
| 3 | SPIRE retirement. | A measured footprint and flake rate (Phase 1 records the baseline), and fleet-manager's cascade plus Agent Trust migrated off SPIRE first. |

---

### KPIs

| Metric | Current Value (measured 2026-10-02) | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Unauthenticated observation write accepted by the pilot's signal-ingest | **Accepted** (live image predates auth) | **401** | Harness live tier |
| Credentials a probe needs | SPIRE JWT-SVID (unavailable to the probe) | **1 Secret, 1 env var** | Rendered DaemonSet |
| Ingest keys held outside the verifying cluster | n/a | **0** | Harness live tier |
| Key comparison cost | not measured | measured by `go test -bench` and recorded, no target | Go benchmark |
| Observations lost during an ingest outage | **All** (a failed dispatch is counted, not kept) | **0** for outages up to 8 h within the spool cap | Partition-injection test (D7) |
| Time for a revoked key to stop working | Until the pod restarts | **≤ 90 s**, no restart | Revoke-and-measure (D8) |

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
| **Information disclosure** | Key leaked via argv, logs, a ConfigMap or a host file. | Env or projected file from a Secret only (in cluster); a `0600` file owned by the service user on headless hosts (ADR-10); no flag; no default; redaction tests. | Anyone with `get secrets` in the namespace, or root on the host, can read it. |
| **Denial of service** | Invalid-key floods. | Constant-time compare over a fixed-length digest is cheap. | No rate limit in-cluster in Phase 1. |
| **Elevation of privilege** | A key reads or writes another tenant's data. | Reads tenant-scoped by key; `cross_tenant_read` only for the gateway. | The probe is a cross-tenant **writer** by design (it observes every tenant's pods), so its writes carry the tenant from operator config, not from the key. |

**Accepted risks and compensating controls (ADR-08):**

| Accepted risk | Rationale | Compensating controls |
| :---- | :---- | :---- |
| **Bearer key exfiltration** | Sender-constrained tokens (DPoP, client mTLS) add client dependencies a remote headless VM or log forwarder cannot carry. A bearer key is the deliberate trade. | (1) **Least-privilege scope**: the probe key is `observations:write` with cross-tenant write, so it cannot read anything; every other key is scoped to what its caller calls. (2) **Revocation without restart** (D8). (3) **Per-key rate limit** (D9). (4) **Per-key batch hash chain** (D10) detects replay and injection out of sequence. (5) **Expiry**: at most 90 days, with a warning 14 days out. |
| **No kernel-level caller attestation** | Without SPIRE, signal-ingest cannot attest the caller's PID or UID. | Containment never depends on API identity (ADR-09): the probe contains workloads through cgroup v2 and veth filters, whoever holds a key. |

**Containment versus API authentication (ADR-09, the L7/L3 decoupling):**

* **API identity plane (L7).** Remote sources send over HTTPS to the Envoy Gateway, which terminates TLS and forwards to signal-ingest. The same-cluster probe posts to signal-ingest's ClusterIP Service directly, in plain HTTP on the pod network (the residual stated under Tampering). signal-ingest checks the key in userspace.
* **Containment plane (L3/L4/cgroup).** The probe contains a workload through cgroup v2 freeze, host-veth TC drop filters and the gitops pin. None of it reads or needs an HTTP credential.
* **kTLS inspection is rejected.** Peeking at TLS payloads in kernel (`BPF_PROG_TYPE_SK_MSG` over kTLS) would need kTLS-enabled clients everywhere and buys nothing: containment never inspects an Authorization header.

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

**Definition of Done (Phase 1b):**

* An injected ingest outage loses no observation within the spool cap, and replay is ordered and idempotent (D7).
* A deleted key stops working within 90 s with no restart (D8).
* A flooding key gets 429 and does not starve another key (D9).
* A replayed or reordered batch is detected and audited, and a spool replay and an epoch restart are not flagged (D10).

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
| 2026-10-02 | AJM, Stefan Prodan | ADR-02 (draft, amended 2026-10-03): OpenBao as token authority. The 300 s TTL became 8-hour leases with a 4-hour sliding refresh | 300 s expiries lose telemetry across partitions, jitter and maintenance | **Deferred to Phase 2**: the probe gains nothing from it in-cluster, and reaching OpenBao from a remote probe is the cross-cluster dependency ADR-03 avoids. If Phase 2 starts, it uses 8 h/4 h |
| 2026-10-02 | AJM | **ADR-03: Phase 1 is a static, named, long API key per caller, header-only, verified in the probe's own cluster** | "keep inbound authentication as simple as possible … a bearer token with a long key … I specifically don't want the SPIRE server to run in the remote signal generating endpoint … cross-cluster auth could be complex, and we're trying to avoid that" | No SPIRE or OpenBao on the probe's path; one Secret per side; rotation is a script re-run |
| 2026-10-02 | AJM | **ADR-04: signal-ingest reads are tenant-scoped; the gateway acts for the user's tenant** | The review found signal-ingest's read handlers ignore tenancy, and fe-signalloom resolves the user's tenant and then never uses it (`signal_fusion.py` `get_observations`), so any dashboard user saw every tenant | Least privilege becomes real. The gateway forwards the verified user tenant, honoured only for a key holding `act_for_tenant`. Assumption, reversible by removing one grant: a superadmin's cross-tenant view is intended. |
| 2026-10-03 | AJM | **ADR-05: the same named static keys guard fleet-manager; dashboard mutations sit behind a login check** | fleet-manager's `/stun` and `/recover` had no caller authentication (`/recover` thawed every stunned agent); the dashboard forwarded browser tokens nobody verified | Per-caller keys (stun-sentinel and fe-signalloom: stun only; operator: everything). nginx `auth_request` to fe `GET /api/v1/auth/check` (superadmin) before injecting the dashboard key; the same gate covers every afm-platform mutation |
| 2026-10-03 | AJM | **ADR-06 (board phase P1): AFM reads the Kusari cluster's RBAC through a separate read-only exporter, not through the probe** | The probe is privileged and runs on every node; giving it cluster-wide RBAC read would put that credential on every node | A single unprivileged CronJob in the probe's bundle, own ServiceAccount, read-only ClusterRole (the four RBAC kinds, namespaces, service accounts; never Secrets), pushing to AFM with its own named key |
| 2026-10-03 | AJM | **ADR-07 (board phase P3): rename `stun-sentinel` to `signalloom-warden`** | "stun" names one action of a component whose main job is detection; "agent" collides with the AI agents it governs | `signalloom-warden` (watches and detains; unused in the repo), chosen by Andy at sign-off 2026-10-03 |
| 2026-10-03 | AJM, Andy Martin | **ADR-08: accept bearer-key exfiltration risk, with compensating controls** | DPoP or client mTLS add unacceptable client-side dependencies for remote VMs and log forwarders | Least-privilege scope, revocation without restart (D8), per-key rate limit (D9), per-key batch hash chain (D10), 90-day maximum lifetime. Redis CRL dropped: D8 needs no new infrastructure |
| 2026-10-03 | AJM, Andy Martin | **ADR-09: L7/L3 decoupling, with kTLS inspection rejected** | Kernel TLS inspection needs custom crypto bindings in every client, and containment never needs the payload | Auth in userspace at signal-ingest (behind Envoy TLS for remote sources); containment by cgroup v2 and veth filters |
| 2026-10-03 | AJM, Andy Martin | **ADR-10: on headless hosts the credential lives in a `0600` file, not `keyctl`** | Kernel keyrings vanish on systemd restarts and behave inconsistently under container seccomp | Phase 1: the static key in a `0600` file owned by the service user. Phase 2: the session and refresh tokens in the same file (`/var/lib/signalloom/session.json`). In cluster, Secrets stay the store |

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

## Second Draft Appraisal (2026-10-03)

Andy's 01:00 update was made to the original draft. Each change is weighed here against the code and ADR-03 (simple static keys, no cross-cluster auth).

| # | Change in the update | Verdict | Why | Where it landed |
| :---- | :---- | :---- | :---- | :---- |
| 1 | 8-hour session leases replace 300 s TTLs | **Agree, Phase 2** | 300 s does lose data across partitions. Phase 1 keys have no session to expire mid-partition | Phase 2 row; ADR-02 amended |
| 2 | Proactive sliding refresh at 4 h | **Agree, Phase 2** | Only meaningful with minted sessions | Phase 2 row |
| 3 | Local buffering across partitions of up to 8 h | **Agree, now** | Measured: the probe drops an observation when a dispatch fails, with no spool. This is a real evidence-loss gap regardless of token type | D7 (Phase 1b), KPI row |
| 4 | Credentials in a `0600` state file, `keyctl` rejected | **Agree, modified** | Right for headless hosts. In cluster, Secrets remain the store, so no node file holds a key | ADR-10 |
| 5 | Sub-second revocation through a Redis CRL | **Modify** | Revocation without restart is right, but Redis adds infrastructure and a dependency ADR-03 avoids. Re-reading the projected key directory gives ≤ 90 s with nothing new | D8, ADR-08 |
| 6 | `telemetry:write` scope | **Agree, already true** | The probe's key is `observations:write`, plus cross-tenant write because it observes every tenant | ADR-08 controls |
| 7 | Monotonic batch counters and hash chains | **Agree, modified** | Detects replay and reordering. It must accept a spool replay and a chain restart after a probe restart (an epoch), or D7 would trip it | D10 |
| 8 | Per-token ingress rate limits | **Agree, now** | Measured: signal-ingest has none. A per-key bucket stops one key starving another | D9 |
| 9 | Accept bearer exfiltration; reject DPoP and mTLS | **Agree** | Consistent with ADR-03; the residual is stated with its controls | ADR-08, accepted-risks table |
| 10 | L7/L3 decoupling; reject kTLS | **Agree, corrected** | Correct in principle. The update says all traffic crosses Envoy; the same-cluster probe does not (ClusterIP, plain HTTP), and that residual stays stated | ADR-09 |
| 11 | Press release and KPIs restored: SPIRE deletion, 650 MB, < 30 s onboarding, 0 hostPath mounts | **Disagree** | Still unmeasured, and SPIRE is still load-bearing (review findings 1, 9). They return when Phase 3 measures them | Withdrawn, unchanged |
| 12 | "Tokens never written to disk" next to a `0600` state file | **Disagree, contradictory** | The update states both. The STRIDE row now says exactly where a key lives | STRIDE information-disclosure row |
| 13 | ADR numbers 03–05 for the new decisions | **Renumbered** | ADR-03 to ADR-07 were already taken | ADR-08 to ADR-10 |

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
  Op->>K8s: write signal-ingest-key-stun-sentinel (fe-signalloom)
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

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `SLTM`
- Integration branch: `refs/heads/integration/sltm-v0.1.0`, cut from `feat/signal-loop-and-bootstrap-refactor` after every Phase 1 and SLDC fix branch is merged into it (Andy, sign-off 2026-10-03). No work has started on this board
- Target components: `d2-signalloom/apps/{signal-ingest,signalloom-stun-sentinel,stun-sentinel,fleet-manager,fe-signalloom,dashboard-signalloom}`, `d2-k8s-afm/`, `d2-signalloom/infra/agent-swarm/`
- Acceptance commands: `make test-sldc-offline`; `make test-sltm-probe-apikey`; `make test-e2e-containment-mutation-proof`; `SLTM_LIVE=1 make test-sltm-probe-apikey` and `make test-e2e-dual-cluster-containment` (live tiers: Governor cards only, never implementation cards)

#### Architectural constitution
- **One header, one key per caller.** Every inbound credential is a named static key: `Authorization: Bearer <key>`, at least 32 random bytes, a 90-day maximum lifetime, compared in constant time over SHA-256 digests, and verified by the service in the caller's own cluster. No SPIRE, JWT or token refresh at a signal source.
- **Keys live only in Secrets.** A value never appears in argv, a ConfigMap, git, a log line or an audit row. Its *name* is logged on every use. curl receives keys through 0600 header files.
- **Tenancy comes from operator configuration, never from the workload.** Probe attribution comes from `SENTINEL_TENANT_MAP` (namespace or namespace/serviceAccount); reads and writes are scoped to the key's tenant; an actor's tenant derives from all of its evidence.
- **Least privilege by default, read-only by construction.** Any new cluster reader gets its own ServiceAccount and only `get/list/watch` on the exact resources it needs. It never reads Secrets and is never the privileged probe.
- **Fail closed and loud.** A missing key disables only that caller and is logged; an audit store that is down refuses with 503; nothing fabricates success.

#### Wire contracts fixed for the board
- **Batch chain (D10):** request headers `X-SignalLoom-Batch-Epoch` (random per sender start), `X-SignalLoom-Batch-Seq` (from 1 within the epoch), `X-SignalLoom-Batch-Prev` (hex SHA-256 of the previous batch body in the epoch; empty for seq 1). The body contract is unchanged. Absent headers mean an unchained sender and are accepted.
- **Spool (D7):** `/var/lib/signalloom/spool` (hostPath, `0700` dir, `0600` files), bounded by `SIGNAL_INGEST_SPOOL_MAX_BYTES` and `SIGNAL_INGEST_SPOOL_MAX_AGE` (default 8h); a 429 `Retry-After` is honoured.
- **AFM import key:** named key `afm-importer`, scope `afm:import`, verified by fe-signalloom with `hmac.compare_digest` over SHA-256 digests, from a projected Secret.
- **Harness:** cards run on the `antigravity` harness, the one with subscription headroom at board creation (Codex throttled, Claude at 54% of its 5-hour window). `start-ready` may rebalance later.

#### Canonical locations
- `d2-signalloom/apps/signal-ingest/api/{static_bearer,static_keys}.go`: named-key verifier
- `d2-signalloom/apps/fleet-manager/callerauth.go`: the fleet-manager mirror of the same contract
- `scripts/sldc-ingest-bearer.sh`, `scripts/fleet-manager-caller-keys.sh`: issuers (stdin only, idempotent, `--rotate`)
- `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml`: the existing in-cluster RBAC export and its `afm-rbac-reader` ClusterRole, to reuse rather than reinvent
- `test/sltm-probe-apikey.bats`: the Phase 1 acceptance suite

#### Testing standards
- Failing test first. Every new assertion is mutation-proven (break the real line, see red, restore, see green), recorded one line per proof in the card's errata.
- Offline by default: `KUBECONFIG=/dev/null`. Live halves gate on `scripts/lib/live-gate.sh` (`SLDC_LIVE=1`, a real kubeconfig, `/readyz`). No offline run may create, delete or exec into anything on a cluster or node.
- No `|| true`, no `skip` on a missing system under test, no `! cmd` as an assertion in bats, no line-number pins, no early-exit reader under pipefail (`scripts/lint-pipefail-grep-q.sh`).
- A test never rewrites a tracked file; regeneration needs an explicit opt-in variable.

#### Anti-patterns
- Cross-cluster trust or credential mirroring.
- A default key or token compiled into a binary.
- Granting the privileged node probe any cluster-wide read.
- Renaming decision records (dated proposals, reports, evidence): they record a past state.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; ripwire | Baseline engineer | S | 45m | antigravity | Prove the board harness, the integration branch and the Phase 1 offline gate before any change. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Map AFM's import contract, its upload API and auth, and where the exporter ships in the probe bundle. |
| P1-1 | context-mode | Python API engineer | M | 120m | antigravity | AFM's backend lives outside this repo, so the key check sits in a fe-signalloom gateway route plus a NetworkPolicy. |
| P1-2 | context-mode | Kubernetes engineer | M | 120m | antigravity | A read-only exporter CronJob in the probe bundle; RBAC and PSS discipline matter more than code volume. |
| P1-GOV | ajm-auto-kanban | Governor | M | 90m | antigravity | Merge in order; run the live AFM import from the Kusari cluster once. |
| P2-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Map the probe's dispatch path, signal-ingest's key loader and router, and the hostPath and PSS constraints for an on-node spool. |
| P2-1 | context-mode | Go systems engineer | L | 180m | antigravity | The spool: bounded, ordered, idempotent replay, 0600 files, honours 429/Retry-After, never blocks detection or freeze (D7). |
| P2-2 | context-mode | Go API engineer | M | 120m | antigravity | Hot reload of the key directory with last-good fallback (D8) and per-key token buckets with 429 (D9). |
| P2-3 | context-mode | Go API engineer | M | 120m | antigravity | Per-key batch sequence and hash chain with epochs that tolerates spool replay (D10); sender and verifier sides. |
| P2-GOV | ajm-auto-kanban | Governor | M | 90m | antigravity | Live partition injection: no loss within the cap; revoke-and-measure ≤ 90 s. |
| P3-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Classify every `stun-sentinel` occurrence (1,323 in 275 files): identity-bearing, living doc, or decision record. |
| P3-1 | context-mode | Platform engineer | L | 180m | antigravity | The rename touches image, ServiceAccount, RBAC, labels, Flux path and event names; it needs a no-overlap cutover so two probes never freeze the same pod. |
| P3-2 | context-mode | Test engineer | M | 120m | antigravity | Rename tests and living docs; add a guard that fails on the old name outside an allow-list. |
| P3-GOV | ajm-auto-kanban | Governor | M | 90m | antigravity | Live cutover check: exactly one probe DaemonSet, Step 4 and Step 5 green, no orphaned RBAC. |
| P4-1 | context-mode | Go API engineer | S | 60m | antigravity | Actor IDs containing `//` are rejected on every `{id}` route; canonicalise or encode them. |
| P4-GOV | ajm-auto-kanban | Governor | S | 60m | antigravity | Final acceptance: every acceptance command, live tiers twice in a row. |

### Spec: Shared Patterns — Phase 1

#### P1 Wire Contract: Authenticated AFM Import Gateway
- **Inbound Route:** `POST /api/v1/afm/clusters/import` on `fe-signalloom` gateway and API.
- **Forwarding Destination:** `http://afm-platform.fe-k8s-afm.svc.cluster.local (port 8000)/clusters/import` (internal cluster Service).
- **Authentication Header:** `Authorization: Bearer <key>` (RFC 6750 Bearer token, minimum 32 random bytes).
- **Static Key Name:** `afm-importer`.
- **Required Scope:** `afm:import`.
- **Environment Configuration:** `AFM_IMPORT_KEYS` on `fe-signalloom` deployment containing a JSON-encoded array of authorized key definitions:
  `[{"name":"afm-importer","scopes":["afm:import"],"cluster":"kind-osramp"}]`
- **Verifier Secret (fe-signalloom):** `fe-signalloom/fe-signalloom-afm-importer-key`, projected as a volume mount at `/etc/fe-signalloom/afm-importer-key/`. Contains data keys `afm-importer` (raw token value) and `afm-importer.expires` (RFC 3339 expiration timestamp).
- **Consumer Secret (fe-signalloom-agents):** `fe-signalloom-agents/signalloom-rbac-exporter-afm-key`, projected as a volume mount into the exporter pod. Contains data key `token` (raw Bearer token value).
- **Key Issuer Script:** `scripts/afm-importer-key.sh` (generates the matching Secret pair for verifier and consumer namespaces).
- **Exporter Identity:** ServiceAccount `signalloom-rbac-exporter` and pod label `app.kubernetes.io/name: signalloom-rbac-exporter` in namespace `fe-signalloom-agents`.
- **Bound Cluster Attribution:** `kind-osramp`. In accordance with the architectural constitution ("Tenancy comes from operator configuration, never from the workload"), the verifier enforces that the payload's `id` field matches the cluster bound to the presented key.
- **Payload Schema:**
  ```json
  {
    "id": "kind-osramp",
    "name": "Local Cluster",
    "rbac": {
      "subjects": [
        {
          "kind": "User|ServiceAccount|Group",
          "name": "string",
          "namespace": "string (optional)"
        }
      ],
      "roles": [
        {
          "name": "string",
          "scope": "Cluster|Namespace",
          "namespace": "string (optional)",
          "rules": [
            {
              "verbs": ["string"],
              "apiGroups": ["string"],
              "resources": ["string"]
            }
          ]
        }
      ],
      "bindings": [
        {
          "name": "string",
          "scope": "Cluster|Namespace",
          "namespace": "string (optional)",
          "roleRef": "string",
          "subjects": [
            {
              "kind": "User|ServiceAccount|Group",
              "name": "string",
              "namespace": "string (optional)"
            }
          ]
        }
      ]
    }
  }
  ```
- **Payload Size Bound:** `AFM_IMPORT_MAX_BYTES` (default: `1048576` bytes / 1 MiB).
- **Digest Verification:** Constant-time comparison using `hmac.compare_digest` over SHA-256 digests (`hashlib.sha256(key.encode()).digest()`).
- **Refusal Status Codes and Error Bodies:**
  - Missing Authorization header: `401 Unauthorized` with `{"error": "missing_authorization_header"}`
  - Unknown or invalid Bearer key: `401 Unauthorized` with `{"error": "invalid_api_key"}`
  - Expired Bearer key: `401 Unauthorized` with `{"error": "key_expired"}`
  - Insufficient scope (missing `afm:import`): `403 Forbidden` with `{"error": "insufficient_scope"}`
  - Cluster ID mismatch (payload `id` differs from key binding): `403 Forbidden` with `{"error": "cluster_id_mismatch"}`
  - Payload size exceeds `AFM_IMPORT_MAX_BYTES`: `413 Payload Too Large` with `{"error": "payload_too_large"}`
  - Invalid JSON syntax or schema failure: `422 Unprocessable Entity` with `{"error": "invalid_payload_schema"}`
  - Downstream AFM connection failure or 5xx: `502 Bad Gateway` with `{"error": "upstream_afm_error"}`

#### File Ownership Split: Phase 1 Cards

| File / Subsystem Path | P1-1 (Gateway & Auth) | P1-2 (Exporter CronJob & RBAC) | Governance / Shared |
| :--- | :--- | :--- | :--- |
| `d2-signalloom/apps/fe-signalloom/src/**` | Sole Owner (implements `/api/v1/afm/clusters/import`, key loader, schema validation) | Read-only | — |
| `d2-signalloom/apps/fe-signalloom/base/deployment.yaml` | Sole Owner (mounts `/etc/fe-signalloom/afm-importer-key/`, configures `AFM_IMPORT_KEYS`) | Read-only | — |
| `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml` | Sole Owner (egress to `afm-platform` on port 8000, ingress from `fe-signalloom-agents`) | Read-only | — |
| `d2-signalloom/apps/dashboard-signalloom/nginx.conf` | Sole Owner (L7 403 on direct `/afm/clusters/import` browser upload path) | Read-only | — |
| `d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml` | Sole Owner (Envoy HTTPRoute L7 filter closing external `/clusters/import`) | Read-only | — |
| `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml` | Sole Owner (labels on in-namespace CronJob only) | Read-only | — |
| `scripts/afm-importer-key.sh` | Sole Owner (Secret generation script) | Read-only | — |
| `d2-signalloom/apps/fe-signalloom/src/tests/**` | Sole Owner (pytest suite for import route, auth gates, size limits) | Read-only | — |
| `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/**` | Read-only | Sole Owner (probe bundle base) | — |
| `d2-signalloom/infra/agent-swarm/signalloom-rbac-exporter/**` | Read-only | Sole Owner (exporter CronJob, config, ServiceAccount) | — |
| `d2-osramp-fleet/tenants/base/agent-swarm.yaml` | Read-only | Sole Owner (ClusterRole/Binding in ResourceSet, Secret sync) | — |
| `test/sltm-rbac-exporter.bats` | Read-only | Sole Owner (exporter manifest and mock push tests) | — |
| `Makefile` | Non-colliding target registration (line-distinct additions) | Non-colliding target registration (line-distinct additions) | — |
| `docs/Proposal — ... (2026-Q4).md` | Non-colliding errata appending | Non-colliding errata appending | Preflight / Governor |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | preflight | Validate SLTM harness identity and the Phase 1 baseline on the integration branch | None | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTM`; `make test-sldc-offline`; `make test-sltm-probe-apikey` | S | antigravity | pass (baseline measured; findings recorded) | — | — | — | — |
| P1-PRE | preflight | Inventory AFM's RBAC import contract, upload API and authentication, and the probe bundle's packaging | P0 | Written inventory with file:line citations for `cluster-import.yaml`, the afm-platform upload route and its auth | S | antigravity | pass (inventory written; wire contract pinned) | — | — | — | — |
| P1-1 | implementation | An authenticated AFM import gateway in this repo: fe-signalloom `POST /api/v1/afm/clusters/import` accepts only a named static key (`afm-importer`, scope `afm:import`, bound to one cluster) and forwards to afm-platform `/clusters/import`; afm-platform's NetworkPolicy then admits `/clusters/import` only from fe-signalloom and AFM's own in-cluster CronJob. The afm-platform backend is NOT in this repository (`d2-k8s-afm/AGENTS.md`), so it is not edited | P1-PRE | pytest per refusal path (no key, wrong key, wrong scope, oversized body); key not in argv or logs; NetworkPolicy render test; mutation proofs | M | antigravity | pass — delivered: `52fae47095a41f217d8300e23eb849cef850b12c` (see Errata — SLTM-P1-1) | — | — | — | — |
| P1-2 | implementation | A read-only RBAC exporter ships in the probe bundle as a separate unprivileged CronJob with its own ServiceAccount, pushing to AFM with its own key | P1-PRE | Rendered RBAC is exactly get/list/watch on clusterroles, clusterrolebindings, roles, rolebindings, namespaces, serviceaccounts and never secrets; restricted PSS; offline push against a fake AFM; mutation proofs | M | antigravity | pass — delivered: 24565a359600b3474e391059d85e41f1daa1895f (see Errata — SLTM-P1-2) | — | — | — | — |
| P1-GOV | governor | Merge P1 in order; one live import from the Kusari cluster appears in AFM with an attributed key name | P1-1, P1-2 | `make test-sldc-offline`; live AFM import check | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Inventory the probe's dispatch path, signal-ingest's key loader and router, and the spool's hostPath and PSS constraints | P1-GOV | Written inventory with file:line citations | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | The probe spools failed dispatches to a bounded on-node spool and replays them in order (D7), and stamps every batch with the D10 chain headers (`X-SignalLoom-Batch-Epoch`, `-Seq`, `-Prev`) | P2-PRE | Go tests: outage, restart, cap overflow, 401/403 not retried, Retry-After honoured; detection and freeze unaffected; mutation proofs | L | antigravity | — | — | — | — | — |
| P2-2 | implementation | signal-ingest reloads its key directory without a restart (D8) and rate-limits per key with 429 (D9) | P2-PRE | Go tests: delete, rotate, malformed update keeps the last good set; flood isolation; mutation proofs | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | signal-ingest verifies the D10 chain headers per key and audits gaps, replays and reordering; absent headers mean an unchained sender (a log forwarder) and are accepted and recorded, never refused | P2-PRE | Go tests: replay, reorder, gap, epoch restart, spool replay accepted; mutation proofs | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Merge P2; live partition injection loses nothing within the cap; a revoked key stops within 90 s | P2-1, P2-2, P2-3 | `SLTM_LIVE=1 make test-sltm-probe-apikey` extended with the partition and revoke cases | M | antigravity | — | — | — | — | — |
| P3-PRE | preflight | Classify every `stun-sentinel` occurrence and write the rename map and cutover plan | P2-GOV | Inventory table: occurrence class, file, new name; decision records excluded | S | antigravity | — | — | — | — | — |
| P3-1 | implementation | Rename the probe's image, ServiceAccount, RBAC, labels, ConfigMap, Flux path and event names to `signalloom-warden` with a no-overlap cutover | P3-PRE | Rendered-manifest tests; tenant map and fleet-manager caller key still resolve; mutation proofs | L | antigravity | — | — | — | — | — |
| P3-2 | implementation | Rename tests and living docs; a guard test fails on the old name outside an explicit allow-list | P3-PRE | Guard bats with a planted occurrence going red; docs-lint clean | M | antigravity | — | — | — | — | — |
| P3-GOV | governor | Merge P3; live cutover leaves exactly one probe DaemonSet and Steps 4–6 green | P3-1, P3-2 | `SLTM_LIVE=1 make test-sltm-probe-apikey`; `make test-e2e-dual-cluster-containment` | M | antigravity | — | — | — | — | — |
| P4-1 | implementation | Actor IDs containing `//` are readable on every `{id}` route | P3-GOV | Go tests per `{id}` route with a SPIFFE-derived ID; mutation proof | S | antigravity | — | — | — | — | — |
| P4-GOV | governor | Final acceptance: every acceptance command passes, live tiers twice in a row | P4-1 | All acceptance commands, two consecutive green runs with timestamps | S | antigravity | — | — | — | — | — |

### Spec: Errata

#### Errata — SLTM-P0

- **Logical ID:** P0
- **Created:** 2026-10-03 02:25:00+01:00
- **Last Updated:** 2026-10-03 02:25:00+01:00
- **Harness:** `antigravity`
- **Integration Branch:** `refs/heads/integration/sltm-v0.1.0` (`0273ae957cd37c39d18c9cdd8e1f7906ed056198`)
- **Feat Ancestor Branch:** `refs/heads/feat/signal-loop-and-bootstrap-refactor` (`0273ae957cd37c39d18c9cdd8e1f7906ed056198`)
- **Merge Base Check:** `git merge-base --is-ancestor refs/heads/feat/signal-loop-and-bootstrap-refactor refs/heads/integration/sltm-v0.1.0` -> `0` (clean ancestor, commit SHAs identical at `0273ae957cd37c39d18c9cdd8e1f7906ed056198`; worktree base at `e2e9db23e460a387aa6f46afbae27d96d8778444`)
- **HEAD SHA:** `e2e9db23e460a387aa6f46afbae27d96d8778444`

##### Baseline Acceptance Table

| Command | Exit Code | Result / Output Summary | Pass Condition & Findings |
| :--- | :--- | :--- | :--- |
| `bash scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTM` | 1 | 5 exceptions raised: missing `ajm-cline-kanban` script, Python permission error on `.kanban-review-ledger.json`, corrupt `.kagent-preflight-proof.json` | Script hardcodes legacy path `/home/andy/.andy_sync/confExt/skills/ajm-cline-kanban/Tools/kanban-check.sh` (renamed to `ajm-auto-kanban`), checks `.kagent-preflight-proof.json` from Kagent board, and hits nono sandbox denial on `/home/andy/src/cp/osramp-demo/.kanban-review-ledger.json`. Baseline defect recorded. |
| `make test-sltm-probe-apikey` | 0 | `1..17`: 10 ok, 7 skip, 0 not ok | 10 offline tests against real `signal-ingest` binary pass (1..10); 7 live tests (11..17) skip with `live tier: set SLTM_LIVE=1 and a real KUBECONFIG`. Zero failures. |
| `make test-sldc-offline` | 2 | TAP: 616 ok, 1 not ok, 40 skip; Go: 48 packages ok; Pytest: 90 passed + 108 passed; Bun: 43 pass; FrostDB: ok | `test/p1-sentinel-preflight.bats` test 1 fails under nono sandbox because `/sys/fs/cgroup/cgroup.controllers` is unreadable without docker fallback (docker is stubbed to exit 1). Baseline finding recorded. |
| `make test-e2e-containment-mutation-proof` | 0 | `1..35`: 35 ok, 0 not ok (`# mutations proven: 35/35`) | All 35 containment mutation assertions proven against offline fixtures. |
| `bash scripts/lint-pipefail-grep-q.sh` | 0 | `lint-pipefail-grep-q: SCANNED CLEAN: 637 files` | 637 files scanned, zero unmarked early-exit readers under pipefail. |
| `bash scripts/check-vacuous-assertions.sh test` | 1 | 15 pre-existing findings + `allowlist no longer describes this tree` | Pre-existing baseline recorded (VAC003, VAC005, VAC006 across 274 test files). |

##### Acceptance Target Resolution List

| Target | Makefile Line | `make -n` Resolution | Live/Offline Policy |
| :--- | :--- | :--- | :--- |
| `test-sltm-probe-apikey` | `Makefile:1031` | `rc=0` | Offline by default; `SLTM_LIVE=1` adds live tier |
| `test-sldc-offline` | `Makefile:1149` | `rc=0` | Offline only (`KUBECONFIG=/dev/null`) |
| `test-e2e-containment-mutation-proof` | `Makefile:1113` | `rc=0` | Offline only |
| `test-e2e-dual-cluster-containment` | `Makefile:1110` | `rc=0` | Live tier (resolved only, never run in implementation cards) |

##### Live Gate Protocol Distinction
`test/sltm-probe-apikey.bats:188-189` gates its live tier on `SLTM_LIVE=1` plus a non-`/dev/null` `KUBECONFIG` (`live_or_skip`), whereas `scripts/lib/live-gate.sh:22-30` gates on `SLDC_LIVE=1`. Governor cards (P1-GOV, P2-GOV, P3-GOV, P4-GOV) must supply `SLTM_LIVE=1` and a valid cluster kubeconfig to open the Kusari live probe tier.

##### Non-Interference and Conflict Audit
- `git status --porcelain` before and after offline test execution: clean (byte-identical empty diff).
- `docker ps` before and after: clean (no container or kind node restarts).
- Tracked file conflict markers (`git grep -nE '^(<<<<<<<|>>>>>>>|=======$)' -- ':!*.md'`): clean (0 occurrences).

##### T8 Mutation Bite Proof
- **File:** `d2-signalloom/apps/signal-ingest/api/static_bearer.go` line 293
- **Mutation:** Replaced `if hmac.Equal(presented[:], a.keys[i].digest[:]) {` with `_ = hmac.Equal(presented[:], presented[:]); if true {` inside a throwaway export directory (`/tmp/p0-mut`) created with `git archive HEAD`.
- **Bite Evidence:** Running `KUBECONFIG=/dev/null bats --tap test/sltm-probe-apikey.bats` failed with exit code 1 on test 3 (`offline: a wrong key, a prefix, a suffix and a padded key are each 401`, accepted bad key with 201) and test 6 (`offline: an expired key is 401`), proving test sensitivity. The throwaway directory was removed immediately.

##### Adversarial Executions
1. `SLTM_LIVE=1 KUBECONFIG=/dev/null bats --tap test/sltm-probe-apikey.bats`: 10 ok, 7 skip with reason `live tier: set SLTM_LIVE=1 and a real KUBECONFIG`. Zero cluster contacts occurred.
2. `KUBECONFIG=/dev/null make -n test-sldc-offline`: Dry run executed zero commands and produced zero files.
3. `scripts/lint-pipefail-grep-q.sh`: Planted defect test triggered warning on unhandled pipefail early-exit.

##### Toolchain Versions
- Go: `go version go1.26.2 linux/amd64`
- Bats: `Bats 1.13.0`
- Python: `Python 3.14.4`
- Bun: `1.4.0`
- uv: `uv 0.5.10`

##### Lead adjudication (controller tick #7, 2026-10-03 02:44:09+01:00)

- **Commit:** `d775cb93`
- **Last Updated:** 2026-10-03 02:44:09+01:00
- The antigravity session committed this block and then sat at its prompt for more than 16 minutes without writing the machine tag or exiting, twice (9beb6, then 4283e). The lead read the acceptance table, found that it measures the baseline P0 asked for, and adjudicated **pass**.
- Recorded findings are for P1-PRE and the governor: `doctor` rc=1 (legacy `ajm-cline-kanban` helper path, Kagent proof file, sandbox denial on the ledger); `p1-sentinel-preflight.bats` test 1 fails under nono because it cannot read the cgroup file; the `TestDenialMatrix` wall-clock flake is being fixed by the estate-reds sweep. None of these blocks P1.

#### Errata — SLTM-P1-PRE

- **Logical ID:** P1-PRE
- **Created:** 2026-10-03 03:25:38+01:00
- **Last Updated:** 2026-10-03 03:25:38+01:00
- **Harness:** `antigravity`
- **Integration Branch:** `refs/heads/integration/sltm-v0.1.0` (`c2dc49dffb3aa0fec8c26621a9a1b22c29dcbd12`)
- **Feat Ancestor Branch:** `refs/heads/feat/signal-loop-and-bootstrap-refactor` (`c2dc49dffb3aa0fec8c26621a9a1b22c29dcbd12`)
- **Merge Base Check:** `git merge-base --is-ancestor refs/heads/integration/sltm-v0.1.0 HEAD` -> `0` (clean ancestor)
- **Worktree Base:** `/home/andy/src/.worktrees/cef59/osramp-demo`
- **HEAD SHA:** `c2dc49dffb3aa0fec8c26621a9a1b22c29dcbd12`

##### 1. AFM RBAC Import Contract Inventory

The import contract of record is defined in `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml` (`convert()` function, `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:135` and `scripts/rbac-to-afm.py:14`). The backend implementation lives outside this repository (`d2-k8s-afm/AGENTS.md:8`), so the in-repo client defines the wire contract.

| JSON Field | Type | Description | Source Line in `cluster-import.yaml` |
| :--- | :--- | :--- | :--- |
| `id` | `string` | Caller-supplied cluster identifier (e.g. `local` or `kind-osramp`) | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:198` |
| `name` | `string` | Human-readable cluster display name (e.g. `Local Cluster`) | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:199` |
| `rbac` | `object` | Container object for extracted subjects, roles, and bindings | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:200` |
| `rbac.subjects` | `list[object]` | Deduplicated list of subjects: `{name: string, kind: string, namespace?: string}` | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:201` |
| `rbac.roles` | `list[object]` | Exported roles: `{name: string, scope: "Cluster"|"Namespace", namespace?: string, rules: list[{verbs: list[string], apiGroups: list[string], resources: list[string]}]}` | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:202` |
| `rbac.bindings` | `list[object]` | Exported bindings: `{name: string, scope: "Cluster"|"Namespace", namespace?: string, roleRef: string, subjects: list[{name: string, kind: string, namespace?: string}]}` | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:203` |

**Key Properties of the Current In-Repo Exporter:**
- **Inbound HTTP Request:** The CronJob executes `POST` to `AFM_IMPORT_URL` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:71` / `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:232`) with only `headers={'Content-Type': 'application/json'}` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:235`). It sends **no authentication credential** of any kind.
- **API Token Usage:** The Kubernetes ServiceAccount token (`/var/run/secrets/kubernetes.io/serviceaccount/token`, `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:215`) is used solely to authenticate against the local Kubernetes API server (`https://{host}:{port}`, `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:220`), never against AFM.
- **Resource Scope:** `collect()` queries only four resource kinds: `clusterroles`, `clusterrolebindings`, `roles`, `rolebindings` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:102`), although the `afm-rbac-reader` ClusterRole also grants `namespaces` and `serviceaccounts` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:21`).
- **Error Handling:** `collect()` catches `Exception as exc` per resource, logs `WARNING: failed to list {resource}: {exc}` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:124`), and if partial, logs `WARNING: partial collection` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:130`) and posts the partial dataset as if complete.
- **Verbs:** Verbs granted are strictly `get` and `list` (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:20`, `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:23`). `watch` is NOT granted.
- **Security Context:** `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml` contains no `securityContext` specification on pod or container.

##### 2. Reachability Matrix for afm-platform (Port 8000)

> **L4 Policy Limitation:** Kubernetes NetworkPolicy operates at Layer 4 (IP, protocol, port) and cannot filter by HTTP path or method; afm-platform itself has no ingress NetworkPolicy (`d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml:95`).

| Path / Route | Proxy / Ingress Component | Match Rule | Authentication Mechanism | Citation | Risk / Exposure |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Gateway Route | Envoy Gateway (`cluster/ingress`) | `Host: afm.osramp.acme.local`, `PathPrefix: /` | **None** (unauthenticated public ingress) | `d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml:18` | **CRITICAL:** Unauthenticated external actors can directly POST to `/clusters/import` through the gateway. |
| Dashboard Proxy `/afm/` | Dashboard nginx | `location /afm/` -> `rewrite ^/afm(/.*) $1 break;` -> `proxy_pass http://afm-platform... (port 8000)` | `auth_request /_afm_gate` (Dex superadmin token check on mutating verbs) | `d2-signalloom/apps/dashboard-signalloom/nginx.conf:130` | Valid superadmin Dex tokens can POST unauthenticated imports directly to AFM backend without static key attribution. |
| Dashboard Proxy `/clusters` | Dashboard nginx | `location /clusters` -> `proxy_pass http://afm-platform... (port 8000)` | `auth_request /_afm_gate` (Dex superadmin token check on mutating verbs) | `d2-signalloom/apps/dashboard-signalloom/nginx.conf:140` | Proxies directly to AFM cluster store for iframed frontend. |
| API Server-Side | `fe-signalloom-api` backend (`rbac_correlation.py`) | Internal HTTP client to `AFM_BASE_URL` | None (internal cluster DNS) | `d2-signalloom/apps/fe-signalloom/src/rbac_correlation.py:84` | Read-only server-side correlation queries (`GET /clusters/{id}/...`). |
| In-Namespace CronJob | `afm-cluster-import` CronJob pod | Direct connection to `afm-platform.fe-k8s-afm.svc.cluster.local (port 8000)/clusters/import` | None (plain HTTP) | `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:71` | In-cluster cronjob posting cluster RBAC snapshot unauthenticated. |

##### 3. Probe Bundle Packaging & Flux Inventory

- **Canonical Base:** `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/` contains `kustomization.yaml`, `service-account.yaml` (declaring SA `stun-sentinel`), `rbac.yaml` (declaring namespaced Role/RoleBinding `stun-sentinel`), `configmap.yaml` (declaring `stun-sentinel-config`), and `daemonset.yaml` (declaring DaemonSet `stun-sentinel`).
- **Cluster Overlays:** `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel-overlays/kind-osramp/` and `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel-overlays/kind-signalloom-hub/` supply per-cluster image repository transformations and ingest URLs.
- **Flux Fleet Kustomization:** Declared in `d2-osramp-fleet/tenants/base/agent-swarm.yaml:552` as `Kustomization` `agent-signalloom-stun-sentinel` in namespace `fe-signalloom-agents`.
  - ServiceAccount: `serviceAccountName: agent-swarm-flux` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:562`).
  - Path: `path: ./signalloom-stun-sentinel-overlays/kind-osramp` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:574`).
  - DependsOn: `dependsOn: [{name: agent-swarm-base}]` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:561`).
- **Parent Kustomization:** `d2-signalloom/infra/agent-swarm/kustomization.yaml` reconciles namespace `fe-signalloom-agents`, base agents, and network policies.
- **Namespace & PSS Gap:** `d2-signalloom/infra/agent-swarm/namespace.yaml:8` defines `fe-signalloom-agents` with labels `signalloom.ai/managed: "true"`, `signalloom.ai/tier: "agents"`, `app.kubernetes.io/part-of: signalloom-swarm` (`d2-signalloom/infra/agent-swarm/namespace.yaml:12`). It has **no** `pod-security.kubernetes.io/enforce` label.
- **Namespace Default-Deny:** `d2-signalloom/infra/agent-swarm/networkpolicy.yaml:15` defines `NetworkPolicy` `default-deny` in `fe-signalloom-agents` (`d2-signalloom/infra/agent-swarm/networkpolicy.yaml:18`) with `podSelector: {}` selecting all pods and isolating both `Ingress` and `Egress`.

##### 4. Evidence-Backed Design Recommendations (P1-PRE-1 .. P1-PRE-5)

- **P1-PRE-1 (L7 Closure of `/clusters/import`):**
  - *Recommendation:* Enforce Layer 7 rejection of direct `/clusters/import` traffic at the ingress boundary by configuring an Envoy Gateway `HTTPRouteFilter` with `directResponse` returning status `403 Forbidden` for path `/clusters/import` on `afm.osramp.acme.local` (Envoy Gateway v1.8.2 pinned in `d2-infra/components/ingress/controllers/base/envoy-gateway.yaml:12`), combined with an explicit `return 403;` in dashboard nginx for direct `/afm/clusters/import` and `/clusters/import`.
  - *Evidence:* NetworkPolicy is L4 and cannot distinguish `/clusters/import` from `/clusters` or `/health`. `gateway-route.yaml` currently forwards `PathPrefix /` unauthenticated (`d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml:24`).
  - *Owner:* Card P1-1.
- **P1-PRE-2 (Exporter ClusterRole and Binding Placement):**
  - *Recommendation:* Place the exporter's cluster-scoped `ClusterRole` and `ClusterRoleBinding` inside the ResourceSet (`d2-osramp-fleet/tenants/base/agent-swarm.yaml`), NOT inside the tenant bundle deployed by `agent-swarm-flux`.
  - *Evidence:* `agent-swarm-flux` has only a namespaced `RoleBinding` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:123`). Its cluster-scoped RBAC grant was deliberately removed (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:129`) to preserve tenant least-privilege. Attempting to deploy cluster-scoped RBAC through `agent-swarm-flux` fails `test/agent-swarm-flux-rbac.bats` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:136`).
  - *Owner:* Card P1-2.
- **P1-PRE-3 (Exporter Image Selection):**
  - *Recommendation:* Run the exporter under an immutable, non-root, Python 3-capable image (e.g. `python:3.12-slim` or distroless python published to the local Zot registry), NEVER `kubesec-afm:latest`.
  - *Evidence:* `kubesec-afm:latest` carries the full FastAPI/Z3 model-checking platform and runs as root by default (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:64`). The exporter is a lightweight batch script that only requires Python 3 standard library (`urllib.request`, `json`, `ssl`).
  - *Owner:* Card P1-2.
- **P1-PRE-4 (PINNED Identity, Secret, and Key Names):**
  - *Recommendation:* Strictly pin the identity, Secret, and key names across the gateway verifier and exporter consumer:
    - Environment variable on fe-signalloom: `AFM_IMPORT_KEYS=[{"name":"afm-importer","scopes":["afm:import"],"cluster":"kind-osramp"}]`
    - Verifier Secret: `fe-signalloom/fe-signalloom-afm-importer-key` (projected data keys: `afm-importer`, `afm-importer.expires`)
    - Consumer Secret: `fe-signalloom-agents/signalloom-rbac-exporter-afm-key` (projected data key: `token`)
    - Issuer Script: `scripts/afm-importer-key.sh`
    - Exporter ServiceAccount and pod label: `signalloom-rbac-exporter`
    - Scope: `afm:import`
    - Bound Cluster ID: `kind-osramp`
  - *Evidence:* Ensures P1-1 and P1-2 develop in parallel against an immutable contract without wire divergence.
  - *Owner:* P1-1 (verifier & issuer) and P1-2 (consumer Secret projection & SA).
- **P1-PRE-5 (Dashboard Browser Upload Path Resolution):**
  - *Recommendation:* Close the dashboard browser POST to `/afm/clusters/import` (`d2-signalloom/apps/dashboard-signalloom/src/api/afmApi.ts:475` through `d2-signalloom/apps/dashboard-signalloom/nginx.conf:130`) with an immediate `403 Forbidden` refusal.
  - *Evidence:* Architectural constitution mandates: "One header, one key per caller... Every inbound credential is a named static key". The browser client possesses only a Dex superadmin JWT and has no static API key. Closing this path breaks manual browser uploads in the UI panel (recorded as known operational tradeoff). Any override must be recorded in the Governor log before P1-1 starts.
  - *Owner:* Card P1-1.

##### 5. Required Tests & Evidence Verification (T1 .. T8)

| Test ID | Objective | Command Executed | Result / Evidence | Status |
| :--- | :--- | :--- | :--- | :--- |
| **T1** | AFM Base Render & RBAC Rules | `KUBECONFIG=/dev/null kubectl kustomize d2-k8s-afm/apps/afm-platform/base > /tmp/sltm-p1-pre/afm-base.yaml && yq -o=json -I0 'select(.kind=="ClusterRole" and .metadata.name=="afm-rbac-reader") \| .rules' /tmp/sltm-p1-pre/afm-base.yaml` | Output: `[{"apiGroups":["rbac.authorization.k8s.io"],"resources":["clusterroles","clusterrolebindings","roles","rolebindings"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["namespaces","serviceaccounts"],"verbs":["get","list"]}]`. Exactly two rules; `watch` verb is NOT granted (`d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:17`). | **PASS** |
| **T2** | AFM Ingress Exposure Positive Control | `yq 'select(.kind=="NetworkPolicy") \| .metadata.name' /tmp/sltm-p1-pre/afm-base.yaml` AND `yq '.kind' /tmp/sltm-p1-pre/afm-base.yaml \| sort \| uniq -c` | Output: 0 NetworkPolicies. Positive control kinds: 1 ClusterRole, 1 ClusterRoleBinding, 1 CronJob, 1 Deployment, 1 HTTPRoute, 1 Namespace, 1 Service, 1 ServiceAccount. Cross-cites `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml:93`. | **PASS** |
| **T3** | Probe Bundle Render & Packaging | `KUBECONFIG=/dev/null kubectl kustomize d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel > /tmp/sltm-p1-pre/probe-bundle.yaml && yq '.kind + "/" + .metadata.namespace + "/" + .metadata.name' /tmp/sltm-p1-pre/probe-bundle.yaml` | Output: `ServiceAccount/fe-signalloom-agents/stun-sentinel`, `Role/fe-signalloom-agents/stun-sentinel`, `RoleBinding/fe-signalloom-agents/stun-sentinel`, `ConfigMap/fe-signalloom-agents/stun-sentinel-config`, `DaemonSet/fe-signalloom-agents/stun-sentinel`. Zero ClusterRoles rendered. | **PASS** |
| **T4** | Existing Offline Test Suites | `KUBECONFIG=/dev/null bats --tap d2-k8s-afm/test/afm-converter.bats test/k8s-afm-preflight.bats` AND `KUBECONFIG=/dev/null bats --tap test/agent-swarm-tenancy.bats test/agent-swarm-flux-rbac.bats d2-signalloom/test/stun-sentinel-daemonset.bats` | Suite 1: 23 ok / 23 tests (12 + 11 ok). Suite 2: 18 ok / 18 tests (4 + 3 + 11 ok). Total: 41 ok, 0 not ok, 0 skip. | **PASS** |
| **T5** | Upload Contract Derived from Code | `python3 -c "import importlib.util,json; s=importlib.util.spec_from_file_location('m','scripts/rbac-to-afm.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); d=m.convert(json.load(open('d2-k8s-afm/test/fixtures/osramp-cluster-rbac.json'))); print(sorted(d.keys())); print(sorted(d['rbac'].keys()))"` | Top-level keys: `['id', 'name', 'rbac']`. RBAC keys: `['bindings', 'roles', 'subjects']`. In-repo senders: `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:232` (CronJob) and `d2-signalloom/apps/dashboard-signalloom/src/api/afmApi.ts:475` (Dashboard) both send unauthenticated POSTs. | **PASS** |
| **T6** | Citation Resolution Check | `/tmp/sltm-p1-pre/verify_citations.sh` and `/tmp/sltm-p1-pre/test_t6.sh` | Output: `0 MISSING` across all cited file:line references. | **PASS** |
| **T7** | Non-Interference & Docs-Lint | `git status --porcelain` before/after; `git diff integration/sltm-v0.1.0...HEAD --stat`; `KUBECONFIG=/dev/null make docs-lint` | Git diff strictly scoped to proposal document; `make docs-lint` exits 0 (Proposal covered under `RECORDS` pattern in `scripts/docs-lint.sh:45`). | **PASS** |
| **T8** | Same-Cluster Deployment Topology | Manifest analysis of `scripts/k8s-afm.sh:184`, `infra/kind/cluster-osramp.yaml:29`, `infra/kind/cluster-signalloom-hub.yaml:27`, `d2-osramp-fleet/tenants/base/agent-swarm.yaml:574` | AFM (`fe-k8s-afm`) deploys only to `kind-osramp` (the Kusari cluster). `kind-signalloom-hub` runs no `fe-k8s-afm`. Exporter -> fe-signalloom gateway -> afm-platform is strictly same-cluster. | **PASS** |

##### 6. Adversarial Verification & Gap Proof

1. **Adversarial Citation Audit:**
   To re-verify every citation in this inventory, execute:
   ```bash
   while IFS=: read -r p l; do
     if [ ! -f "$p" ] || [ -z "$(sed -n "${l}p" "$p")" ]; then
       echo "MISSING: $p:$l"
     fi
   done < <(rg -o '[A-Za-z0-9_./-]+:[0-9]+' <(git diff integration/sltm-v0.1.0...HEAD -- 'docs/Proposal*.md') | grep '/' | sort -u)
   ```
2. **Absence Claims Evidenced by Positive Controls:**
   - Absence of NetworkPolicy in `d2-k8s-afm`: Confirmed by `rg "kind:\s*NetworkPolicy" d2-k8s-afm/` returning 0 lines, while `kubectl kustomize d2-k8s-afm/apps/afm-platform/base` renders 8 distinct Kubernetes resources (Deployment, Service, CronJob, ClusterRole, ClusterRoleBinding, ServiceAccount, Namespace, HTTPRoute).
   - Absence of Authorization Header in Exporter POST: Confirmed by inspection of `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml:235` (`headers={'Content-Type': 'application/json'}`).
   - External Backend Source: Confirmed by `d2-k8s-afm/AGENTS.md:8` (`The backend source is not in this repository. It is in the separate kubesec-afm checkout.`).
3. **The Failing Gap Request (Red-to-Green Baseline for P1-1):**
   With the current manifests, sending an unauthenticated HTTP request:
   ```http
   POST /clusters/import HTTP/1.1
   Host: afm.osramp.acme.local
   Content-Type: application/json

   {"id": "test-cluster", "name": "Test", "rbac": {"subjects": [], "roles": [], "bindings": []}}
   ```
   matches the `PathPrefix /` rule on `afm-platform` HTTPRoute (`d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml:23`) and is routed directly to `afm-platform` port 8000 without requiring an API key. P1-1 will turn this failing case green by enforcing Layer 7 rejection on `/clusters/import` at the gateway and directing authenticated imports through `fe-signalloom` `POST /api/v1/afm/clusters/import`.

#### Errata — SLTM-P1-1

- **Logical ID:** P1-1
- **Commit:** `52fae470` (`52fae47095a41f217d8300e23eb849cef850b12c`)
- **Created:** 2026-10-03 03:50:00+01:00
- **Last Updated:** 2026-10-03 04:18:00+01:00
- **Harness:** `antigravity`
- **Integration Branch:** `refs/heads/integration/sltm-v0.1.0` (base ref: `3f594d3e8e19bbff9a7c3664d6eb2be1c7fa15f7`)
- **HEAD SHA:** `52fae47095a41f217d8300e23eb849cef850b12c`

##### Failing-First Summary
Failing test suites were authored and committed first in `ec12d405`:
- `d2-signalloom/apps/fe-signalloom/src/tests/test_afm_import_gateway.py`: 33 pytest cases testing all refusal paths (missing auth header, non-Bearer schemes, invalid tokens, prefix/suffix/padded tokens, whitespace/blank keys, missing `afm:import` scope, oversized bodies via Content-Length or streaming, non-JSON or invalid schema bodies, cluster ID mismatches, expired/invalid key files) and forwarding paths (fake upstream passthrough, upstream 5xx/timeout/connect errors, key redaction in logs/headers).
- `test/afm-import-gateway-manifests.bats`: 6 offline manifest test cases covering AFM base NetworkPolicy (4 exact ingress peers), HTTPRoute directResponse 403 filter, CronJob pod template component label, fe-signalloom projected Secret volume (0440 mode) & env `AFM_IMPORT_KEYS`, fe-signalloom NetworkPolicy `allow-rbac-exporter-ingress` on TCP 8000, and dashboard `nginx.conf` 403 regex closure.
- `test/afm-importer-key.bats`: 8 bats tests covering key issuer CLI contract, context requirement, stdout/stderr/argv secrecy, idempotency, rotation, and failure modes.

##### Delivered Components & Architecture Summary
1. **Authenticated Import Gateway Router (`afm_import.py`)**:
   - Prefix `/api/v1/afm`, route `POST /clusters/import`, wired in `d2-signalloom/apps/fe-signalloom/src/main.py`.
   - Dynamic key loader reading `$AFM_IMPORT_KEYS` and `$AFM_IMPORTER_KEY_DIR/<name>` + `<name>.expires`.
   - Constant-time token verification using `hmac.compare_digest` over SHA-256 digests against every configured key (no early loop termination).
   - Strict body streaming byte cap: `AFM_IMPORT_MAX_BYTES = 8388608` (`d2-signalloom/apps/fe-signalloom/src/afm_import.py:27`).
   - Timeout configuration: `AFM_TIMEOUT_S = 20.0` (`d2-signalloom/apps/fe-signalloom/src/afm_import.py:30`).
   - Audit logging via `_audit_outbound_request` (`afm.cluster_import_requested`, detail `{key, cluster_id, bytes}`, tenant `system`, subject `key:afm-importer`).
   - Forwarder passes raw payload with `Content-Type: application/json` only; inbound `Authorization` header is never forwarded upstream.
2. **Database Migration & Bootstrap**:
   - `050_afm_cluster_import_event_type.sql` added to widen `audit_events.event_type` CHECK list with `afm.cluster_import_requested`.
   - Discovery portal bootstrap files regenerated; `make -C d2-signalloom bootstrap-drift` passes with 0 drift.
3. **Layer 3/4 & Layer 7 Route Closures**:
   - `d2-k8s-afm/apps/afm-platform/base/networkpolicy.yaml`: TCP 8000 ingress limited strictly to 4 peers (`fe-signalloom`, `dashboard-signalloom`, `ingress` gateway proxy, in-namespace `cluster-import` CronJob).
   - `d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml`: ExtensionRef to `HTTPRouteFilter` (`gateway.envoyproxy.io/v1alpha1`) with `directResponse.statusCode: 403` on exact `/clusters/import` and PathPrefix `/clusters/import/`.
   - `d2-signalloom/apps/dashboard-signalloom/nginx.conf:131`: `location ~ ^/(afm/)?clusters/import(/|$) { return 403; }` closes manual browser uploads with 403 as determined in P1-PRE-5.
   - `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml`: Pod template labeled `app.kubernetes.io/component: cluster-import`.
4. **fe-signalloom Deployment & Ingress NetworkPolicy**:
   - `base/deployment.yaml`: Configured env `AFM_IMPORT_KEYS` and projected secret volume `fe-signalloom-afm-importer-key` (defaultMode 0440, optional).
   - `base/networkpolicy.yaml`: Added `allow-rbac-exporter-ingress` on TCP 8000 from namespace `fe-signalloom-agents` / pod label `signalloom-rbac-exporter`.
5. **Key Issuer Tooling (`scripts/afm-importer-key.sh`)**:
   - Mints verifier Secret (`fe-signalloom/fe-signalloom-afm-importer-key`) and consumer Secret (`fe-signalloom-agents/signalloom-rbac-exporter-afm-key`).
   - Requires `--context <ctx>`, supports `--rotate` and stdin piping, never exposes key material in argv, logs, stdout, or stderr.

##### Role & RoleBinding Boundary Assertion
- Manifest evaluation confirms no Role or RoleBinding in `fe-signalloom-agents` grants `secrets` get, list, or watch to any agent ServiceAccount.

##### Mutation Proofs (11/11 Proven RED -> GREEN)
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` scope check removed -> `test_other_scope_key_is_403_and_nothing_forwarded` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` constant-time compare replaced with == -> `test_digest_compare_is_constant_time` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` bound cluster check bypassed -> `test_body_cluster_id_mismatch_is_403` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` body size limit cap removed -> `test_oversized_body_is_413` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` inbound Authorization header forwarded upstream -> `test_valid_import_is_forwarded_once_with_the_bound_cluster` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` presented token leaked in logs -> `test_key_value_never_logged_and_name_always_logged` RED; restored -> GREEN
- MUT `d2-signalloom/apps/fe-signalloom/src/afm_import.py` whitespace key check bypassed -> `test_missing_empty_or_blank_key_file_disables_route` RED; restored -> GREEN
- MUT `d2-k8s-afm/apps/afm-platform/base/networkpolicy.yaml` NetworkPolicy from peer widened -> `afm-import-gateway-manifests: NetworkPolicy selects afm-platform and admits exactly the four expected ingress peer blocks` RED; restored -> GREEN
- MUT `d2-k8s-afm/apps/afm-platform/base/gateway-route.yaml` HTTPRouteFilter status changed from 403 to 200 -> `afm-import-gateway-manifests: HTTPRoute directResponse 403 filters /clusters/import and /clusters/import/` RED; restored -> GREEN
- MUT `scripts/afm-importer-key.sh` key value leaked to stdout in issuer -> `afm-importer-key: key value never appears in argv, stdout, or stderr` RED; restored -> GREEN
- MUT `d2-signalloom/apps/dashboard-signalloom/nginx.conf` nginx closure regex location altered -> `afm-import-gateway-manifests: dashboard nginx.conf closes /clusters/import and /afm/clusters/import with 403` RED; restored -> GREEN

##### Test Execution Metrics
- `d2-signalloom/apps/fe-signalloom/src/tests/test_afm_import_gateway.py`: 33 passed, 0 failed (0.94s)
- `test/afm-import-gateway-manifests.bats`: 6 passed, 0 failed
- `test/afm-importer-key.bats`: 8 passed, 0 failed
- `test/phase1-governor-verification.bats`: 7 passed, 0 failed
- Regression suites:
  - Ingest proxies & RBAC correlation (`fe-signalloom` pytest): 408 passed, 0 failed
  - AFM preflight & converter bats: 23 passed, 0 failed
  - Tenant hash cross-language vectors (bun): 43 passed, 0 failed
  - Bootstrap drift (`make -C d2-signalloom bootstrap-drift`): 0 diff, clean exit
  - Whitespace check (`git diff --check`): clean (0 errors)
  - Pipefail lint (`scripts/lint-pipefail-grep-q.sh`): SCANNED CLEAN (641 files)

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->


#### Errata — SLTM-P1-2 A read-only RBAC exporter ships in the probe bundle as a separate unprivileged CronJob with its own ServiceAccount, pushing to AFM with its own key
**Created:** 2026-10-03 04:27:01+01:00
**Last Updated:** 2026-10-03 04:27:01+01:00
**Status:** Completed
**Commit:** 24565a359600b3474e391059d85e41f1daa1895f
**Governor merge:** [pending Governor reconciliation]
**Decisions:**
- Placed ClusterRole and ClusterRoleBinding `signalloom-rbac-exporter` in ResourceSet `d2-osramp-fleet/tenants/base/agent-swarm.yaml` rather than the Flux-applied bundle, because `agent-swarm-flux` lacks cluster-scoped RBAC creation permissions (P1-PRE-2).
- Pinned CronJob container image to `python:3.12-slim` (P1-PRE-3), meeting restricted PSS with non-root UID/GID 65532, read-only root filesystem, drop ALL capabilities, and RuntimeDefault seccomp.
- Injected AFM key only via projected Secret file (`defaultMode: 0440` at `/etc/signalloom-rbac-exporter/afm-key/token`), strictly passed as `Authorization: Bearer <token>` over internal FQDN `http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000/api/v1/afm/clusters/import`.
**Deviations:**
- Placed ClusterRole and ClusterRoleBinding in ResourceSet `spec.resources[]` as planned in P1-PRE-2 to avoid widening Flux privileges.
**Notes:**
- Failing-first tests committed in `a820492f` (13 failures out of 14 on base tree). Implementation delivered in `24565a35`.
- TAP totals: `test/afm-rbac-exporter-manifests.bats`: 7 passed, 0 failed, 0 skipped. `test/afm-rbac-exporter-push.bats`: 7 passed, 0 failed, 0 skipped.
- T6 guards TAP totals: `test/agent-swarm-flux-rbac.bats` (3/3 passed), `test/agent-swarm-tenancy.bats` (4/4 passed), `d2-signalloom/test/stun-sentinel-daemonset.bats` (11/11 passed), `test/sentinel-capabilities.bats` (16/16 passed, 1 skipped). Total: 35 tests, 0 failures, 1 skipped.
- `make -n test-sldc-offline` wiring count: 2 registered suites (`test/afm-rbac-exporter-manifests.bats`, `test/afm-rbac-exporter-push.bats`).
- Rendered 18-triple RBAC list:
  rbac.authorization.k8s.io|clusterrolebindings|get
  rbac.authorization.k8s.io|clusterrolebindings|list
  rbac.authorization.k8s.io|clusterrolebindings|watch
  rbac.authorization.k8s.io|clusterroles|get
  rbac.authorization.k8s.io|clusterroles|list
  rbac.authorization.k8s.io|clusterroles|watch
  rbac.authorization.k8s.io|rolebindings|get
  rbac.authorization.k8s.io|rolebindings|list
  rbac.authorization.k8s.io|rolebindings|watch
  rbac.authorization.k8s.io|roles|get
  rbac.authorization.k8s.io|roles|list
  rbac.authorization.k8s.io|roles|watch
  |namespaces|get
  |namespaces|list
  |namespaces|watch
  |serviceaccounts|get
  |serviceaccounts|list
  |serviceaccounts|watch
- Mutation proofs (9/9):
  MUT <d2-osramp-fleet/tenants/base/agent-swarm.yaml> <resources: ["namespaces", "serviceaccounts"] -> resources: ["namespaces", "serviceaccounts", "secrets"]> -> <bats test/afm-rbac-exporter-manifests.bats -f "never reads secrets"> RED; restored -> GREEN
  MUT <d2-osramp-fleet/tenants/base/agent-swarm.yaml> <verbs: ["get", "list", "watch"] -> verbs: ["get", "list", "watch", "create"]> -> <bats test/afm-rbac-exporter-manifests.bats -f "rendered ClusterRole RBAC"> RED; restored -> GREEN
  MUT <d2-osramp-fleet/tenants/base/agent-swarm.yaml> <verbs: ["get", "list", "watch"] -> verbs: ["get", "list"]> -> <bats test/afm-rbac-exporter-manifests.bats -f "rendered ClusterRole RBAC"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter-cronjob.yaml> <serviceAccountName: signalloom-rbac-exporter -> serviceAccountName: stun-sentinel> -> <bats test/afm-rbac-exporter-manifests.bats -f "never reads secrets"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter-cronjob.yaml> <allowPrivilegeEscalation: false -> allowPrivilegeEscalation: true> -> <bats test/afm-rbac-exporter-manifests.bats -f "restricted Pod Security"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter-cronjob.yaml> <secretName: signalloom-rbac-exporter-afm-key -> secretName: wrong-key-secret> -> <bats test/afm-rbac-exporter-manifests.bats -f "key mounted as Secret volume"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter-cronjob.yaml> <value: http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000/api/v1/afm/clusters/import -> value: http://external-afm.example.com:8000/api/v1/afm/clusters/import> -> <bats test/afm-rbac-exporter-manifests.bats -f "key mounted as Secret volume"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter/export.py> <'Authorization': f'Bearer {key}', -> # 'Authorization': f'Bearer {key}',> -> <bats test/afm-rbac-exporter-push.bats -f "full push with bearer key"> RED; restored -> GREEN
  MUT <d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/rbac-exporter/export.py> <sys.exit(5) -> return> -> <bats test/afm-rbac-exporter-push.bats -f "gateway 401, 403, 413, 500 exits 5"> RED; restored -> GREEN
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
