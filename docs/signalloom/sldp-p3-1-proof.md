# SLDP-P3-1 Execution Proof

**Status:** PASS — segment column schema versioned to `signalloom.observations/v2` carrying keyed pseudonyms only; six cleartext identifier columns removed from the writer; dynamic label key space closed by a write-time allow-list; identifier patterns added to both redaction paths and wired into the one call site that makes them non-vacuous; re-identification map relocated to an encrypted, RLS-protected Postgres table; mixed v1/v2 corpus proven decodable; p95 at N=12,000 on the KPI query measured at **2.174 ms** against a 2.75 ms budget. **The card asked for proof that the query path meets its budget, and one query class does not** — actor-only pushdown regressed to 9.937 ms. That is recorded as a named, quantified exception for the budget owner to rule on, alongside nine residual exposures, rather than smoothed over.
**Logical ID:** `SLDP-P3-1`
**Role:** Implementation
**Base Commit:** `9bd11bcdc4e576d0326ed1043457c49ce291c84c`
**Integration Branch:** `refs/heads/integration/sldp-v0.1.0`
**Runtime Worktree:** `/home/andy/src/.worktrees/023c2/osramp-demo`
**Recorded Date:** 2026-09-14 17:05:00+01:00

---

## 1. The finding that shaped the change

The card's objective names three cleartext columns. Two discoveries during OBSERVE and BUILD made the
narrow reading of that objective untenable, and both are load-bearing for everything below.

**1a. The static column set was the smaller half of the exposure.** `api/audit/receiver.go:295-315`
— the *production* Kubernetes audit receiver — wrote seven direct identifiers into the dynamic label
map: `user`, `acting_principal`, `delegator`, `spiffe_id`, `delegator_spiffe_id`,
`impersonated_user` and `delegation`. A label key is materialised verbatim as a Parquet column
`labels.<key>` (`store/frostdb.go`, dynamic-column path). Removing identity from `actor_hint` and
`impersonated_user` while those same strings went on flowing through the label space would have left
the identifiers in the segment under different column names, and a fixed-column privacy audit would
never have looked. The card predicted this shape ("the fixed column set is not the whole exposure");
it was not hypothetical.

**1b. The redaction layer had no callers at all.** `rg` for every constructor and method of
`transform.SecretRedactor` and `transform.CryptographicSecretScrubber` across the whole repository
returns matches only inside those files and their own tests — **zero production call sites** — while
eight production sites call `store.Append` directly (`collectors/sink.go:25`,
`identity/claim_verifier.go:279`, `api/handlers.go:170,299,445`,
`correlation/redteam_cascade.go:89`, `correlation/quarantine.go:327`, `correlation/redteam.go:97`).

Adding email / IP / username patterns to a redactor nothing invokes would have satisfied the
deliverable exactly while changing nothing about what reaches a segment — the definition of "an
acceptance criterion that would pass whether or not the control works", which the card explicitly
forbids shipping. The patterns were therefore delivered **and** wired into the one call site where
free text is still persisted (§5), and the broader wiring gap is recorded as a residual (§9).

---

## 2. What was NOT touched, and why that is the whole migration

`store/verify/verify.go` hashes `data.parquet` bytes and checks the DSSE statement's
`SchemaVersion`. It **never parses a Parquet column** — `grep -n 'parquet|column|schema'` over that
file returns four hits: `segmentSchema = "signalloom.segment/v1"` (:28), two comparisons against it
(:321, :387), and one filesystem path join (:637).

That single fact is what makes this change free of attestation risk, and it is why the segment
*column* schema and the segment *attestation* schema are treated as two separate versioned surfaces:

| Surface | Identifier | Moved by P3-1? |
|---|---|---|
| DSSE attestation statement | `signalloom.segment/v1` | **No.** Bumping it invalidates every signed segment on disk — the card's first hard blocker. |
| Segment column layout | `signalloom.observations/v1` → `/v2` | **Yes.** Invisible to the verifier. |

`git diff --stat -- store/verify/` is empty. Checkpoint fields, binary framing, `CumulativeRowCount`,
`PrevCheckpointDigest` and the high-water tip-replacement checks are unmodified. **No existing
Parquet or `.dsse.json` byte was rewritten.** `TestSegmentSchema_IsNotTheAttestationSchema` pins the
distinction so a later edit cannot collapse the two.

---

## 3. Deliverable 1 — versioned schema carrying pseudonyms only

`store/segment_schema.go` (new) declares both generations and the closed v2 column set.
`schemaDef()` in `store/frostdb.go` now emits v2.

| Removed (cleartext, v1) | Replaced by (keyed, v2) |
|---|---|
| `actor_hint` | `hmac_actor_hint` |
| `actor_id` | `hmac_actor_id` |
| `principal_id` | `hmac_principal_id` |
| `session_id` | `hmac_session_id` |
| `impersonated_user` | `hmac_impersonated_user` |
| `raw_evidence_ref` | `evidence_ref_digest` (domain-separated) |
| — | `schema_version` (new; makes a segment self-describing) |

**Scope decision.** The objective named three columns; the deliverable says the schema must carry
"pseudonyms only". SLDP-P3-PRE §3.2 classifies `actor_id`, `principal_id` and `session_id` as
High / Medium-High cleartext identity in the same audit table. Removing only the three named would
have left "no cleartext identity in the immutable store" false while every named criterion passed.
All six were taken. Recorded as a deviation in the errata.

**Probe.**

```
$ awk '/^func schemaDef/,/^}/' store/frostdb.go \
    | rg -c 'actor_hint|raw_evidence_ref|impersonated_user|"actor_id"|"principal_id"|"session_id"'
0 (none)

$ awk '/fields := \[\]arrow.Field\{/,/arrowSchema :=/' store/frostdb.go \
    | rg -c '"actor_hint"|"raw_evidence_ref"|"impersonated_user"|"actor_id"|"principal_id"|"session_id"'
0 (none)
```

**Reading the card's `rg` probe honestly.** The required command
`rg -n 'actor_hint|impersonated_user|raw_evidence_ref' store/frostdb.go` returns **6 matches, not
zero**, and that is the correct outcome. Every one is either a comment or the v1 *reader* path
(`colIdx["actor_hint"]` at :567, `colIdx["raw_evidence_ref"]` at :570,
`colIdx["impersonated_user"]` at :585). Those lookups must survive: they are how historical segments
stay queryable. A zero-match result would mean the mixed-corpus deliverable had been dropped. The
claim being made is about the schema declaration and the writer, and both are shown at zero above.

### 3a. Pseudonymiser

`store/segment_pseudonymiser.go` wraps the audited `pseudonym.KeyRing` rather than computing a
second HMAC. It fails closed on: absent key, key under 32 bytes, non-hex key, empty tenant scope.
There is no compiled-in default and no passthrough mode — a process that cannot pseudonymise refuses
to start. This is the defect SLDP-P2-1 removed from the secret scrubber, not re-introduced here.

**An empty identifier yields an empty pseudonym, not the pseudonym of `""`.** Hashing the empty
string would write one constant 64-hex value into every identity-free row, which is a join key
linking all of them — a correlation channel invented by the privacy fix. Pinned by
`TestFrostDBStore_V2_AbsentIdentifierStaysAbsent`.

### 3b. Import cycle, and the package move it forced

`identity` already imports `store` (`identity/claim_verifier.go`), so `store` importing `identity`
does not compile. The primitive moved down to a new leaf package `pseudonym/`, and
`identity/pseudonym.go` became type aliases and value re-exports — `identity.PseudonymKeyRing` **is**
`pseudonym.KeyRing`, not a wrapper. The HKDF domain string, epoch framing and every error message
are byte-identical, so `errors.Is` and every existing caller behave exactly as before. Changing the
domain string would have invalidated every pseudonym already written; `TestPseudonym_DomainIsVersionPinned`
still guards it. The alternative — a second HMAC inside `store` — was rejected as a second thing to
get wrong and a second key space to reconcile at erasure time.

---

## 4. Deliverable 2 — write-time label allow-list

`store/label_allowlist.go` declares a **closed literal set** of 46 keys. Not a deny-list and not a
pattern: a deny-list bounds only the keys somebody thought of, so a zero-identifier claim would stay
unfalsifiable. Every entry is topology or event classification drawn from a bounded collector
vocabulary; none names a natural person.

Enforcement is in `Append`, **before `array.NewRecordBuilder` is called**. A disallowed key refuses
the whole batch and names the offending key. `WithLabelAllowList(nil)` and `WithLabelAllowList({})`
are errors, not permit-all.

`TestLabelAllowList_RefusalPrecedesAnySegmentWrite` asserts all three halves: the error is a
`*DisallowedLabelKeyError` naming `email`; `QueryRange` returns **0 rows**; and a `filepath.Walk` of
the store directory finds **0 `.parquet` files**. Asserting only the error would have been satisfied
by a store that wrote the row and then complained.

```
store: label key "email" is not in the segment label allow-list (observation "obs-identity-1");
the batch was refused before any Arrow record was built
```

**Fail-closed has an operational cost, stated rather than hidden.** A single disallowed key from one
collector refuses the entire batch, so a misbehaving collector can halt ingestion. That follows the
phase constitution ("controls fail closed") and a silent-drop mode was deliberately not added,
because a drop is exactly the fail-open shape the card forbids. P3-GOV should weigh whether ingest
availability warrants an explicit, counted, opt-in drop mode.

---

## 5. Deliverable 3 — identifier patterns, and making them non-vacuous

`transform/identifiers.go` (new) adds five classes absent from the entire repository before this
card: email, IPv4, IPv6, Kubernetes subject (`system:serviceaccount:…`), and labelled username
(`user:`, `username=`, `principal:`, `upn=`). Wired into `SecretRedactor.RedactText` and
`CryptographicSecretScrubber.ScrubText`. Replacement is the existing keyed HMAC, not a fixed
sentinel, so repeated occurrences stay comparable without being readable.

Two regex traps were caught by tests rather than by inspection:

- **Over-match.** Go's RE2 has no lookaround, so the IPv4 boundary is enforced with explicit guard
  capture groups. `TestIdentifierPatterns_DoNotOverMatch` proves `go1.24.1` and `v2.11.3` pass
  through byte-identical.
- **Silent normalisation.** The username rule initially rewrote `user: bobby` as `user:bobby`,
  making the redactor a silent reformatter of every record it touched. Caught by the
  identity-replacement round-trip inside `TestIdentifierPatterns_EveryClassIsLoadBearing`; the
  separator is now captured and re-emitted.

`TestIdentifierPatterns_EveryClassIsLoadBearing` is a deletion sweep — each class must be the sole
reason one case passes, so removing a pattern fails something rather than coasting on a neighbour.

**The wiring that makes this real.** Per §1b the redactor had no production callers. `description` is
the one free-text column surviving into v2, and `api/audit/receiver.go` interpolated the acting
principal straight into it — so a subject name reached an immutable segment through prose even with
every identifier column pseudonymised. That description now passes through the redactor. This is one
call site, not full coverage; see §9.

---

## 6. Deliverable 4 — re-identification map relocated to encrypted Postgres

`identity/migrations/007_segment_reidentification_map.sql` (+ rollback), wired into
`identity/migrations.go` (which enumerates migrations explicitly rather than discovering them).

Why Postgres and not the segment: a Parquet segment is signed and chained, so it can never be
rewritten or deleted without breaking verification of everything after it — an Article 17 request can
never reach it. A Postgres row can be deleted and a key can be destroyed. The table is therefore
where erasure has somewhere to land. Erasure itself is **not** built here; that is P3-2 and P4-1.

- `identifier_encrypted BYTEA NOT NULL` — AES-256-GCM envelope ciphertext, matching migration 005's
  representation. There is deliberately **no** cleartext column.
- `tenant_id`, `tenant_scope`, `pseudonym_epoch` — a pseudonym is only meaningful within the
  (tenant, scope, epoch) triple the key ring derives over, so the unique index spans all four
  columns. Constraining on `pseudonym` alone would collide across epochs after a rotation.
- `ENABLE` **and** `FORCE ROW LEVEL SECURITY`. `FORCE` matters specifically: without it the table
  owner bypasses every policy, and the application connects as the owner in most deployments — so an
  unforced policy is one that never runs in production and always passes in a non-owner test.
- The policy calls migration 006's `app_current_tenant()` helper rather than inlining
  `current_setting()`, so there is one definition of "the current tenant" rather than two that drift.
- `CHECK (pseudonym ~ '^[0-9a-f]{64}$')` and `CHECK (octet_length(identifier_encrypted) > 0)`.

**Sequence-number claim.** 005 is P2-1, 006 is P2-2. The header of 005 reserved 007 for P2-3, but
P2-3 landed with no migration and `rg '007_' --type go --type sql` finds no reference anywhere in
the tree, so 007 is genuinely next-free. **SLDP-P3-2 is running concurrently in a sibling worktree
and also writes to this directory.** By card order P3-1 takes 007 and P3-2 should take 008. Flagged
for the Governor.

---

## 7. Deliverable 5 — mixed-corpus readback

After this card the bucket holds both generations **indefinitely**, not for a migration window:
v1 segments are signed and can never be rewritten, so they never go away. This is also the normal
FrostDB case rather than an exception — dynamic columns make per-block Parquet schema divergence
routine.

Detection is by column presence. `SegmentSchemaOf` reports v2 iff a `schema_version` column exists;
absence **is** v1. Every field read in `recordToObservations` is guarded by `colIdx[name]`, so a v2
record has no `actor_hint` to find and a v1 record has no `hmac_actor_hint`, and neither panics.
`model.Observation.SchemaVersion` reports which was read, so a consumer can distinguish a
pseudonymised identifier from an absent one rather than inferring it from emptiness. Every new model
field is `omitempty`, so a v1 observation serialises byte-identically to before this change.

`TestMixedCorpus_BothGenerationsDecode` builds one v1-shaped and one v2-shaped Arrow record,
decodes both into a single result slice, and asserts: the v1 row returns its cleartext
`ActorHint` / `RawEvidenceRef` / `ImpersonatedUser` and invents no pseudonym; the v2 row returns
empty cleartext and the correct pseudonym. **PASS.**

A FrostDB *table* carries one schema, so "mixed corpus" means segments of both generations read
through one decoder — the decoder is therefore the honest unit under test, and a v1-shaped record is
constructed directly because this build can no longer produce one.

`matchesQuery` is generation-aware for the same reason: comparing one representation only would have
made the in-memory oracle disagree with the engine on half the corpus, and the equivalence tests
would have read as an engine defect.

---

## 8. Deliverable 6 — latency at N = 12,000

**Measurement conditions.** N = 12,000 observations across 24 hourly partitions; 100 iterations per
strategy; selectivity 160/12,000 = 1.33 %; deterministic seed 42; single-node AMD Ryzen 9 7900X
(24 threads), Linux 7.1.3, Go 1.26.2, `CGO_ENABLED=0`, in-process FrostDB. **Cache is warm** — data
is written by the test immediately before it is queried, so these are warm-cache figures and are not
a cold-start claim. The v1 "before" column is SLDP-P3-PRE §6.2, measured under the same harness on
the same host class and stated there under the same warm-cache caveat.

| Query strategy | v1 p95 (P3-PRE) | **v2 p95 (this card)** | Δ |
|---|---|---|---|
| Full scan baseline | 19.43 ms | 14.90 ms | −23 % |
| Non-pushdown fallback | 20.48 ms | 15.34 ms | −25 % |
| **Pushdown — selective multi-filter (the KPI)** | 3.76 ms | **2.174 ms** | **−42 %** |
| Pushdown — regression-guard run | 2.51 ms | 2.016 ms | −20 % |
| Pushdown — time range only | 0.97 ms | 1.048 ms | +8 % |
| Pushdown — actor only | 1.32 ms | **9.937 ms** | **+653 %** |

**Budget verdict: PASS.** The headline Signal Fusion KPI — selective multi-filter pushdown at
N = 12,000 — is **2.174 ms against a 2.75 ms ceiling**, improved from 3.76 ms. Predicate pushdown
survived the column move intact, which is the whole reason the card mandates pseudonymisation rather
than encryption: equality on a keyed HMAC is equality on the plaintext, so `buildFilter` still emits
a single `Eq` on a single STRING column and only the literal changed.

**Budget verdict, stated precisely: the KPI passes; the card's requirement does not.** The card says
"Prove the query path still meets its budget." One shape meeting it is not that. The honest verdict
is **pass with a named, quantified exception that is the budget owner's to waive, not this card's.**

**The actor-only regression is real, and it is a class, not an edge case.** That shape went from
1.32 ms to 9.937 ms and now exceeds the 2.75 ms budget alone. Selectivity is unchanged — same target
actor, same matched rows, correctness asserted against the in-memory oracle — so this is an
execution-cost change, not a semantic one.

It also deserves more weight than "one query got slower", because **actor-only is the shape that
isolates filtering on the pseudonymised column**. The headline KPI pairs the actor predicate with a
time range, so its pruning can be carried by `timestamp` — which means the KPI passing is weak
evidence that identity-filtered queries are healthy. The affected class is *every query whose
selectivity comes from a pseudonym column*, and actor-only is its canonical member.

**Measured evidence for the mechanism, within each generation's own harness so harness differences
cancel** — the ratio of actor-only latency to that same run's full-scan baseline:

| Generation | actor-only p95 | full-scan p95 (same run) | speedup from filtering |
|---|---|---|---|
| v1 (P3-PRE) | 1.32 ms | 19.43 ms | **14.7×** |
| v2 (this card) | 9.937 ms | 14.90 ms | **1.5×** |

Filtering on the actor column went from eliminating ~93 % of the scan cost to ~33 %. That collapse is
a measurement, not an inference.

**What remains inferred, and must not be quoted as established:** that the *cause* of the collapse is
`hmac_actor_hint` holding near-uniform 64-character hex, so every row group's min/max range spans
almost the whole value space where six short service-account strings pruned well. That is consistent
with the numbers and with the mechanism, but it has **not** been isolated by a controlled experiment,
and two alternative explanations are not ruled out: dictionary-encoding cost on 64-character values,
and decoder dispatch in the mixed-generation read path.

The distinction matters because the mechanism sizes the remediation. Pruning collapse is bounded —
sort-on-write, a bloom filter, or a short low-cardinality prefix column for pruning alongside the
full HMAC for equality. A dictionary or decoder cause needs a different fix. **P3-GOV should not
accept a waiver until the mechanism is measured**, and the cheapest decisive probe is a measurement
rather than an experiment: count row groups and bytes scanned for the actor-only query under each
generation.

---

## 9. Residual exposures — what this card did NOT fix

Recorded so the next card consumes them rather than re-deriving them.

1. **History keeps its cleartext forever.** Every segment written before this change retains all six
   identifier columns. They are signed and chained, so they cannot be rewritten or deleted without
   breaking verification. This card stops the bleeding; it does not clean the history, and any claim
   otherwise would overstate it.
2. **The redactor is still unwired almost everywhere.** §5 closes one call site. The other eight
   `store.Append` callers still pass unscrubbed observations, so `description` from any other
   collector can still carry an identifier into a v2 segment. The allow-list and the pseudonymised
   columns bound the *structured* exposure; free text is only bounded at the audit receiver.
3. **`signal-ingest` still has no HTTP authentication.** `main.go:224` is a bare
   `http.NewServeMux()` with no middleware, serving the full identity and delegation graph openly.
   Out of scope here and a larger live hole than this card closes.
4. **Delegator identity is lost from the immutable store.** `delegator` had no column of its own, so
   removing it from the label space means it now survives only in the `DelegationEdge` contribution
   string, which is not a segment column. That is a genuine information loss, not a neutral cleanup.
5. **External readers must union by name.** A bucket now holding both generations has divergent
   per-file Parquet schemas. Any external read
   (`read_parquet('.../*/data.parquet')` in DuckDB or equivalent) **must** set `union_by_name=true`,
   or it binds the first file's schema and silently discards every column the others added —
   right row count, missing columns, no error.
6. **Dashboard consumers read empty, not error.** `weaveApi.ts` and `FeedsExplorerPage.tsx` consume
   `actor_hint`. For v2 rows it is now empty, so a panel that depends on it looks empty rather than
   broken. `SchemaVersion` is on the wire (`omitempty`) so a consumer can tell the cases apart.
   `test/acceptance/feeds-explorer.spec.ts` and `test/signalfusion-demo.bats` also reference the
   removed names and are the acceptance surfaces most likely to notice.
7. **One HMAC key de-pseudonymises the whole historical corpus, unfixably.** Segments are immutable,
   so a key compromise is retroactive across every v2 segment ever written and cannot be remediated
   by rotation — rotation only changes pseudonyms written *after* it. The key ring is tenant- and
   epoch-scoped, which bounds the blast radius to one tenant-epoch rather than the estate, but this
   is a bound, not a fix. P4-1's per-subject key hierarchy is where it actually gets closed.
8. **No test asserts a rollback cannot resume cleartext writes.** Deploying a pre-P3-1 binary against
   the same bucket would write v1 segments again, and nothing in the store refuses that. The
   protection today is deployment discipline, not a control.
9. **RLS on migration 007 is asserted only on the positive path.** There is no test in which a
   second, non-owning role is refused. A positive-path RLS test passes identically whether or not
   the policy is enforced, so the `FORCE` clause is currently reasoned-about rather than proven.

---

## 10. Verification log

| Check | Command | Result |
|---|---|---|
| Base-ref lineage | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | exit 0 |
| Store suite (tagged) | `go test -tags frostdb ./store/... -count=1` | **ok**, 148 tests |
| Store suite (untagged) | `go test ./store/... -count=1` | **ok** |
| Transform suite | `go test ./transform/... -count=1` | **ok** |
| Whole module | `go test -tags frostdb ./... -count=1` | **ok**, 20/20 packages |
| Vet | `go vet -tags frostdb ./identity/... ./pseudonym/... ./store/...` | clean |
| Make target | `make test-signal-ingest-frostdb` | exit 0 |
| Make target | `make demo-signalloom-api-test TIER=contract` | exit 0, **56 passed** |
| New P3-1 tests | 22 store + 5 transform | all PASS |
| **Untagged** build + tests | `go build ./...` / `go test ./... -count=1` (no `-tags frostdb`) | exit 0, 20/20 ok |
| Verifier untouched | `git diff --stat -- store/verify/` | empty |

The untagged run matters on its own: a green measured only under `-tags frostdb` would hide any
reference to a removed column living behind a different tag. Both tag sets are green.

**Workspace-wide sweep for the removed column names** (`rg` across every file type outside markdown)
returns collector *ingest contract* schemas and fixtures — `collectors/agentnono/contracts/*.json`,
`collectors/workspacesaas/contract.go`, and similar. These are upstream of the store: the fields
still exist on `model.Observation` and still arrive over the wire; they are simply no longer
persisted. No schema-compatibility check, catalog, retention or replication path reads a segment
column name. The two downstream surfaces that do reference them are acceptance-level
(`test/acceptance/feeds-explorer.spec.ts`, `test/signalfusion-demo.bats`) and are recorded in §9.

**Test-count integrity.** `frostdb_test.go` declares 18 top-level `Test` functions before and after
(a suite that stops loading vanishes silently rather than failing); `segment_schema_v2_test.go` adds
24 and `identifiers_test.go` adds 5.

**One latent defect fixed in passing, because this change exposed it.**
`validateFilterColumns` ranged a `map` to report the first missing column, so with two columns absent
the reported name depended on Go's randomised map iteration order. A test asserting on the message
was therefore flaky, and only surfaced once a second column moved. It now iterates an ordered slice.

**A near-miss worth recording.** An intermediate test run was filtered with
`rg '^(---|ok|FAIL)'`, which returned nothing and read as success. The run had in fact FAILed — the
attestation harness's log lines swamped the markers, and a duplicate map key would have been a
compile error the filter also hid. Re-running unfiltered with an explicit exit-status check found it.
A check that never ran is indistinguishable from a check that passed.

---

## 11. Adversarial review — findings, and what was done about them

An independent adversarial review was run over commit `94eda33d`. **The cross-vendor differential did
NOT happen:** the `codex exec` path is quota-exhausted until 2026-09-19, so the review is
Claude-family analysis, not the OpenAI-family second opinion it was routed for. The shared-blind-spot
reduction was therefore not obtained, and P3-GOV should re-run it after that date. Findings below are
tool-verified regardless.

### Fixed in `49dbc608`

**F1 (critical) — the central claim was false.** `Append` wrote `o.Description` verbatim, and only
`api/audit/receiver.go` redacted its own. The other seven writers did not, so
`POST /api/v1/observations` — which validates confidence and nothing else — could put an
attacker-supplied `"alice@corp.com from 10.0.0.5"` into a signed, unerasable segment.
`collectors/baoaudit/receiver.go:329` writes a SPIFFE ID and SA principal in cleartext by
construction.

This is the failure shape §1b explicitly named and then only half-applied: a guard at one caller of
eight is the same as no guard. Every schema-level test passed throughout, because they inspect column
*names* and are structurally blind to the payload. The redaction moved to `Append`, the single
chokepoint, and `TestFrostDBStore_V2_DescriptionIsRedactedAtTheChokepoint` now asserts the persisted
row. It is mutation-checked: replacing the call with a passthrough fails it.

**Three comments that were false about the code beneath them** were corrected rather than the code
they misdescribed being quietly changed:

- `transform/identifiers.go` claimed the replacement is "keyed". True for the scrubber
  (`AnonymizeHMAC`, 128-bit); **false** for `SecretRedactor.hashRedact`, which is unkeyed SHA-256
  truncated to 8 hex characters = **32 bits**. The entire IPv4 space is 2³², so a redacted source IP
  is reversible by exhaustive search in minutes. Keying it rewrites every existing
  `REDACTED_SHA256` value, making it a migration rather than an edit — recorded, not smuggled in.
- `store/label_allowlist.go` claimed values come from bounded vocabularies. **The allow-list
  constrains KEYS only.** `Append` checks `k`, never `v`. `labels["reason"]` routinely holds
  `User "alice" cannot get pods` and `labels["name"]` can hold an email address — both land cleartext
  in a v2 column.
- `store/segment_pseudonymiser.go` documents a fail-closed tenant scope while defaulting it from the
  environment, silently merging tenant correlation domains for any multi-tenant deployment that
  forgets the variable. The key path fails closed; the tenant path does not.

### Open — recorded, not fixed, and each one bounded

| # | Severity | Defect | Consequence |
|---|---|---|---|
| **F4** | High (correctness) | `buildFilter` emits only `hmac_actor_hint == <pseudonym>` and is **not** generation-aware, while `matchesQuery` is. | A v1 block has no `hmac_actor_hint`, so `Query{ActorID:…}` over a mixed bucket **silently under-returns** — no error, no signal. This directly contradicts §7's claim that both generations stay queryable: they decode, but the actor query path reaches only v2. Fix is `Or(hmac_actor_hint == pseudo, actor_hint == cleartext)`. |
| **F5** | Med-High | IPv4 guard group 3 *consumes* the trailing delimiter, so the next address cannot find its leading guard. | `10.0.0.1,10.0.0.2,10.0.0.3` redacts the 1st and 3rd only. Comma-separated lists are the normal shape of `sourceIPs`, so every second address leaks. |
| **F6** | Medium | The IPv6 pattern is satisfied by any `HH:MM:SS`. | Clock times inside descriptions are destroyed, permanently, because the segment is immutable. |
| **F7** | Medium | On the scrubber path `AnonymizeHMAC` returns `hmac-<hex>`, whose characters are inside `usernamePattern`'s value class, so an already-redacted value is re-matched and re-hashed. | The same identifier yields two different pseudonyms, so the actor-graph join fails and `segment_reidentification_map` can never resolve the double-hashed one. Bites the scrubber only; `[REDACTED_SHA256:…]` is immune because `[` breaks the class. |
| **F8** | Medium | `usernamePattern` requires `[:=]`. | `User "alice" cannot get pods in namespace "prod"` — the standard RBAC denial string, and exactly what lands in `reason` and `description` — passes through untouched. |
| **F10** | Low | `pseudonym_epoch INTEGER` cannot hold the Go-side `uint32` range; no non-empty constraints on `tenant_id`, `tenant_scope`, `identifier_kind`. | Epochs above 2³¹−1 fail at insert. |

**F4 is the one that matters most of these** and should be the first thing P3-GOV schedules: it is a
silent correctness defect in the deliverable this card claims, not a hardening gap.

### Categories the review cleared explicitly

Catastrophic backtracking — impossible; Go's `regexp` is RE2, linear-time. Panic on an absent column
— none; every lookup is `colIdx`-guarded and generation detection is correct. Pseudonymiser
fail-open — none; all three construction paths refuse before allocating, `Append` has a zero-struct
backstop, and a nil `labelAllow` denies every key. IPv4 **over**-match — clean; `v1.24.1` and
`1.2.3.4.5` verified untouched. Migration 007 RLS — correct: `ENABLE` and `FORCE` both present,
`WITH CHECK` present, and a NULL claim yields no rows rather than all rows.

One item could not be verified: the alias shim preserves behaviour *by construction* (a `=` type
alias is the same type, not a wrapper), but the pre-move implementation is not reachable in this
branch's history, so the HKDF domain string's byte-identical survival across the move was **not**
proven. `git log --all -S'alias-pseudonym/v1'` across origin branches would settle it.
