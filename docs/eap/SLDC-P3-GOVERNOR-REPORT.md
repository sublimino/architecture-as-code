# SLDC-P3-GOV: Phase 3 Governor Report: Tenant Routing & Isolation Verification

> Status: see `ci-evidence/phase3-governance-certification.json` (`status: "PASS"`, `gates_passed: 8/8`).
> **Governance Attestation:** Phase 3 gate is certified passed; Phase 4 (cAdvisor telemetry pipeline) is cleared to proceed.

| Field | Value |
| :---- | :---- |
| Card | SLDC-P3-GOV (Phase 3 Governor) |
| Integration branch | `integration/sldc-v0.1.0` |
| Merge commit | `ec30913e00b65671c6ec7a73f831969ce76cbb3b` |
| Merged | SLDC-P3-1 `f65f5a414066f4b9638185a7da6f532fdb9c0f18`, SLDC-P3-2 `3d9aee452048a95beae597cba5cf6ce4a9fd076b` |
| Runner | `scripts/test-phase3-governor.sh` |
| Suites | `test/phase3-governor-verification.bats` (12/12 pass), `test/eap-tenant-routing.bats` (14/14 pass), `test/tenant-hash-vectors.bats` (12/12 pass) |
| Evidence | `ci-evidence/phase3-governance-certification.json`, `ci-evidence/phase3-routing-audit.txt` |

---

## 1. Executive Summary & Verification Scope

The Phase 3 Governance Gate validates cryptographic tenant domain synthesis, Gateway API HTTPRoute compilation, Dex OIDC federation alignment, and strict fail-closed cross-tenant ingress boundary isolation.

Prior to Phase 3, legacy typo vectors (`kurasi` yielding unsalted `6f82ad81`) existed in documentation and exploratory test stubs. Phase 3 establishes the canonical tenant derivation vector `kusari` -> `4b53ab6b` using salted SHA-256 (`sha256(salt + ":" + lower(trim(tenant)))[0:8]`) across all language implementations, and proves that cross-tenant access attempts, mismatched headers, and legacy typo vectors are strictly rejected with **HTTP 403 Forbidden** or **HTTP 404 Not Found**.

---

## 2. Certified Governance Gate Matrix

| Gate | Description | Assertion & Evidence | Result |
| :--- | :---------- | :------------------- | :----- |
| **G1 Branch Integration** | Clean non-fast-forward merge of P3-1 and P3-2 into `integration/sldc-v0.1.0`. | Merge commit `ec30913e` integrates `feat/sldc-p3-1` (`f65f5a41`) and `feat/sldc-p3-2` (`3d9aee45`) with 0 merge conflicts. | **PASS** |
| **G2 Crypto Derivation** | Multi-runtime verification of `derive_tenant_hash('kusari')` -> `4b53ab6b`. | Python (`test/unit/test_tenant_hash.py` 28/28), TypeScript (`test/unit/tenant-hash.test.ts` 6/6), Go (`fe-signalloom/pkg/tenant` 5/5), BATS (`test/tenant-hash-vectors.bats` 12/12). | **PASS** |
| **G3 HTTPRoute Config** | Gateway API HTTPRoute manifest syntax and label binding. | `deploy/eap-tenant-httproute.yaml` binds `sl-eap-4b53ab6b.ts.net` & `sl-eap-4b53ab6b.demo.signalloom.io` to `fe-signalloom-service:3000` with labels `tenant: kusari` and `tenant-hash: 4b53ab6b`. | **PASS** |
| **G4 Dex OIDC Alignment** | Dynamic Origin / Redirect URI federation readiness. | `d2-signalloom/infra/dex/dex-config-eap.yaml` and `base/dex.yaml` configure canonical callback `https://sl-eap-4b53ab6b.ts.net/auth/callback` for client `signalloom-dashboard`. | **PASS** |
| **G5 Positive Routing** | Live and hermetic routing probes to canonical hostnames. | Probes to `sl-eap-4b53ab6b.ts.net` and `sl-eap-4b53ab6b.demo.signalloom.io` return **HTTP 200 OK** with security headers; headerless requests default safely to inferred `kusari`. | **PASS** |
| **G6 Negative Isolation** | Strict boundary isolation on spoofed, unauthorized, or legacy headers. | 6/6 negative probes rejected fail-closed: `X-Tenant-ID: kurasi` -> **403**, `X-Tenant-ID: 6f82ad81` -> **403**, `X-Tenant-ID: rogue` -> **403**, `sl-eap-6f82ad81.ts.net` -> **404**. | **PASS** |
| **G7 Mutation Testing** | Empirical falsification assurance on altered vectors and relaxed filters. | Deliberate mutation of derivation vectors and filter policies asserts 100% detection rate and immediate test failure on synthetic regressions. | **PASS** |
| **G8 Zero-Tolerance Typo** | Codebase-wide eradication of legacy typo `kurasi` and `6f82ad81`. | Repository scan confirms 0 occurrences of `kurasi` or `6f82ad81` in active codebase files. | **PASS** |

---

## 3. Cryptographic Derivation Verification

The canonical tenant hash derivation is formally verified against the reference formula:

$$\text{Hash} = \text{SHA-256}(\text{SALT} \parallel \text{":"} \parallel \text{lowercase}(\text{trim}(\text{tenant})))[0:8]$$

Using pilot salt `signalloom-eap-salt-2026-q3`:
- Canonical input: `"kusari"` $\longrightarrow$ `4b53ab6b`
- Unsalted digest: `d9d69501` (flagged as non-canonical and rejected)
- Legacy HMAC vector: `4a89f30d` (flagged as non-canonical and rejected)
- Legacy typo: `"kurasi"` $\longrightarrow$ fails closed with exit code 1 / `ErrRetiredTenant`

All implementations (Go `tenant.DeriveTenantHash`, Python `derive_tenant_hash.py`, TypeScript `deriveTenantHash`, and Shell `tailscale-eap-env.sh`) produce identical byte-for-byte outputs and enforce identical fail-closed exception paths on retired inputs.

---

## 4. Ingress Routing & Cross-Tenant Boundary Probes

Raw HTTP trace evidence captured in `ci-evidence/phase3-routing-audit.txt` validates the complete routing matrix:

```
[HTTP Probe P1] Host: sl-eap-4b53ab6b.ts.net | Header: X-SignalLoom-Tenant='kusari'           | Expected: 200 | Actual: 200 (PASS)
[HTTP Probe P2] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='kusari'                   | Expected: 200 | Actual: 200 (PASS)
[HTTP Probe P3] Host: sl-eap-4b53ab6b.ts.net | Header: None (Inferred)                         | Expected: 200 | Actual: 200 (PASS)
[HTTP Probe P4] Host: sl-eap-4b53ab6b.demo.signalloom.io | Header: None                       | Expected: 200 | Actual: 200 (PASS)
[HTTP Probe P5] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='  KUSARI  '               | Expected: 200 | Actual: 200 (PASS)
[HTTP Probe N1] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='kurasi'                   | Expected: 403 | Actual: 403 (PASS)
[HTTP Probe N2] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='6f82ad81'                 | Expected: 403 | Actual: 403 (PASS)
[HTTP Probe N3] Host: sl-eap-4b53ab6b.ts.net | Header: X-SignalLoom-Tenant='rogue'            | Expected: 403 | Actual: 403 (PASS)
[HTTP Probe N4] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='unauthorized-org'         | Expected: 403 | Actual: 403 (PASS)
[HTTP Probe N5] Host: sl-eap-4b53ab6b.ts.net | Header: X-Tenant-ID='  KuRaSi  '               | Expected: 403 | Actual: 403 (PASS)
[HTTP Probe N6] Host: sl-eap-6f82ad81.ts.net | Header: X-Tenant-ID='kusari'                   | Expected: 404 | Actual: 404 (PASS)
```

---

## 5. Deliberate Mutation Testing & Falsification Proof

To satisfy Shared Pattern 6 (Empirical Mutation Assurance), the following deliberate mutations were verified:
1. **Hash Generator Discrimination:** Mutating the expected hash to `d9d69501` or `6f82ad81` immediately triggers assertion failure.
2. **Tenant Filter Ingress Policy:** Injecting a synthetic bypass permitting `kurasi` or arbitrary tenant strings causes `test/eap-tenant-routing.bats` mutation assertions to fail immediately with exit code 1.
3. **Typo Zero-Tolerance Audit:** Injecting `kurasi` into a non-exempt codebase file causes Gate 8 to exit with code 1.

---

## 6. Remediations Executed During Governance

1. **`d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go`:** Removed legacy Phase 1 fallback `if tenant == "kurasi"` which canonicalized the typo; replaced with strict tenant label assignment. Inverted `ebpf_correlator_test.go` to test canonical `kusari` normalization.
2. **`d2-signalloom/apps/docs-signalloom/src/content/docs/operate/environment-routing.mdx`:** Rewrote documentation to replace all instances of `Kurasi` and `6f82ad81` with canonical `Kusari` and `4b53ab6b`.
3. **`test/phase3-governor-verification.bats`:** Authored comprehensive Governor BATS suite with 12 end-to-end tests validating merge cleanliness, cryptographic derivation, routing, isolation, and mutation resilience.
4. **`scripts/test-phase3-governor.sh`:** Authored automated multi-gate runner generating machine-readable JSON approval certificates and raw trace logs.

---

## 7. Sign-Off & Advancement Authorization

Phase 3 Governance certification is **COMPLETE and APPROVED**. All cryptographic boundaries and tenant isolation policies have been empirically verified.

- **Authorized Next Phase:** Phase 4 Pre-Flight (`SLDC-P4-PRE`) and cAdvisor Telemetry Pipeline Implementation (`SLDC-P4-1`, `SLDC-P4-2`).
