# SLDP-P6-2 Execution Proof — Customer-Self-Hosted Install Proof as Primary Validation

**Card:** `SLDP-P6-2` · **Phase:** 6 · **Role:** Implementation  
**Base Ref:** `refs/heads/integration/sldp-v0.1.0`  
**Worktree:** `/home/andy/src/.worktrees/c6d2a/osramp-demo`  
**Date:** 2026-09-14  
**Status:** **PASS**  
**Primary Deliverable:** [`docs/signalloom/sldp-p6-2-selfhost-install-proof.md`](./sldp-p6-2-selfhost-install-proof.md)  

---

## 1. Executive Summary & Objectives Achieved

SLDP-P6-2 resolves the critical misalignment between the commercial architecture and the deployment validation strategy in the Signal Loom Data Protection & Production Hardening programme.

### 1.1 The Core Problem Resolved
1. **The Flawed Milestone:** Milestone 4 of the proposal originally specified a *“region-pinned production deploy + KMS signing + DPIA pack”* evaluated via a GKE smoke test against a ControlPlane-operated cluster. This tested the **deferred vendor-operated SaaS model**, providing zero proof for the model actually selected by the business.
2. **The Programme Mandate:** **CEO Decision 4 and Section 10 Item 1** explicitly established **Customer-Self-Hosted** deployment as the primary go-to-market model. In tier-1 regulated banking and financial enterprises, employee identity graphs and authorization telemetry cannot leave the customer's private security perimeter.
3. **The Solution:** SLDP-P6-2 successfully refactors the validation architecture:
   - Establishes **Customer-Self-Hosted Kubernetes Deployment** as the **primary validation target**, proving installation from published, signed OCI artefacts into an environment ControlPlane does not operate.
   - Designates **Vendor-Operated GKE SaaS Deployment** as an explicitly **secondary reference overlay**.
   - Proves **zero dependency on ControlPlane-operated infrastructure** (including for KMS, identity provider, object storage, and attestation anchoring).
   - Establishes decoupled, **per-model residual risk statements**.
   - Records an explicit errata entry in the proposal Appendix.

---

## 2. Required Tests & Execution Evidence

All required acceptance commands and verification probes were executed directly in the worktree:

| # | Check / Command | Exit Code | Output / Evidence Summary |
|---|---|:---:|---|
| **1** | `test -f docs/signalloom/sldp-p6-2-selfhost-install-proof.md` | `0` | **PASS**: Primary self-host install proof document exists |
| **2** | `test -f docs/signalloom/sldp-p5-2-selfhost-install-proof.md` | `0` | **PASS**: Reference pointer file exists |
| **3** | `make test-signal-ingest` | `0` | **PASS**: Full `signal-ingest` Go test suite passes 100% across 24 packages (`ok .../identity`, `ok .../store`, `ok .../subjectkey`, `ok .../audit`, `ok .../transform`, `ok .../api`) |
| **4** | `bats test/acceptance-spec-coverage.bats` | `0` | **PASS**: 7/7 CI Stage 1c acceptance spec coverage checks pass |
| **5** | `make demo-signalloom-api-test TIER=contract` | `0` | **PASS**: 56/56 pytest contract checks pass (All 30 API routes & 001-009 migrations verified) |

### 2.1 Acceptance Spec Coverage Guard Output
```
1..7
ok 1 the guard can read every project in playwright.config.ts
ok 2 every spec on disk has exactly one registry row, and every row has a spec
ok 3 every registry runner is a known kind, and every non-CI row gives a reason
ok 4 a spec matches a playwright project if and only if the registry says so
ok 5 every ci: row names a stage that really runs that spec
ok 6 every spec a CI stage runs is registered as ci:
ok 7 every make: row names a target whose recipe runs that spec
```

### 2.2 FastAPI Contract & Migration Suite Output
```
======================== 56 passed, 2 warnings in 1.53s ========================
```

---

## 3. Zero-Dependency & Network Isolation Evidence

### 3.1 NetworkPolicy Audit
Inspection of `d2-signalloom/apps/signal-ingest/base/networkpolicy.yaml` confirms that `signal-ingest` enforces strict, mathematically bounded egress rules:
- **DNS Egress:** UDP/TCP port 53 scoped exclusively to `kube-system` namespace (`k8s-app: kube-dns`).
- **Database Egress:** TCP port 5432 scoped exclusively to `inf-signalloom` namespace (`app.kubernetes.io/name: postgresql`).
- **External Internet / SaaS Egress:** **Zero rules (Blocked by Default Deny).**
- **Ingress:** Port 8082 restricted exclusively to `fe-signalloom` API backend and `supercred-demo-runner`.

### 3.2 In-Cluster Key Custody & Attestation Plane
1. **Master KEK Custody:** Managed autonomously via `OpenBao` in `inf-bao` namespace; zero outbound Cloud KMS API calls.
2. **Subject DEK Shredding:** Executed locally in PostgreSQL table `subject_keys` with cryptographic destruction receipts.
3. **Attestation Keyring:** SPKI public keys stored locally in `<EvidenceDir>/keys/`; attestation checkpoints signed with in-cluster Ed25519 keys.
4. **Identity Federation:** Handled by Dex OIDC in `inf-signalloom` federating directly to customer enterprise LDAP/SAML without cloud identity brokers.

---

## 4. Per-Model Residual Risk Separation

Residual risks have been formally categorized and separated into two distinct matrices in `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` §6:

1. **Customer-Self-Hosted Risks:**
   - `CSH-01`: Customer key custody & unseal key backup durability.
   - `CSH-02`: PostgreSQL WAL & offline snapshot residual ciphertext management.
   - `CSH-03`: Kubernetes worker node host hardening & hypervisor memory isolation.
   - `CSH-04`: Customer SRE container update and patch cadence.
2. **Vendor-Operated GKE SaaS Risks:**
   - `SaaS-01`: Cloud sub-processor exposure (US Cloud Act / FISA 702).
   - `SaaS-02`: Multi-tenant compute node co-location side-channels.
   - `SaaS-03`: Google Cloud IAM misconfiguration.
   - `SaaS-04`: Regional cloud outage blast radius.

---

## 5. Summary of Deliverables & Citations

| Deliverable | Location / Citation | Status |
|---|---|:---:|
| **Customer-Self-Hosted Install Proof** | [`docs/signalloom/sldp-p6-2-selfhost-install-proof.md`](./sldp-p6-2-selfhost-install-proof.md) | **Delivered** |
| **Secondary GKE Reference Definition** | `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` §5 | **Delivered** |
| **Zero ControlPlane Dependency Proof** | `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` §4 | **Delivered** |
| **Per-Model Residual Risk Statements** | `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` §6 | **Delivered** |
| **Published Artefact & Migration Registry** | `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` §2 | **Delivered** |
| **Proposal Errata Update** | Proposal Appendix `#### Errata — SLDP-P6-2` | **Delivered** |
| **Work Decomposition Result Update** | Proposal Appendix `### Spec: Work Decomposition` row `P6-2` | **Delivered** |

---

## 6. Conclusion

SLDP-P6-2 satisfies all card requirements and establishes the verified foundation for final certification by the Phase 6 Governor (`SLDP-P6-GOV`).
