# Reference: Compliance & Supply Chain Evidence Specification

Signal Loom provides immutable supply chain security artifacts conforming to SLSA Level 3, SPDX 2.3, and Cosign keyless / keyed signing standards.

## Required Artifact Triad

For every built container image, three cryptographic sidecars must exist in `docs/signalloom/evidence/` or `docs/signalloom/evidence-fe/`:

1. **`.digest.txt`**: Canonical SHA256 image digest:
   ```
   sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
   ```

2. **`.sbom.spdx.json`**: Software Bill of Materials in SPDX 2.3 JSON format containing complete dependency inventory, licenses, and package checksums.

3. **`.provenance.slsa.json`**: In-toto attestation recording builder identity, git commit SHA, build timestamp, and invocation recipe.

---

## Audit Trail Invariant (Append-Only)

PostgreSQL table `audit_events`:
- Managed by `inf-signalloom/base/initdb/001_init.sql`.
- PostgreSQL rule or trigger prevents `UPDATE` or `DELETE` on this table:
  ```sql
  CREATE RULE audit_events_no_update AS ON UPDATE TO audit_events DO INSTEAD NOTHING;
  CREATE RULE audit_events_no_delete AS ON DELETE TO audit_events DO INSTEAD NOTHING;
  ```
- Any attempt to modify raises `42501` (permission denied / rule block).
- A compliant deployment MUST exhibit non-zero row growth corresponding to agent registrations, status changes, and policy evaluations.
