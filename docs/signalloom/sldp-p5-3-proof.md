# SLDP-P5-3 Execution Proof — Data-Subject-Rights Mechanisms (Articles 15, 20, 21)

**Card:** SLDP-P5-3 · **Phase:** 5 · **Role:** implementation  
**Integration branch:** `integration/sldp-v0.1.0`  
**Date:** 2026-09-14  

---

## 1. Executive Summary & Objective

Prior to SLDP-P5-3:
1. `docs/Signal Fusion — Architecture and GDPR Reference.md` §7.4 claimed Article 15 Access was built into an export endpoint, yet no export endpoint existed in `d2-signalloom/apps/signal-ingest/api/handlers.go`.
2. Article 20 Data Portability was absent from both documentation and implementation.
3. Article 21 Right to Object was incorrectly credited to a payload field allow-list (`d2-signalloom/apps/agentmaxxing-host-sensor/filter.py`), with zero subject-level or person-level exclusion concepts.

This card implements the full data-subject-rights architecture across both data planes and at the workstation sensor boundary, aligns documentation with technical reality, and proves robust security and privacy invariants.

---

## 2. Key Architecture & Deliverables

```
                                  DATA SUBJECT RIGHTS BOUNDARY
                                                │
   [ Workstation Host Sensor ]                  │           [ Signal-Ingest API Gateway ]
  ┌───────────────────────────┐                 │                 ┌───────────────┐
  │  SubjectObjectionRegistry │                 │                 │  Auth & RBAC  │
  │  (Art. 21 Person Opt-Out) │                 │                 │ (Fail-Closed) │
  └─────────────┬─────────────┘                 │                 └───────┬───────┘
                │ (Suppresses telemetry         │                         │
                │  collection at source)        │                         ▼
                ▼                               │           GET /api/v1/privacy/export/{id}
       [ Filtered Ingest ]                      │           GET /api/v1/actors/{id}/export
                │                               │                         │
                ▼                               │                         │
  ┌──────────────────────────────────────────┐  │        ┌────────────────┴────────────────┐
  │                 PLANE 1                  │  │        │             PLANE 2             │
  │     PostgreSQL / In-Memory Graph         │  │        │   FrostDB / In-Memory Evidence  │
  │  • Canonical Actor Profile               │◄─┼────────┤ • HMAC Pseudonym Pushdown       │
  │  • Aliases & Attributions                │  │ (Merge)│ • Observation Event History     │
  │  • Delegation Edges & Scopes             │  │        │ • Evidence Attestation Digests  │
  │  • Art. 15(4) Third-Party Redaction      │  │        │ • Bounded Pagination & k >= 5   │
  └──────────────────────────────────────────┘  │        └─────────────────────────────────┘
                                                │
```

### 2.1 Cross-Plane Personal Data Export (Article 15 Access)
- **Endpoints:** Registered `GET /api/v1/privacy/export/{id}` and `GET /api/v1/actors/{id}/export` under `privacy:export` permission.
- **Dual-Plane Resolution:**
  - **Plane 1 (Identity Graph):** Resolves canonical actor entity, verified aliases, active and revoked delegation edges, and permission scopes.
  - **Plane 2 (Evidence Store):** Resolves immutable telemetry observations, evidence records, and signed attestation digests matching the data subject's HMAC pseudonym (`hmac_actor_id`, `hmac_actor_hint`, `hmac_principal_id`, `hmac_impersonated_user`).
- **Over-disclosure Protection (Article 15(4)):** Multi-party records (e.g. delegation links and impersonation events) redact third-party personal identifiers (`[REDACTED_THIRD_PARTY_SUBJECT]`, `ThirdPartyMasked: true`) to prevent exfiltration of co-workers' data during a DSAR.
- **Fail-Closed Requester Verification:** Access requires valid authentication tokens and matching actor claims (`requester == subjectID`, explicit actor scope in `ActorIDs[subjectID]`, or verified alias), or explicit administrative privacy permissions (`privacy:admin` / DPO). Unverified third-party calls without administrative DPO authority fail closed with `403 Forbidden`.
- **Bounded Export Sizing:** Default limit of 100 records (`MaxExportLimit = 1000`) with pagination offsets. Truncation flags (`truncated: true`, remediation guidance) prevent memory exhaustion from oversized exports.
- **Small-Cell Suppression Floor (k-Anonymity):** Enforces `MinAggregateGroupSize = 5` for any statistical or grouped queries, returning `ErrGroupSizeBelowAnonymityFloor` to eliminate re-identification risks.

### 2.2 Machine-Readable Portable Export (Article 20 Portability)
- **Portable Format Schema:** Produces structured Article 20 JSON adhering to schema `https://signalloom.controlplane.io/schemas/gdpr-art20-portability-v1.json` (`export.go:27`).
- **Content:** Aggregates user profile attributes, consented delegations, and activity telemetry with completeness statement and legal rationale.
- **Supported Format Triggers:** Accessible via `?format=portability`, `?format=art20`, `?format=article20_portable`, or `Accept: application/x-portability+json`.
- **Documented Legal Scope Boundaries:** Covers data directly provided by the data subject and automated telemetry collected under consent or contract (Art. 20(1)); explicitly excludes internal risk scoring algorithms, aggregate statistics, and proprietary heuristics.

### 2.3 Person-Level Objection and Opt-Out (Article 21 Objection)
- **Workstation Sensor Registry:** Implemented `SubjectObjectionRegistry` in `filter.py` and integrated into `sensor.py`.
- **Distinction from Allowlisting:** Payload allowlisting (`AllowlistFilter`) restricts dictionary keys/attributes on observed processes. The objection registry identifies individuals (`actor_id`, username, email) and suppresses all process sampling, stream polling, and process exit events at the workstation edge before transmission.

---

## 3. Test & Verification Evidence

### 3.1 Go Signal-Ingest Subject Rights Test Suite
Command: `env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -run TestSubjectRights ./... -v`
```
=== RUN   TestSubjectRights_Article15_DualPlaneAccessExport
--- PASS: TestSubjectRights_Article15_DualPlaneAccessExport (0.00s)
=== RUN   TestSubjectRights_Article20_MachineReadablePortability
--- PASS: TestSubjectRights_Article20_MachineReadablePortability (0.00s)
=== RUN   TestSubjectRights_OverDisclosure_PreventsThirdPartyLeakageInSharedRecords
--- PASS: TestSubjectRights_OverDisclosure_PreventsThirdPartyLeakageInSharedRecords (0.00s)
=== RUN   TestSubjectRights_BoundedSizeAndOverflowBehavior
--- PASS: TestSubjectRights_BoundedSizeAndOverflowBehavior (0.00s)
=== RUN   TestSubjectRights_BoundedTimeExport_LargestSubject
--- PASS: TestSubjectRights_BoundedTimeExport_LargestSubject (0.00s)
=== RUN   TestSubjectRights_MinimumGroupSize_EnforcesKAnonymity
--- PASS: TestSubjectRights_MinimumGroupSize_EnforcesKAnonymity (0.00s)
=== RUN   TestSubjectRights_PseudonymRing_DeterministicDerivedPseudonym
--- PASS: TestSubjectRights_PseudonymRing_DeterministicDerivedPseudonym (0.00s)
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed/SelfAccess_Succeeds
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed/WildcardNonDPO_FailsClosed
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed/DPOWithPrivacyAdminPermission_Succeeds
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed/DPOServiceAccount_Succeeds
--- PASS: TestSubjectRights_RequesterVerification_FailsClosed (0.00s)
    --- PASS: TestSubjectRights_RequesterVerification_FailsClosed/SelfAccess_Succeeds (0.00s)
    --- PASS: TestSubjectRights_RequesterVerification_FailsClosed/WildcardNonDPO_FailsClosed (0.00s)
    --- PASS: TestSubjectRights_RequesterVerification_FailsClosed/DPOWithPrivacyAdminPermission_Succeeds (0.00s)
    --- PASS: TestSubjectRights_RequesterVerification_FailsClosed/DPOServiceAccount_Succeeds (0.00s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	0.020s
```

### 3.2 Python Host Sensor Article 21 Objection Test Suite
Command: `python3 -m unittest discover -s d2-signalloom/apps/agentmaxxing-host-sensor`
```
.........................................
----------------------------------------------------------------------
Ran 41 tests in 0.898s

OK
```

### 3.3 Full Go Signal-Ingest Module Suite
Command: `env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test ./...`
```
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest	0.018s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	7.336s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit	0.158s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit	4.508s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors	1.472s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono	0.528s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/baoaudit	0.327s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf	0.611s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/gcpaudit	0.009s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/kagent	0.054s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf	0.005s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/spirea	0.010s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/workspacesaas	0.044s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation	16.223s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	0.399s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model	0.005s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair	0.038s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy	0.016s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy/tombstone	1.622s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store	4.032s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/subjectkey	0.016s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/transform	0.006s
```

---

## 4. Documentation Reconciliation

Updated `docs/Signal Fusion — Architecture and GDPR Reference.md` (§7.4) to replace stale assertions with exact technical mechanisms, endpoints, and scope limitations:
- **Article 15 (Access):** Detailed dual-plane export (`GET /api/v1/privacy/export/{id}` and `GET /api/v1/actors/{id}/export`), fail-closed auth, Art. 15(4) third-party masking, bounded pagination, and $k \ge 5$ k-anonymity.
- **Article 20 (Portability):** Documented machine-readable format (`?format=article20_portable`) and statutory boundaries.
- **Article 21 (Objection):** Documented `SubjectObjectionRegistry` in the workstation sensor for person-level exclusion.
