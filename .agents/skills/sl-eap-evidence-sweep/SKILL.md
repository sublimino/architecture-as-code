---
name: sl-eap-evidence-sweep
description: "Scheduled-run EAP pilot compliance evidence sweeper for #partner-signal-loom. Validates Cosign signatures, SLSA provenance, SPDX SBOMs, PostgreSQL audit_events row growth, and NetAssert policy proofs. USE WHEN sweep evidence, audit compliance evidence, verify eap evidence, verify cosign signatures, sl-eap-evidence-sweep, or on schedule '0 6 * * *'."
---

# sl-eap-evidence-sweep

Scheduled compliance evidence auditor and packager for **Signal Loom** (`#partner-signal-loom`) EAP design partners and enterprise reviews (Kusari EAP, Microsoft Architecture Review).

## Loop Lens & Schedule Contract

- **Cadence**: `0 6 * * *` (Daily at 06:00 UTC, or before external partner delivery).
- **Trigger**: Cron notification, `/sl-eap-evidence-sweep`, or manual prompt "sweep compliance evidence".
- **Checkpoint**: Push right. Automatically verify all cryptographic digests, signatures, and database audit logs. Compile a verified evidence ledger and deliver a concise executive brief.
- **Brief**: Emit a 4-bullet status: (1) Evidence artifacts verified, (2) Cosign and SLSA validity, (3) PostgreSQL audit row count, and (4) Diligence readiness score.

---

## Mandate & Non-Negotiable Invariants

1. **Cryptographic Proof (Never Trust Unchecked Files)**:
   - Every container artifact delivered to EAP partners must have a valid Cosign signature (`.sig`), SHA256 digest (`.digest.txt`), SPDX SBOM (`.sbom.spdx.json`), and SLSA provenance (`.provenance.slsa.json`).

2. **Immutable Audit Trail Invariant**:
   - The PostgreSQL `audit_events` table is append-only. Modifying existing rows must raise error `42501`.
   - The table must maintain active, continuous row insertion during platform operations. Zero rows indicates a broken audit logging pipeline.

3. **Airgap Verification Integrity**:
   - Evidence files must be self-contained and independently verifiable offline using public keys stored in `.keys/`.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Sweep.md`](Workflows/Sweep.md)
- **Compliance Evidence Spec**: [`References/ComplianceEvidenceSpec.md`](References/ComplianceEvidenceSpec.md)
- **Executable Sweeper**: [`Tools/evidence-sweep.sh`](Tools/evidence-sweep.sh)

---

## Execution Sequence

1. **Evidence Directory Audit**:
   - Scan `docs/signalloom/evidence/` and `docs/signalloom/evidence-fe/`.
   - Check presence of digest, SBOM, and provenance files for all built images (`dashboard-signalloom`, `fe-signalloom`, `fleet-manager`).

2. **Cosign & Digest Verification**:
   - Run digest verification against committed images.
   - Run BATS supply chain tests: `bats d2-signalloom/test/dashboard-supplychain.bats`.

3. **Audit Log Continuity Probe**:
   - If database is running, query `SELECT COUNT(*) FROM audit_events;`.
   - Verify count is greater than zero and timestamp of newest row is recent.

4. **NetAssert & Network Policy Proofs**:
   - Verify latest NetAssert test run reports in `docs/signalloom/`.

5. **Generate Evidence Report**:
   - Aggregate all signatures and hashes into a markdown table.

---

## Completion Criteria

- **Clarity**: Unambiguous evidence certification status (`COMPLIANT`, `PARTIAL`, or `DEFICIENT`).
- **Demand**: 100% of image evidence files audited. Database audit count verified and brief delivered.
