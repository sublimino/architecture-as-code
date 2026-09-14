# Tombstone Signing Authority and Its Published Limits

**Card:** SLDP-P4-2 · **Package:** `d2-signalloom/apps/signal-ingest/privacy/tombstone`
**Schema:** `signalloom.tombstone/v1` · **Predicate:** `https://controlplane.io/attestations/signalloom-tombstone/v1`

This document answers three questions a second-line reviewer will ask about an attested tombstone,
and answers the third one unfavourably rather than leaving it implied.

1. Who may sign a tombstone?
2. What does a valid signature prove?
3. How would a forgery be detected?

---

## 1. Who may sign

Exactly one role: the **Signal Loom evidence-plane signing identity**, holding the Ed25519 private
key named by the environment variable `SIGNAL_TOMBSTONE_KEY` and loaded by
`tombstone.NewTombstoneSigner`.

| Property | Value | Enforced at |
|---|---|---|
| Algorithm | Ed25519 (PKCS#8 PEM) | `NewTombstoneSignerFromPEM` — a non-Ed25519 key is refused with `ErrNotEd25519` |
| Key identifier | hex SHA-256 of the PKIX SPKI | `NewTombstoneSignerFromPEM`; identical rule to `store/segment_attestor.go` |
| Envelope | DSSE, `payloadType` `application/vnd.in-toto+json`, PAE-encoded | `TombstoneSigner.Sign` |
| Statement | in-toto `https://in-toto.io/Statement/v1` | `tombstone.Statement` |
| Signature count | exactly one | `VerifyEnvelope` refuses 0 or ≥2 |

### Separation from the erasure-authorisation registry

The tombstone signing identity is deliberately **not** a member of
`privacy.OperatorRegistry`, the dual-operator set that authorises an Article 17(3) override.

Those are two different authorities. Operators *authorise* an erasure; the platform *attests* that
it happened. One key holding both would mean a single compromised operator could grant themselves
an override and then mint the evidence that the override was granted properly — the dual-operator
control in `privacy/exception.go` would still be running, and would still be satisfiable by one
person.

### Separation from the segment attestor

The envelope format is byte-compatible with `store/segment_attestor.go`, so a deployment *may*
reuse that key. It **should not**, and the reason is revocation rather than cryptography: a segment
attestation asserts "these bytes were ingested" and a tombstone asserts "this data is gone". One key
means one revocation, so withdrawing a mis-issued tombstone claim invalidates every ingestion claim
in the estate at the same time. Reusing the key is a decision to take knowingly, not a default to
fall into.

### Pre-signature refusals

`Sign` cannot be used to launder a field into attested evidence. Before any signature is produced,
`Statement` runs both:

- `Tombstone.Validate()` — value-level: schema version, id length, day shape, policy basis,
  generation range, commitment lengths, and that `anonymity_set_min` equals the build's constant.
- `ValidateDocument()` — key-level: the marshalled document's key set must equal
  `tombstone.AllowedFields` exactly, in both directions.

`VerifyEnvelope` re-runs both *after* the signature verifies, so a tombstone minted by an older or
patched build cannot carry a forbidden field into a reader that assumed the allow-list had been
enforced upstream. `TestTombstoneSigningCannotLaunderAForbiddenField` proves this with a validly
signed envelope whose predicate carries `subject_pseudonym`: the signature is genuine, and the
envelope is still refused.

---

## 2. What a valid signature proves

**It proves custody of the tombstone signing key at the moment of signing. That is all.**

It does **not** prove:

- **when** the tombstone was minted — `erased_day` is an unverified assertion by the signer;
- **that the erasure happened** — nothing binds the tombstone to the key-destruction event other
  than the signer's own claim;
- **that the tombstone is the only one** — nothing prevents minting two contradictory tombstones.

---

## 3. Forgery detectability — the published limit

> **There is no external transparency anchor for Signal Loom evidence today. A locally signed
> tombstone forgery is not externally detectable. Do not represent an attested tombstone to a
> regulator as tamper-evident.**

The two anchoring paths and their current state:

| Path | State | Evidence |
|---|---|---|
| **Rekor** | Refuses outright. `require_rekor_if_configured` verifies connectivity and then raises regardless: `raise AnchorError("Rekor anchoring is not implemented; no checkpoint was published to Rekor")` | `d2-signalloom/apps/fe-signalloom/src/audit_anchor/anchor.py:407` |
| **Archivista** | Optional. `SegmentAttestor` publishes only when `ArchivistaURL != ""`, and `RequireArchivista` defaults false; an unreachable Archivista falls back to a local `FileAnchorStore` | `store/segment_attestor.go`; `audit_anchor/anchor.py` |

The consequence, stated plainly: a holder of `SIGNAL_TOMBSTONE_KEY` can mint a tombstone for an
erasure that never occurred, or backdate one to any `erased_day`, and every verification path in
this repository will accept it. Detection today requires comparing the tombstone against the
erasure audit trail inside the deployment — which is to say, it requires trusting the same party
that would have forged it.

**This is a limit, not a defect introduced by this card.** It is published here so that the claim
made to a customer's DPO is the claim the code supports.

### What would close it

1. Implement Rekor publication *and inclusion-proof verification* — connectivity is not anchoring,
   which is exactly why `anchor.py:407` refuses rather than pretending.
2. Or make Archivista mandatory (`RequireArchivista: true`) with a monitored, independently
   operated instance, and verify inclusion on read.

Either one converts "custody of the key" into "custody of the key at a witnessed time", which is
what makes backdating detectable.

---

## 4. The auditability field, and why it is the only one

A tombstone that is perfectly non-linkable cannot answer "prove *my* erasure ran". The field that
resolves this is `confirmation_commitment`:

```
confirmation_commitment = HMAC-SHA256(K, canonical("signalloom.tombstone.confirmation.v1",
                                                   tenant_id, subject_id, request_id))
```

`K` is a 256-bit one-time key drawn at mint, returned **once** by `tombstone.Mint`, and never
persisted by this package. Handing it to the requester is the deliberate, greppable
`ConfirmationKey.Disclose()`; the type refuses to marshal and redacts itself under `%v`, `%s` and
`%#v`.

| Party | Holds | Can confirm a specific erasure? |
|---|---|---|
| Any third party, holding the full retained-evidence corpus and candidate subject list | tombstone only | **No.** The field is a PRF output. `TestTombstoneConfirmationIsUselessWithoutTheKey` iterates 1,000 candidates including the true one and confirms nothing. |
| The platform | tombstone, evidence, its own keys | **No.** It discarded `K`. It therefore cannot be compelled to re-identify. |
| The data subject / their regulator | tombstone + `K` + the subject and request they already know | **Yes.** `ConfirmSpecificErasure` returns true for the true triple and false for four distinct near-misses. |

Note the shape: the commitment supports a **test**, not a **reveal**. The verifier must already
know the subject to check membership, so the field can never disclose a subject's identity to
someone who does not already hold it.

### Two consequences the DPIA pack must record

1. **The confirmation key is personal data once issued.** It is a token that links a named person
   to a specific erasure event. Retaining it creates a record of who exercised Article 17. Whoever
   holds it — the subject, or a controller-side escrow if one is ever introduced — is processing
   personal data and must be declared, not left as an undeclared artefact.
2. **The key must live outside the crypto-shred boundary.** SLDP-P4-1's erasure saga destroys the
   subject key envelope. If the confirmation key were ever stored inside it, the erasure would
   destroy the proof of its own erasure. This package never persists the key at all, which
   satisfies the invariant by construction; any future escrow must honour it explicitly.

---

## 5. Cross-card invariants

| # | Invariant | Owner | Consequence if broken |
|---|---|---|---|
| I1 | Key generations passed to `ProjectReceipt` are **tenant-scoped**, never per-subject | SLDP-P4-1 | The generation range becomes a subject identifier |
| I2 | No key-generation identifier appears in retained evidence — not a segment column, not an audit detail payload, not a queryable key-metadata table | SLDP-P4-1 | Direct join key; demonstrated by `TestTombstoneLinkageProbeDetectsGenerationCollision` |
| I3 | The confirmation key is never persisted, and never enters the crypto-shred boundary | SLDP-P4-1, SLDP-P5-x | Either the non-linkability collapses, or the proof is destroyed with the data |
| I4 | `privacy` must not import `privacy/tombstone` — inject via an interface declared in `privacy`, wired in `main.go` | SLDP-P4-1 | Import cycle |
| I5 | The bucket population supplied to `Mint` is a real measurement of the tenant's cohort for that UTC day, not a constant | SLDP-P4-1 | The k-anonymity check becomes decorative |
| I6 | Erasures are **batched** so that at least `MinAnonymitySet` subjects' rows disappear between any two externally observable states of the retained corpus | SLDP-P4-1 | See §6 — the differencing attack bypasses every tombstone field |
| I7 | Tombstones are published as a randomly ordered daily batch committed under one Merkle root, not appended individually as minted | SLDP-P4-1 / evidence plane | Chain position is a total order, and position + tenant + day is a quasi-identifier no random `tombstone_id` can fix |
| I8 | The `ConfirmationKey` returned by `Mint` never reaches a response log, trace span, message queue or audit projection | SLDP-P4-1 (HTTP layer) | "Returned once" is an operational claim, not a cryptographic one; each of those is an unintended persistence of the only secret in the scheme |

I5 is the one with no test behind it, and it is stated here rather than implied: this package can
refuse a population below the floor, but it cannot verify that the number it was given is true.

---

## 6. Two attacks this package cannot close, and who owns them

Both were surfaced by an independent adversarial review of the design, and both live outside a
tombstone's fields, which is precisely why the field-level controls in this package cannot address
them.

### 6.1 The differencing attack across corpus snapshots — **unmitigated**

The linkage probe joins a tombstone against a *static* retained corpus. The real adversary — an
auditor, a regulator, a replica holder, someone with an older export — sees the corpus at time *T*
and again at *T+1*. Erasure removes rows. **The set difference between two snapshots is the erased
subject's row set, with an anonymity set of one**, and it links to the tombstone by `erased_day`
without reference to any published field. Every property engineered into the tombstone is bypassed,
because the leak is in the corpus delta rather than in the document.

This matters specifically for an evidence store, which exists to be read repeatedly by auditors, so
multiple observable snapshots are a design feature rather than an exotic assumption.

The mitigation is **I6**: k must hold over the set of subjects whose rows vanish together, which
makes the anonymity bucket a *scheduling* property of the erasure batch rather than a field-level
property of the tombstone. That is a meaningfully different piece of engineering and it belongs to
the erasure saga, not to this package. `Mint`'s k-check is necessary and is not sufficient.

### 6.2 External auxiliary knowledge — **unmitigable**

Erasure requests arrive with lawyer letters, support tickets, and data subjects who say publicly
that they were deleted on the third. `tenant_id` plus `erased_day` then identifies directly, and no
property of this schema can prevent it. It is recorded so that the claim made to a DPO is
"unlinkable against the retained corpus", not "unlinkable".

---

## 7. Published schema (`signalloom.tombstone/v1`)

| Field | Type | Why it is safe |
|---|---|---|
| `schema_version` | string | Constant across all tombstones |
| `tombstone_id` | 32 hex chars | 128 bits of `crypto/rand`, independent of every input |
| `tenant_id` | string | A tenant is not a data subject; it scopes the anonymity set |
| `erased_day` | `YYYY-MM-DD` UTC | Coarsened; `Mint` refuses below a cohort of `MinAnonymitySet` |
| `policy_basis` | 2-value enum | Partitions the population into two classes |
| `key_generation_first` / `key_generation_last` | uint64, epoch-aligned | Coarsened to a `GenerationEpochSize`-wide band — see below |
| `keys_destroyed_band` | `0` / `1` / `2-5` / `6-20` / `21+` | Generalised — see below |
| `receipt_commitment` | 64 hex chars | `SHA-256(nonce ‖ projection)` where the projection is a strict subset of published fields and contains no subject |
| `receipt_nonce` | 64 hex chars | 256 bits of `crypto/rand`; makes structurally identical erasures publish different commitments |
| `confirmation_commitment` | 64 hex chars | PRF output under a one-time key the platform does not retain |
| `anonymity_set_min` | int | The build's threshold constant, never the observed measurement |

### Why `keys_destroyed` is banded

k enforced over `(tenant, erased_day)` alone is defeated by any unbucketed attribute that re-splits
the bucket, and an exact key count is exactly that. Five tombstones sharing a tenant and a day with
counts 3, 7, 1, 22 and 4 are **five singletons** to an adversary who can estimate a candidate's key
count — which retained segment rows permit, since activity volume tracks key count.

`TestTombstoneLinkageProbeDetectsUnbandedQuasiIdentifier` demonstrates this directly. With the
exact count and the raw generation range published, each attribute alone leaves 7 and 25 candidates
respectively — both above the floor — while **their conjunction leaves exactly 1**. With banding and
epoch coarsening, the same conjunction leaves 25.

### Why the generation range is epoch-coarsened

A tenant-scoped monotonic counter is a timestamp wearing a disguise, and three things leak from
one: **rank** (first/last orders subjects by enrolment and by last activity, and ranking candidates
by first-seen in segment rows turns that into a solvable permutation-matching problem), **cadence**
(periodic rotation makes generations-per-day calibratable, which inverts any generation into a
wall-clock estimate finer than the published day, which then joins to `decided_at` at RFC3339Nano),
and **population** (observed maxima and gaps admit a German-tank estimator for tenant size — a
commercial disclosure as much as a privacy one).

Publishing the epoch band containing the destroyed generations removes all three at band
resolution: two erasures within one epoch publish byte-identical ranges. `Validate` enforces
alignment, so a hand-assembled un-coarsened range cannot be published.

**Residual, and recommended:** truncate retained `decided_at` in the erasure audit trail to the
coarsest granularity the audit obligation permits. Nanosecond precision in the retained corpus is a
near-unique fingerprint and weakens every temporal control above it.
