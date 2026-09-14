# SLDP remaining milestone sizing — P1-3

Planning estimates, not approved staffing or calendar commitments. This document
supplies every blank milestone effort field for **Governor application** to the
proposal. The task's safety boundary prohibits writing the proposal in the
Governor sibling worktree; the proposal itself has not been changed here.

## Basis and assumptions

Sources: `sldp-p0-boundary-map.md`, `sldp-p0-proof.md`,
`sldp-p1-pre-proof.md`, and current interfaces at P1-2 integration `fcc72aba`.
This is new control construction, not configuration-only hardening. The
independent verifier is now available; historical evidence remains immutable.

Use two core delivery engineers; security/platform/GRC specialists are consulted
within the person-day ranges, not silently assumed as a free second team.
One person-day is eight focused hours. Costs are **remaining implementation,
testing and review**, excluding already completed P0/P1-2. External legal effort
and KMS contingency are stated separately.

**D0** is authorized start with two engineers assigned and authoritative tenant
ownership agreed. No absolute date is defensible without that start decision.
Deadlines below are relative working days (weekends/holidays excluded).

M3's tenant foundation is a prerequisite for useful per-tenant pseudonyms,
erasure and protected queries. The proposed order is **M3 → M1 → review → M2 →
M4 → signoff**. It needs Governor approval; this card does not alter the phase
graph. The schedule is deliberately serial by milestone to avoid promising
overlapping full-time two-engineer teams from the same two people. Early KMS
discovery and legal booking can occur, but no unallocated parallel capacity is
claimed.

## Replacement milestone fields

| Milestone | Duration (working days) | Consultants | Person-days | Deadline relative to D0 |
|---|---:|---:|---:|---|
| M1: Pseudonymisation, separated re-identification map, field allow-list | 16–21 | 2 | 26–34 | D+32–43, after M3 |
| M2: Retention/rotation, crypto-shred, attested tombstones, Art 17 exceptions | 23–31 | 2 | 40–54 | D+56–75, after M1/review |
| M3: Graph encryption-at-rest and tenant isolation | 16–22 | 2 | 26–36 | D+16–22 |
| M4: Region pinning, KMS signing, DPIA pack | 18–25 | 2 | 30–42 | D+74–100, after M2 |
| Mid-project review | 0.25 | 2 | 0.5 | D+33–44 |
| Signoff and evidence reconciliation | 2–3 | 2 | 4–6 | D+76–103 |
| **Total** | **75.25–102.25** | **2 core** | **126.5–172.5** | **D+76–103 (rounded up)** |

Approximate elapsed delivery is 15–21 working weeks before external delay.
Elapsed days exceed person-days/2 because integration and review are not
perfectly divisible. Rounded deadline endpoints must not be added together;
they derive from cumulative unrounded durations in the stated execution order.

## Interface-derived work breakdown

### M1 — 26–34 person-days

- P0 locates scrubber/HMAC in `transform/transform.go`, but persistence wiring
  and authoritative identity policy are still work, not an existing end-to-end
  control. Field allow-list and ingest-policy wiring: **5–7 days**.
- `identity/repository.go` and alias migrations store directly identifying
  values; `AESGCMEncryptor` is whole-field encryption, not the separately
  authorized re-identification service. Pseudonym keys, encrypted alias map,
  audited re-identification and migration: **11–14 days**.
- `store/frostdb.go` schema, `model.Observation`, authorization references and
  the never-merge invariant must evolve without changing old Parquet bytes:
  **10–13 days**, including schema compatibility and negative tests.

### M2 — 40–54 person-days

- `identity.Repository` has no erase-subject transaction; its reaper changes
  status rather than deleting personal data. Per-subject key hierarchy and
  idempotent saga/recovery: **12–16 days**.
- No legal-hold/dual-operator erasure gate exists. Build hold checks, scope,
  approvals and failure recovery: **7–10 days**.
- `audit.EventPartitionDropped` is only a declaration in the P0 baseline.
  Retention needs a controller and receipts across identified stores/sinks,
  not a call to an existing eraser: **12–16 days**.
- Tombstones need non-linkable identifiers and explicit checkpoint-verifiable
  semantics; erasure and legal exceptions need failure-injection evidence:
  **9–12 days**. Neither deletion of old segments nor signature-only success is
  an acceptable shortcut.

### M3 — 26–36 person-days

- `identity.Repository`, `SignalStore.Query` and `model.Observation` lack
  authoritative tenant ownership in the baseline. Tenant claims must bind
  stored objects, not merely authenticate a caller: **8–12 days**.
- Operational PostgreSQL RLS, tenant migration, transaction-scoped tenant
  context, pooled-connection cleanup, non-owner/non-BYPASSRLS role enforcement,
  and hostile cross-tenant tests: **10–14 days**.
- Confidentiality/key-custody wiring, SSE/query authorization, least-privilege
  roles and integration regression: **8–10 days**. P1-2 fail-closed encryption
  removes a baseline defect but does not create tenant policy.

### M4 — 30–42 person-days

- `SegmentAttestorConfig.PrivateKeyPath`, concrete `*ed25519Signer`, and direct
  `ed25519.Sign` mean KMS is a signer-interface and public-version-retention
  change, not an environment-variable substitution: **8–12 days**.
- Region-pinned/customer-hosted installation, backup/restore, network and
  optional anchor residency evidence: **8–10 days**; production execution
  requires separate explicit authorization.
- DPIA/LIA/data map and lawful-basis evidence against implemented controls:
  **6–8 days** plus external review below.
- Reviewed P5-3 Article 15/20/21 mechanisms and downstream contract delivery:
  **8–12 days**; these are not assumed to exist in the Go APIs.

Cross-version evidence compatibility consumes approximately 8–12 days **inside**
the M1/M2 estimates, not an additional line to double-count.

## Contingencies and approval dependencies

- Selected KMS provider/algorithm is unconfirmed. If it cannot satisfy the
  current Ed25519 DSSE contract, add **8–15 person-days**, approximately **5–10
  elapsed working days**, for approved versioned algorithm adaptation. Never
  silently invalidate retired-key evidence or fall back to exportable keys.
  Risk-adjusted engineering total: **134.5–187.5 person-days**; serial deadline
  approximately **D+81–113** before external delay.
- External DPO/legal review: **2–4 reviewer-days**, excluded from engineering
  total; book at D0 with **10–20 working days** lead time. This is calendar
  dependency, not proof of compliance or a guaranteed review date.
- The Phase Governor must reconcile tenant-ownership sequencing. No new claim
  that a primitive exists is made here; P0's missing controls remain build work.
- Fixed calendar deadline, named staffing and a production corpus scan require
  authorization/input not supplied to this isolated implementation card.

The Governor should copy these ranges into the six milestone rows, replace
the “to be estimated with team” total with the stated planning range and D0
qualification, and preserve unrelated cards' Result/cost/token columns.
