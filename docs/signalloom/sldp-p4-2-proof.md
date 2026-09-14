# SLDP-P4-2 Execution Proof — Non-linkable Attested Tombstones

**Date:** 2026-09-14 · **Branch:** `integration/sldp-v0.1.0` · **Base:** `97bb7985`
**Package:** `d2-signalloom/apps/signal-ingest/privacy/tombstone` (2,973 lines across 5 files)
**Companion:** [`tombstone-signing-authority.md`](./tombstone-signing-authority.md)

---

## 1. Objective

Specify a tombstone that cannot recreate the link it erases: a schema that structurally cannot
carry an identifying or joinable field, a non-joinability test that attempts the join and requires
it to fail, a documented signing authority, a published statement that no external anchor exists,
a population-size check on the coarse timestamp, and a stated resolution of the tension between
non-linkability and auditability.

## 2. What a link is, and the three mechanisms that carry one

A link exists between a tombstone and a subject iff an adversary can compute, from public data, a
function that narrows the candidate set below their prior. That is not the same as "contains an
identifier", and the difference is what the rest of this document turns on. Exactly three
mechanisms carry a link:

1. **Direct carriage** — the field is the identifier, or a deterministic function of it under a key
   the platform retains.
2. **Recomputation oracle** — the field is a digest over data the adversary can guess.
3. **Selector** — the value is rare enough to select a single row in retained evidence.

A fourth, which only appears when fields are considered jointly, is addressed in §6:
**conjunction** — individually safe attributes intersecting to a singleton.

## 3. Deviation from SLDP-P4-PRE §6.2 — two allow-listed fields are joinable

The preflight's field list was not implemented as written. Two of its seven allow-listed fields are
themselves re-identification primitives.

| P4-PRE §6.2 field | Mechanism | Evidence | Replacement |
|---|---|---|---|
| `receipt_digest` = "hex SHA-256 digest of `KeyDestructionReceipt`" | **2** — the struct is `{SubjectID, TenantID, KeysRemoved, DestroyedAt}` (`privacy/erasure.go`), and every field except `SubjectID` would have been published in the same tombstone, so the digest reduces to guess-and-check over the subject space alone | `TestTombstoneLinkageProbeDetectsPlantedReceiptDigest` plants it and confirms the true subject | `receipt_commitment` over `ReceiptProjection`, which has no subject in its domain |
| `erased_at` at RFC3339**Nano** | **3** — the erasure audit row written by `Service.writeDecision` carries `decided_at` at the same resolution alongside `subject_pseudonym`; nanosecond equality is a de-facto primary key | `TestTombstoneLinkageProbeDetectsNanosecondTimestamp` collapses the cohort from 41 to 1 | `erased_day`, a UTC calendar day, with `Tombstone` carrying no `time.Time` field at all |

The preflight also allow-listed `receipt_digest` four lines above a deny-list entry reading "no
unkeyed hashes of subject identifiers". **The allow-list contradicted the deny-list.**

Note the sharper form, since it is the one that matters:
`TestTombstoneLinkageProbeDetectsCoarseOnlyReceiptDigest` shows that coarsening the timestamp does
**not** rescue the digest construction. The day is published too, so the preimage remains guessable.
The construction had to change, not its inputs.

## 4. The published schema

`signalloom.tombstone/v1` — twelve fields, closed under `ValidateDocument` in both directions. The
full field table with per-field safety arguments is in
[`tombstone-signing-authority.md` §7](./tombstone-signing-authority.md).

Structural defences, in order of how hard they are to bypass:

| Defence | Mechanism | Bypass requires |
|---|---|---|
| No `time.Time` field anywhere in `Tombstone` | reflection-asserted | changing the struct AND `TestTombstoneHasNoTimeField` |
| Allow-list ≡ reflected struct tags, both directions | `TestTombstoneAllowListMatchesStruct` | adding the field to both, which is a visible decision |
| Forbidden name substrings and `_`-delimited tokens | `FieldNameViolations`, shared by tests and the signer | naming the field something that is not an identifier word |
| `ValidateDocument` at mint, at sign, and after verify | key-set equality | patching three call sites |
| `Tombstone.Validate` value check | schema version, id length, day shape, epoch alignment, band membership, commitment lengths | patching `Validate` |

**Implementation note worth recording.** The naive forbidden-substring check for `ip` fires on
"rece**ip**t", which would reject the schema's own `receipt_commitment`. Weakening the guard to
make it pass would also stop it catching `ip_address`. The guard therefore splits keys on `_` and
matches short fragments as whole tokens (`ForbiddenFieldTokens`), keeping raw substring matching
for fragments that cannot false-positive (`ForbiddenFieldSubstrings`).

## 5. The population-size check on the coarse timestamp

A coarse timestamp is not a privacy control on its own: "an erasure happened in tenant T on
2026-09-14" identifies the subject exactly when only one subject in T could have been erased that
day. `Mint` therefore takes `BucketPopulation` and **fails closed**.

| Input | Result | Sentinel |
|---|---|---|
| unset (`0`) | refused — absent is not "unchecked, proceed" | `ErrPopulationUnknown` |
| negative | refused | `ErrInvalidRequest` |
| `1` | refused | `ErrAnonymitySetTooSmall` |
| `MinAnonymitySet - 1` = 4 | refused | `ErrAnonymitySetTooSmall` |
| `MinAnonymitySet` = 5 | **permitted** (boundary, inclusive) | — |
| `100` | permitted | — |

A refused mint returns the **zero** `Tombstone` and the zero key, so a caller ignoring the error
publishes nothing plausible — asserted, and mutation-verified by "return a populated tombstone
alongside a refusal".

`MinAnonymitySet = 5` is the conventional small-cell suppression floor in statistical disclosure
control. It is a defensible default, not a figure any regulation names, and it is a compile-time
constant so a deployment cannot lower it under pressure.

**The tombstone publishes the threshold, never the measurement.** `anonymity_set_min` is always 5.
Publishing the observed population would be a per-tombstone varying attribute useful for clustering
and would disclose tenant volume. `TestTombstonePublishesThresholdNotMeasurement` mints with a
distinctive population of 8123 and asserts the string does not appear in the document.

## 6. The non-joinability probe

`linkage_probe_test.go` is a `_test.go` file permanently: it implements a re-identification attack,
and a re-identification tool in the shipped binary is one an operator can be compelled to run. Go
does not compile `_test.go` into the package archive, so this is structural rather than a
convention.

### 6.1 What counts as a link

Not "a strategy matched something". A tombstone publishes its tenant and a calendar day on purpose,
so a strategy matching every row in the tenant on that day has found the **scope**, not the
subject. A strategy has LINKED when a single join predicate narrows the candidate set below
`MinAnonymitySet` — the DPO's "better than 1 in k?" stated as code.

Narrowing is tracked **per predicate**, not per strategy. That correction mattered: aggregating
every hit into one subject set let a genuine one-row link
(`tombstone.subject_pseudonym == audit.subject_pseudonym`) be diluted to harmlessness by forty
scope-level matches on `tenant_id`, and the planted-pseudonym control went green against a probe
that had found the defect.

### 6.2 Corpus and strategies

The corpus is 41 rows modelling what survives an erasure: audit rows (`subject_pseudonym`,
`decided_at` at RFC3339Nano, `request_id`) and columnar segment rows (HMAC actor pseudonym), plus
two attributes the adversary can **estimate** rather than read — `ObservedKeyCount` (activity
volume tracks key count) and `EnrolmentGeneration` (rank by first-seen).

| # | Strategy | What it tries |
|---|---|---|
| 1 | exact | every (tombstone field, evidence field) pair for equality |
| 2 | substring | containment in both directions, ≥8 characters |
| 3 | digest | recomputation over the candidate list, including the P4-PRE receipt shape with `keys_removed` **enumerated** and every corpus nanosecond timestamp |
| 4 | generation | published range against a generation identifier in evidence |
| 5 | temporal | the most precise temporal field present |
| 6 | quasi-identifier | the **conjunction** of day ∧ key-count ∧ generation |

### 6.3 Result — compliant tombstone

```
fields=12 rows=41 candidates=41
  exact{raw=41 predicates=1 narrowed=41 links=false}
  substring{raw=82 predicates=2 narrowed=41 links=false}
  digest{raw=0  predicates=0 narrowed=0  links=false}
  generation{raw=0 predicates=0 narrowed=0 links=false}
  cohort{raw=41 predicates=1 narrowed=41 links=false}
  quasi-identifier{raw=25 predicates=1 narrowed=25 links=false}
  cohortBasis=erased_day (UTC day)   best=1/25
```

The identifier strategies find nothing. The temporal and quasi-identifier strategies find a
**cohort**, which is the honest claim — `TestTombstoneNonJoinability` asserts a lower bound of
`MinAnonymitySet` rather than zero, precisely because a nanosecond timestamp is exactly what would
fail a lower bound.

### 6.4 Positive controls — the probe is not inert

A probe whose job is to fail to link is indistinguishable, when green, from a probe that does
nothing. Six controls plant a defect and require the **same code path** to find it.

| Control | Defect planted | Strategy that must fire | Result |
|---|---|---|---|
| `DetectsPlantedPseudonym` | subject's keyed pseudonym | exact | narrowed 41 → **1** |
| `DetectsNanosecondTimestamp` | `erased_at` RFC3339Nano | temporal | cohort 41 → **1** |
| `DetectsPlantedReceiptDigest` | P4-PRE `receipt_digest` | digest | confirms the true subject |
| `DetectsCoarseOnlyReceiptDigest` | same digest over the **day** | digest | still confirms — coarsening does not save it |
| `DetectsGenerationCollision` | generation id in evidence | generation | **1** |
| `DetectsUnbandedQuasiIdentifier` | exact count + raw range | quasi-identifier | see below |

`TestTombstoneLinkageProbeSurvivesRepeatedMints` runs 25 independent mints against the same corpus,
so a single lucky draw cannot carry the claim.

### 6.5 The conjunction attack, and the generalisations that defeat it

An adversarial review of the design raised that "LINKED = one predicate narrows below k" is a
single-predicate definition, and predicates that are individually safe narrow multiplicatively when
intersected. It was right, and the attack was real:

```
exact count alone:              1/7     (above the floor — not a link)
coarsened generation alone:     1/25    (above the floor — not a link)
CONJUNCTION of the two:         1/1     (a link)
```

Two generalisations close it, both mutation-verified:

- **`keys_destroyed` → `keys_destroyed_band`** (`0` / `1` / `2-5` / `6-20` / `21+`). An exact key
  count re-splits a k=5 `(tenant, day)` bucket into singletons against an adversary who can
  estimate it from activity volume.
- **`key_generation_first/last` → epoch-aligned band** (`GenerationEpochSize = 1000`). A
  tenant-scoped monotonic counter is a timestamp in disguise and leaks enrolment **rank**, rotation
  **cadence** (which inverts to a wall-clock estimate finer than the published day, joining to
  nanosecond `decided_at`), and tenant **population** via a German-tank estimator. Two erasures
  within one epoch now publish byte-identical ranges. `Validate` enforces alignment, so an
  un-coarsened range cannot be hand-assembled.

With both generalisations the same conjunction leaves **25**.

## 7. The auditability resolution — which field confirms a specific erasure

`confirmation_commitment` = `HMAC-SHA256(K, canonical(tenant, subject, request))`, where `K` is a
256-bit one-time key drawn at mint, returned once, and never persisted by this package.

| Party | Can confirm a specific erasure? | Proof |
|---|---|---|
| Third party with the full corpus and candidate list | **No** — the field is a PRF output | `TestTombstoneConfirmationIsUselessWithoutTheKey` iterates 1,000 candidates including the true one |
| The platform | **No** — it discarded `K`, so it cannot be compelled either | by construction; nothing persists it |
| The data subject / their regulator | **Yes** | `TestTombstoneConfirmSpecificErasure`: 1 true row, 4 false rows |

The commitment supports a **test**, not a **reveal**: the verifier must already know the subject,
so the field can never disclose an identity to someone who does not hold it. This is crypto-
shredding applied to the *proof* rather than to the data — the same primitive as the erasure itself.

## 8. Mutation verification — every control can fail

`privacy/tombstone/mutation-check.sh` breaks each control in turn and requires a **named** test to
go red. It asserts the number of tests that actually ran, because a `go test -run` pattern matching
nothing exits 0 and would score as a kill.

**24 mutations killed, 0 survived, 1 declared expected-survivor.**

The declared survivor is `ValidateDocument` inside `Statement`: `Statement` marshals a `Tombstone`,
which by construction emits only allow-listed keys, so the check is defence-in-depth against a
future struct/allow-list divergence that `TestTombstoneAllowListMatchesStruct` already catches at
test time. It is recorded rather than deleted, and rather than asserted to die.

**The harness found a real defect in the probe.** When `keys_destroyed` became a band, the mutation
that reinstates the P4-PRE oracle started building its preimage from the band — and **survived**,
because `digestGuesses` hardcoded `"3"`. A real adversary does not know the exact count but a count
is a small integer, so they enumerate it. The digest strategy now enumerates `keys_removed` across
the band string and 0–25, and the mutation is killed. A probe that guesses one value produces false
negatives that read as clean results.

## 9. Command evidence

```
$ cd d2-signalloom/apps/signal-ingest && go test ./privacy/tombstone/ -count=1 -v
    RUN=76  PASS=76  FAIL=0  SKIP=0

$ go test -run TestTombstone ./...
ok   .../privacy/tombstone    1.488s      (all other packages: no tests to run)

$ go test -race ./privacy/tombstone/ -count=1
ok   .../privacy/tombstone    10.349s

$ go vet ./...
    (clean, whole module)

$ gofmt -l privacy/tombstone/
    (empty)

$ ./privacy/tombstone/mutation-check.sh
    killed=24 survived_or_inconclusive=0

$ make test-signal-ingest
    MAKE_RC=0    PASS: 1123   FAIL: 0   SKIP: 34

$ rg -n 'not implemented' d2-signalloom/apps/fe-signalloom/src/audit_anchor/anchor.py
407:    raise AnchorError("Rekor anchoring is not implemented; no checkpoint was published to Rekor")
```

The 34 skips are pre-existing in other packages; `privacy/tombstone` reports zero skips, and the
declared-vs-run test count is asserted (76 declared, 76 run) rather than inferred from a green
verdict.

## 10. Published limits and unmitigated attacks

Stated so that the claim made to a DPO is the claim the code supports.

| # | Limit | Status |
|---|---|---|
| L1 | **No external transparency anchor.** Rekor refuses at `anchor.py:407`; Archivista is optional. A holder of the signing key can mint or backdate a tombstone and no party outside the deployment can detect it. | **Published, unmitigated.** Closing it requires Rekor publication *with inclusion-proof verification*, or mandatory monitored Archivista. |
| L2 | **The differencing attack.** The probe joins against a *static* corpus. An observer holding two snapshots takes the set difference and obtains the erased subject's rows with anonymity set 1, linking by `erased_day` alone. Every tombstone field is bypassed because the leak is in the corpus delta. | **Published, unmitigated here.** Owned by SLDP-P4-1 as invariant I6: erasures must be batched so ≥5 subjects' rows vanish together. `Mint`'s k-check is necessary, not sufficient. |
| L3 | **Chain position.** If tombstones are appended individually to an externally verifiable append-only chain, position + tenant + day is a quasi-identifier no random `tombstone_id` fixes. | **Published.** Invariant I7: publish as a randomly ordered daily batch under one Merkle root. |
| L4 | **External auxiliary knowledge.** Lawyer letters, support tickets, a subject who says publicly they were deleted on the third. | **Unmitigable by any schema.** The claim is "unlinkable against the retained corpus", not "unlinkable". |
| L5 | **The bucket population cannot be verified.** `Mint` refuses a population below the floor but cannot check that the number it was given is true. | **Published.** Invariant I5. |
| L6 | **Retained `decided_at` is RFC3339Nano.** Nanosecond precision in the audit trail is a near-unique fingerprint and weakens every temporal control above it. | **Recommendation recorded**, outside this card's boundary (`privacy/erasure.go` is SLDP-P4-1's). |

## 11. Scope boundaries honoured

- **No migration sequence number claimed.** The card flags `identity/migrations/` as a collision
  surface where two cards must not claim the same number. Tombstones are attestation-plane
  evidence, not identity-graph rows, so nothing here needs a migration; claiming 009 speculatively
  would have created the collision the card warns about.
- **`privacy/erasure.go` and `store/frostdb.go` untouched.** Both are flagged collision surfaces and
  `erasure.go` Phase 5 is SLDP-P4-1's. The contract is compile-checked instead:
  `ProjectReceipt` takes the concrete `privacy.KeyDestructionReceipt`, so if P4-1 changes the
  receipt shape this package stops compiling and someone decides again whether the new field is
  safe to commit to.
- **No existing attested segment or checkpoint touched**; no Parquet bytes rewritten; no tenant
  isolation weakened; no re-identification map created — the platform is *less* able to
  re-identify after this card than before, which is the point.

## 12. Cross-card invariants for SLDP-P4-1

Restated from [`tombstone-signing-authority.md` §5](./tombstone-signing-authority.md); I6–I8 are
the ones that would otherwise be discovered at P4-GOV.

| # | Invariant |
|---|---|
| I1 | Generations passed to `ProjectReceipt` are tenant-scoped, never per-subject |
| I2 | No generation identifier appears in retained evidence |
| I3 | The confirmation key is never persisted and never enters the crypto-shred boundary — otherwise erasure destroys the proof of its own erasure |
| I4 | `privacy` must not import `privacy/tombstone`; inject via an interface declared in `privacy`, wired in `main.go` |
| I5 | `BucketPopulation` is a real measurement, not a constant |
| I6 | Erasures are batched so ≥`MinAnonymitySet` subjects' rows disappear between any two externally observable corpus states |
| I7 | Tombstones are published as a randomly ordered daily batch under one Merkle root |
| I8 | The `ConfirmationKey` never reaches a response log, trace span, queue or audit projection |

## 13. Verdict

**PASS.** All six deliverables shipped: a schema that structurally cannot carry an identifying or
joinable field; a non-joinability test that attempts the join, fails it, and proves it is not inert
with six positive controls; a documented signing authority separated from the erasure-authorisation
registry; a published statement that no external anchor exists, citing `anchor.py:407`; a
fail-closed population-size check on the coarse timestamp; and a stated resolution of the
non-linkability/auditability tension naming exactly which field confirms a specific erasure and to
whom.

Three limits are published rather than closed (L1, L2, L4), one of which (L2) is a real bypass of
everything this card builds and is owned by SLDP-P4-1 as a scheduling constraint.
