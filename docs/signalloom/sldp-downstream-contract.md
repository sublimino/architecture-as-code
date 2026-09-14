# Signal Loom data-protection contract — v0.1.0 (frozen by SLDP-P6-GOV)

**Status:** frozen · **Published by:** SLDP-P6-GOV · **Integration ref:** `refs/heads/integration/sldp-v0.1.0`
**Consumers:** SLER, SLCD, AMXD · **Supersedes:** nothing — this is the first published version

---

## 0. Why this document exists, and how to use it

Three parallel identity schemes appeared in this codebase because three missions each inferred an
identity model from source instead of reading a published one. This document is the interface they
should have been reading. It is frozen: SLER, SLCD and AMXD build against the symbols named here
and do not re-derive them.

**Every row names the file a consumer reads.** A contract that describes an interface without
naming where to find it leaves the consumer to infer one, which is the failure this document exists
to prevent. Paths are relative to the repository root
(`d2-signalloom/apps/signal-ingest/` is abbreviated `si/` below).

**What "frozen" means and does not mean.** It means the *names and their semantics* are stable for
v0.1.0 — a consumer may bind to them. It does not mean the controls are complete; §7 lists what is
explicitly not covered, and the mission certification
([`sldp-mission-certification.md`](./sldp-mission-certification.md)) states which properties are
proven and which are accepted.

---

## 1. Tenant scoping

**The rule:** every persisted identity, key, hold, receipt and re-identification row carries
`tenant_id`, and PostgreSQL enforces the predicate independently of the application's WHERE clause.
A consumer must never rely on its own filtering alone.

| Element | Where a consumer reads it |
|---|---|
| RLS enablement and policies | `si/identity/migrations/006_tenant_isolation_rls.sql` — 4 × `ENABLE ROW LEVEL SECURITY`, 8 × `CREATE POLICY` |
| Per-feature RLS (added after 006) | `007_segment_reidentification_map.sql`, `008_retention_legal_holds.sql`, `009_subject_keys.sql`, `010_retention_receipts.sql` — each enables RLS and creates its own policy |
| Session variable the policies read | `si/identity/migrations/006_tenant_isolation_rls.sql` (the `current_setting` predicate) |
| HTTP route → permission → tenant binding | `si/api/auth.go` (route table, ~line 300 onward) |
| Live hostile-context proof | `make test-identity-rls-live` (Makefile:582) — stands up a real PostgreSQL; migration text alone passes identically whether the policies deny anything or not |

**Consumer obligation.** Open pooled connections with the tenant session variable set. A bare
pooled query under `FORCE ROW LEVEL SECURITY` returns zero rows rather than an error — a silent
empty result is the failure mode, not a permission denial.

---

## 2. Pseudonym derivation

Two distinct pseudonym domains exist. **They are not interchangeable, and a consumer that mixes
them will silently fail to join.**

| Domain | Symbol | File | Scope of the key |
|---|---|---|---|
| Columnar segments (FrostDB / Parquet) | `store.SegmentPseudonymiser.Pseudonym(value string)` | `si/store/segment_pseudonymiser.go:138` | root key + tenant scope + epoch |
| Segment evidence references | `store.SegmentPseudonymiser.EvidenceRefDigest(value string)` | `si/store/segment_pseudonymiser.go:154` | domain-separated from `Pseudonym` |
| Identity graph / erasure saga | `privacy.SubjectPseudonymiser.Pseudonym(tenantID, subjectID string)` | declared `si/privacy/erasure.go:149`; consumed `si/subjectkey/saga.go:286` | tenant-keyed |

**Configuration a consumer must supply** (`si/store/segment_pseudonymiser.go:19-29`):

| Env var | Meaning |
|---|---|
| `SIGNAL_SEGMENT_PSEUDONYM_KEY` | root HMAC key; absent ⇒ construction fails closed |
| `SIGNAL_SEGMENT_PSEUDONYM_EPOCH` | epoch; changing it deliberately breaks joinability across the boundary |
| `SIGNAL_SEGMENT_PSEUDONYM_TENANT` | tenant scope; default `signaldb/observations` (`DefaultSegmentTenantScope`) |

**Properties a consumer may rely on:** determinism within a (key, tenant, epoch) triple; scope
separation across tenants and epochs; domain separation between `Pseudonym` and
`EvidenceRefDigest`; fail-closed construction on a missing or short key. Each is pinned by a named
test in `si/store/segment_schema_v2_test.go:160-309`.

**Property a consumer must NOT rely on:** that a segment pseudonym and an identity-graph pseudonym
for the same natural person are equal. They are computed under different keys by design.

---

## 3. Key hierarchy

`si/subjectkey/hierarchy.go` — a three-level hierarchy whose *only* erasure primitive is destroying
the per-subject DEK. The tenant KEK and the tenant HMAC keys deliberately survive erasure.

| Symbol | File:line | Contract |
|---|---|---|
| `subjectkey.KeyScope{TenantID, SubjectPseudonym, KeyEpoch, KeyVersion}` | `hierarchy.go:121` | the four-tuple that names exactly one key; `Validate()` refuses an incomplete scope |
| `subjectkey.NewHierarchy(masterKey []byte)` | `hierarchy.go:165` | refuses a weak master key |
| `subjectkey.NewDEK()` | `hierarchy.go:248` | random, never derived — a derived DEK would be recoverable after "destruction" |
| `subjectkey.Zero(b []byte)` | `hierarchy.go:343` | in-place zeroisation; the alternative is leaving live key material for the allocator |
| `subjectkey.Saga.Erase(ctx, tenantID, subjectID)` | `saga.go:275` | idempotent, deterministic `OperationID`, returns `DestructionReceipt` |
| `subjectkey.Saga.DestroySubjectKeys(...)` | `saga.go:228` | wraps `Erase`, returns `privacy.KeyDestructionReceipt` |
| Plaintext DEK cache purge | `si/subjectkey/cache.go:186` `PurgeSubject(tenantID, pseudonym)` | prefix-scoped to one subject within one tenant |
| Schema | `si/identity/migrations/009_subject_keys.sql` |

**What the tenant KEK NOT being destroyed means, stated plainly** (`cache.go:68,73`): the tenant KEK
wraps every other subject's DEK, and the tenant HMAC keys compute the pseudonym the saga itself uses
to *find* the subject's row. Destroying either would evict other subjects' key material for no
erasure benefit, and would make the erasure unable to locate its own target. A consumer that wants
tenant-wide destruction is asking for a different operation, which does not exist.

---

## 4. Retention and erasure

`si/retention/` — a retention state machine over a storage-copy inventory, plus
`si/identity/migrations/010_retention_receipts.sql`.

| Element | Where a consumer reads it |
|---|---|
| Storage-copy inventory — **35 sinks** | `si/retention/sink.go:205` `AllSinkSpecs()` |
| Inventory provenance parity test | `si/retention/inventory_parity_test.go` — parses `sldp-p6-pre-proof.md` and `sldp-p0-boundary-map.md`; a new row in either document fails the test until an adapter exists |
| Receipt schema | `si/retention/receipt.go:23` `ReceiptSchema = "signalloom.retention-deletion-receipt/v1"` |
| Dispositions — closed set of five | `si/retention/receipt.go:41-71` |
| Acceptance gate | `si/retention/gate.go:80` `AcceptanceGate(...)` — fails on any overdue object **and** on a vacuous pass |
| Controller | `si/retention/controller.go` — `Sweep`, `SubmitExternalReceipt`, `Reconcile`, `Reaper` |

**The five dispositions, and which count as complete** (`receipt.go:90`):

| Disposition | Complete? | Meaning |
|---|:---:|---|
| `purged` | yes | rows or bytes removed |
| `already_absent` | yes | copy was not present; still earns a receipt |
| `retained_unresolvable_token` | yes | attested bytes retained because deleting them would break the checkpoint chain; the token no longer resolves to a subject |
| `held` | **no** | an active legal hold blocked deletion |
| `unreachable` | **no** | the sink could not be reached |

**The inventory denominator is the contract's most load-bearing number.** A copy that is never
enumerated cannot go overdue, so a forgotten sink presents as *higher* coverage, not as a hole. A
consumer adding a new persistence sink MUST add a row to `AllSinkSpecs()`; the parity test is what
makes that obligation enforceable rather than advisory.

**Residual honesty.** Receipts declare `StorageResidualMVCCAndBackup` rather than claiming
bit-level disk erasure: dropping PostgreSQL rows leaves dead tuples in WAL and physical backups
until `VACUUM` and backup expiry.

---

## 5. Telemetry field allow-list

`si/store/label_allowlist.go` — a **closed allow-list of 48 dynamic label keys**. Any key outside it
is refused *before any Arrow record is built*; the whole batch is rejected, not the offending row.

- Empty allow-list is a **refusal**, never a permit-all (`ErrLabelAllowListEmpty`, `label_allowlist.go:20`).
- Refused keys produce `DisallowedLabelKeyError` naming the key and observation, so an operator need not bisect a batch.
- The 48 keys are infrastructure topology and event classification only; no key names a natural person.
- Pinned by `si/store/segment_schema_v2_test.go:467-536`.

**Two limits a consumer must design around, both stated in the source:**

1. **The allow-list constrains KEYS only.** `Append` checks `k` and never `v`. `reason` routinely
   holds strings like `User "alice" cannot get pods`; `name` can hold an email address. This bounds
   the *shape* of the label space, not its contents. Free-text values are covered only to the extent
   the description redactor covers them, which today is not at all
   (`label_allowlist.go:49-55`, SLDP-P3-1 finding F3).
2. **The file carries `//go:build frostdb`.** The allow-list is compiled into the FrostDB store
   only. A consumer running the default in-memory store (`si/store/factory.go`) has **no
   allow-list in force**, and `make test-signal-ingest` — the untagged target — never exercises it.
   Use `make test-signal-ingest-frostdb` to test against the configuration that has the control.

---

## 6. Evidence integrity — what erasure must not break

| Element | Where a consumer reads it |
|---|---|
| Go verification entrypoints | `si/store/verify/verify.go:176` `VerifyCorpus`, `:237` `VerifySegment` |
| Keyring loading | `si/store/verify/verify.go:261` `LoadKeyring`, `:295` `LoadKeyringFromDir` |
| Python verifier + CLI | `d2-signalloom/apps/fe-signalloom/src/audit_anchor/` — `segments.py`, `cli.py` (`verify --source segments`) |
| Segment signer abstraction (KMS) | `si/store/signer.go`, `signer_kms.go:63` `NewKMSSigner` |
| Tombstones | `si/privacy/tombstone/` — `tombstone.go`, `signer.go` |

**The invariant, and it is not negotiable:** erasure is crypto-shredding plus tombstones. It never
rewrites or deletes an attested segment's bytes. Segment schema changes ship as a *new schema
version*; the segment schema and the attestation schema are separate, pinned by
`TestSegmentSchema_IsNotTheAttestationSchema` (`si/store/segment_schema_v2_test.go:146`). A consumer
that deletes a segment file also breaks checkpoint continuity — use the retention path and accept
`retained_unresolvable_token`.

---

## 7. Explicitly NOT in this contract

Named so a consumer does not infer coverage from silence:

1. **Free-text label values and observation descriptions.** §5 limit 1. No redaction is in force today.
2. **Article 18 (restriction of processing).** No owner on any board row; the `frozen` actor status
   the GDPR reference claims exists does not (`rg 'frozen' si/identity/` → zero lines).
3. **Article 21 server-side enforcement.** Registration and persistence exist; server-side
   enforcement does not (P5-GOV finding G4). The host-sensor objection registry is process-local
   and in-memory; no deletion controller reaches workstation sensor memory.
4. **Cross-tenant isolation on the Article 15/20 export path.** Not assessed; the export harness is
   not tenant-scoped (P5-GOV finding G1).
5. **Queue-overflow posture for the segment attestor.** Undecided. A KMS-induced overflow can leave
   a segment silently unattested with `Upload` returning `nil` (SLDP-P5-PRE recommendation #3).
6. **Rekor publication.** Rejected at `audit_anchor/anchor.py:392-407`. If it is ever enabled it is a
   NEW retention sink and needs a row in `AllSinkSpecs()`.
7. **Physical unlinking of FrostDB Parquet segment files.** `FrostDBStore.DropPartition` advances an
   in-memory timestamp cutoff. Whether FrostDB supports safe physical unlinking without corrupting
   active block readers is unproven.

---

## 8. Consumability check

Performed by SLDP-P6-GOV. For each contract element, the single file a consuming mission opens:

| Contract element | File a consumer reads | Verified present |
|---|---|:---:|
| Tenant scoping | `si/identity/migrations/006_tenant_isolation_rls.sql` + `si/api/auth.go` | ✅ |
| Pseudonym derivation | `si/store/segment_pseudonymiser.go` | ✅ |
| Key hierarchy | `si/subjectkey/hierarchy.go` | ✅ |
| Retention | `si/retention/sink.go` + `si/retention/receipt.go` | ✅ |
| Telemetry allow-list | `si/store/label_allowlist.go` | ✅ |
| Evidence integrity | `si/store/verify/verify.go` | ✅ |
| This contract | `docs/signalloom/sldp-downstream-contract.md` | ✅ |

**"Frozen" currently has no enforcement mechanism, and a consumer should know that.** Naming a file
freezes nothing: a rename or a symbol move voids the contract silently, and the consumer discovers
it at runtime. Until a sibling pins a digest of this artefact, or asserts file-exists plus
symbol-exists in its own build, drift breaks a *reading*, not a build. Recommended to the first
consuming mission that binds to this document.

### 8.1 Three warnings a consumer must read before binding

1. **Cross-tenant erasure isolation is UNFALSIFIED.** Mutation M1d removed the tenant predicate
   from `si/subjectkey/store.go:293` and `TestErasureSaga_ErasesOneSubjectOnly` stayed green.
   Isolation rests on tenant-keyed pseudonym derivation (§2), not on a tested predicate. Widened
   (M1e): with that predicate deleted, **every test in `subjectkey`, `privacy` and
   `privacy/tombstone` still passes** — all three packages report `ok`. This is an untested
   control, not a weak assertion. **Do not design as though the store enforces a tenant boundary on
   key lookup; nothing tests that it does.** Certification §1, Property 1.
2. **The 48-key allow-list in §5 is compiled by exactly one non-default make target.**
   `-tags frostdb` occurs once in the Makefile and nowhere in CI. It is not type-checked by
   `go build ./...` or `go vet ./...`. Treat it as a design intent with a documented gap, not as an
   enforced egress control. Certification §6 Q2.
3. **"Historical attestations verify" means the writer's own corpora**, not bytes signed by an
   older build. No golden pre-change corpus is checked in, so a backward-compatibility break in
   canonicalisation or envelope schema would not be caught. Certification §1, Property 2.
