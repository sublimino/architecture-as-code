# SLDP-P2-1 Execution Proof — Keyed HMAC Pseudonyms and Envelope-Encrypted Alias Values

**Card:** SLDP-P2-1 · **Phase:** 2 · **Role:** implementation
**Integration branch:** `integration/sldp-v0.1.0`
**Worktree:** `/home/andy/.cline/worktrees/ddfcb/osramp-demo` (isolated runtime worktree; principal checkout untouched)

---

## 1. What was wrong

`AESGCMEncryptor.Hash` (`identity/encryption.go:135-138`, pre-change) computed a bare
`sha256.Sum256` over the alias value with **zero key material**:

```go
func (e *AESGCMEncryptor) Hash(value string) string {
    sum := sha256.Sum256([]byte(value))
    return hex.EncodeToString(sum[:])
}
```

The alias population is small and highly predictable — corporate emails, usernames, SPIFFE IDs
from a known cluster namespace. An unkeyed digest over such a population inverts by rainbow table.

The pseudonym was also redundant, because the re-identification map was the row itself:

| Artefact | Location | Held |
|---|---|---|
| `alias_value VARCHAR(512) NOT NULL` | `001_identity_graph.sql:20` | cleartext identifier |
| `alias_value_hash VARCHAR(64)` | `001_identity_graph.sql:21` | unkeyed SHA-256 of the same string |
| `idx_aliases_value_temporal` | `001_identity_graph.sql:50` | **index on the cleartext** |
| `idx_aliases_idempotent_seed` (UNIQUE) | `003_idempotent_seeding.sql:4` | **index on the cleartext** |

Note the contrast that makes this a defect rather than an oversight: `actors.metadata` and
`delegations.metadata` were already `BYTEA` and encrypted. The *metadata* was protected; the
*actual identifiers* were not.

Separately, `transform/secrets_scrubber.go:56` defaulted to a salt literal committed in public
source whenever none was configured. A pseudonymisation secret in git is public, so every
deployment that never set the variable shared one attacker-known key — and under GDPR Article 4(5)
such a secret is not "kept separately".

---

## 2. What was built

### 2.1 Keyed pseudonym primitive — `identity/pseudonym.go` (new)

`PseudonymKeyRing` derives a per-tenant key with `crypto/hkdf` (Go 1.24 stdlib — **no new module
dependency**) and computes `HMAC-SHA256(tenantKey, value)`.

The HKDF `info` parameter is:

```
BE32(len(domain)) || domain || BE32(epoch) || BE32(len(tenant)) || tenant
domain = "signalloom/identity/alias-pseudonym/v1"
```

Every variable-length field is length-prefixed and every scalar is fixed-width, so the byte string
parses back to exactly one `(epoch, tenant)` pair. Without the length prefix, tenant `"ab"` and
tenant `"a"` followed by a value beginning `"b"` could serialise identically and silently merge two
tenants' correlation domains. `TestPseudonym_TenantBoundaryIsUnambiguous` probes that boundary
directly rather than trusting the construction to be prefix-free by inspection.

**Scope rationale.** The pseudonym is a *join key*: the actor graph resolves aliases by comparing
pseudonyms, so it must be deterministic for a given `(tenant, epoch, value)`. A per-row random salt
would be cryptographically stronger and functionally useless. A single global key would be
deterministic but would let one tenant's pseudonym set be compared against another's. Tenant-and-
epoch is the smallest scope that preserves the join.

**Fail-closed, with no legal error value.** Empty/short root key, empty tenant and empty value each
return an error and `""` *together*. Returning `""` with a nil error would make "no pseudonym"
indistinguishable from "this identifier legitimately has none", which is how a control fails open.

### 2.2 Envelope encryption with row binding

`Encryptor` gains `EncryptEnvelope(plaintext, aad)` / `DecryptEnvelope(envelope, aad)`.
Wire format: `[version:1][wrappedDEKLen:2 BE][wrappedDEK][body]`. A fresh 32-byte data key per
record, wrapped under the root key; both seals bind AAD.

`AliasEnvelopeAAD(actorID, aliasType, pseudonym)` binds each ciphertext to its row. **This is not
decoration.** Without it, an attacker holding `UPDATE` on `aliases` can copy
`alias_value_encrypted` from row A into row B; it decrypts perfectly, the row's pseudonym column
now disagrees with the plaintext, and nothing cross-checks the two. Since the pseudonym is itself
`HMAC(tenantKey, aliasValue)`, binding to it binds the ciphertext to the tenant *and* the plaintext
in one move. `TestAliasEnvelope_RejectsCrossRowSubstitution` proves the substitution now fails.

`wrappedDEKLen` is pinned to the single legal value (12 nonce + 32 key + 16 tag = 60), turning a
16-bit attacker-controlled field into a checked constant. Every rejection path returns
`ErrInvalidEnvelope`, so a caller checking one error class cannot miss another.

**Dev mode weakens encryption, never pseudonymisation.** `NoopEncryptor` computes real keyed
pseudonyms from an ephemeral per-process key, and *refuses* a real envelope rather than returning
its raw bytes as an "alias value" with exit 0.

### 2.3 Schema — `005_pseudonymisation_and_encryption.sql` (new)

Sequence `005`, as reserved for this card by SLDP-P2-PRE §3.2. **No `006_*` or `007_*` file was
created.**

- `alias_value_encrypted BYTEA` added; `alias_value` loses `NOT NULL`.
- `idx_aliases_value_temporal` and the UNIQUE `idx_aliases_idempotent_seed` **dropped** — leaving
  them would keep the identifier readable from index pages after the heap column is nulled.
- `idx_aliases_idempotent_seed_pseudonymous` UNIQUE on `(actor_id, alias_type, alias_value_hash,
  valid_from)` replaces the cleartext uniqueness constraint.
- `chk_aliases_pseudonymised` added `NOT VALID`, promoted to validated by the Go backfill once
  every row conforms, so a half-migrated table is visibly half-migrated.
- `alias_value_hash` is `VARCHAR(64)`; an HMAC-SHA256 hex digest is exactly 64 characters, so the
  btree key width is unchanged and nowhere near the ~2704-byte index key limit.

### 2.4 The never-merge invariant — the fail-open that had to be closed here

`check_never_merge_alias()` (`001:63-93`) compared `NEW.alias_value` against
`delegations.principal_actor_id`/`delegate_actor_id`. Once the backfill nulls `alias_value`, those
`EXISTS` clauses can never match: the trigger reports success while checking nothing.
`check_never_merge_delegation()` (`001:95-114`) reads `aliases.alias_value` and has the identical
exposure. SLDP-P2-PRE §4.2.2 names this hazard exactly.

**Two candidate resolutions were considered and one was rejected.**

*Rejected:* move the check into Go in `PostgresRepository.AddAlias`, and narrow the trigger to
well-formedness (pseudonym is 64-hex, ciphertext non-NULL). This does not work, for three reasons.
A well-formedness check is a *different invariant* — it says nothing about whether an alias equates
a delegate with its principal, so counting it as mitigation is a substitution that makes the plan
merely look safe. A Go `SELECT`-then-`INSERT` pair is a read-then-write race: two concurrent
connections, one adding the alias and one adding the delegation, each read before the other writes
and both are admitted. And it covers one writer only — `psql`, the backfill, any future service
bypasses it, where the trigger covered all of them.

*Adopted:* re-pin the invariant **in pseudonym space**. The comparison never required the database
to *compute* a pseudonym. `alias_value` and `principal_actor_id` are both actor-ID-shaped strings
in the same namespace under the same tenant key, and HMAC is a function, so:

```
alias_value = principal_actor_id  ⟺  HMAC(k, alias_value) = HMAC(k, principal_actor_id)
```

Equality in pseudonym space **is** equality in cleartext. Migration 005 adds Go-written columns
`delegations.delegate_actor_pseudonym` / `principal_actor_pseudonym`; both triggers compare two
opaque 64-character strings. **No key enters the database**, and the check stays inside the
`INSERT`'s own transaction — atomic, covering every writer.

**Scope note, stated plainly.** Pinning never-merge was nominally SLDP-P2-3 (`007`, marked
"optional / if trigger replacement"). It is done here because (a) the card lists "any control that
fails OPEN" as a hard STOP blocker, and (b) SLDP-P2-PRE §4.2.3 requires the pinning be established
*before* P2-1's schema alterations land — so deferring it would have contradicted the plan of
record, not followed it. P2-3 should treat the trigger work as done and re-scope to negative
assertion coverage. See §7.

### 2.5 Committed salt removed

`NewCryptographicSecretScrubber` now returns `(*CryptographicSecretScrubber, error)` and refuses an
absent or under-16-character salt. There is no safe default, so there is no default.
`NewCryptographicSecretScrubberFromEnv` reads `SIGNAL_SCRUBBER_SALT` and errors when unset.

The literal is deliberately **not** quoted in the source comment. A grep for it is the check that
the defect is gone, and a comment quoting it would satisfy that grep while proving nothing.

**Additional finding, fixed.** `AnonymizeHMAC` truncated its digest to 16 hex characters — 64 bits.
Over a small enumerable identifier population that is brute-forcible regardless of key secrecy,
which would have made the salt fix cosmetic. Widened to 32 hex characters (128 bits).

---

## 3. Test evidence

All commands run from the isolated worktree.

### 3.1 Card-required commands

| # | Command | Result |
|---|---|---|
| R1 | `go test ./identity/...` | `ok … 0.386s` |
| R2 | `rg -n 'sha256.Sum256' identity/encryption.go` | 2 hits, **both key-derivation**: `:151` (comment) and `:163` (32-byte key stretch in `NewAESGCMEncryptorWithKeys`). **Zero identifier-hashing sites.** |
| R3 | `rg -n 'signal-loom-default-identity-salt' transform/secrets_scrubber.go` | **no matches** |
| R4 | `go test -run TestAlias ./identity/...` | **10 tests PASS** (non-vacuous — a zero-match filter would exit 0 and prove nothing) |
| R5 | `make test-signal-ingest` | **EXIT=0 — 539 PASS / 0 FAIL / 7 SKIP**, 22 packages ok |
| — | `bats test/acceptance-spec-coverage.bats` | all pass |

The only surviving occurrence of the removed salt literal anywhere in Go source is
`identity/pseudonym_test.go:298`, where it is used as an **attacker key guess** in the dictionary
attack. That is the correct place for it.

### 3.2 Adversarial dictionary attack

`TestAliasPseudonym_ResistsDictionaryAttack` — not skipped, not env-gated, not short-circuited.

```
pseudonym_test.go:247: candidate directory: 1446 plausible identifiers
pseudonym_test.go:276: positive control: unkeyed SHA-256 inverted 6/6 secrets
                       — the removed scheme is breakable as claimed
pseudonym_test.go:333: keyed HMAC: 0/6 secrets inverted against 1446 candidates
                       across 5 key guesses
--- PASS: TestAliasPseudonym_ResistsDictionaryAttack (0.01s)
```

The positive control is the point. It runs the same attack against the **scheme this card removed**
and asserts it *succeeds*. If it did not, the attack harness would be broken and the negative
result below it would prove nothing. The candidate directory contains every value in
`FixtureAliases`, so the attack is given every advantage. Key guesses include the deleted public
default salt.

`TestAliasPseudonym_CrossTenantSetsAreDisjoint` — 0 collisions across an identical 1,446-value
population under two tenants.

### 3.3 Live Postgres — the layer that previously had zero coverage

Before this card, **no test in the repository executed `PostgresRepository`'s alias SQL**.
`pool_sharing_test.go` is the only test constructing `NewPostgresRepository`; it uses an
unreachable DSN, `lib/pq` connects lazily, and it only compares `*sql.DB` pointers — no statement
ever ran. Migration 005, the `ON CONFLICT` target, the NULL-column scan, the index drops and both
triggers would all have been entirely unasserted.

`identity/alias_pg_live_test.go` (new) closes that. Run against `postgres:16-alpine`:

```
--- PASS: TestAliasPG_GateIsHonest
--- PASS: TestAliasPG_MigrationEncryptsEveryExistingRow (0.36s)
    pre-migration: 6 rows holding cleartext alias_value
    backfill report: scanned=6 rewritten=6 remaining_cleartext=0 missing_ciphertext=0
    post-migration: 0 cleartext rows, 6 rows round-tripped, lookup resolved 1
--- PASS: TestAliasPG_RollbackRestoresCleartext (0.36s)
    rollback data pass: scanned=1 restored=1
    rollback verified: cleartext restored, 2/2 indexes rebuilt, ciphertext column dropped
--- PASS: TestAliasPG_CleartextIndexesAreGone (0.36s)
--- PASS: TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace (0.31s)
    never-merge enforced at the database layer in pseudonym space:
    pq: structural never-merge invariant violated: cannot alias actor actor-delegate
    to its delegation counterparty (pseudonym 9cbabbd0a9c8…) (23514)
--- PASS: TestAliasPG_TriggerRejectsUnpseudonymisedInsert (0.36s)
    null pseudonym / malformed pseudonym / missing ciphertext — all rejected
ok … 1.754s
```

Migration counts asserted **against the database**, not against the backfill's own report:

```
 rows  | cleartext | ciphertext
-------+-----------+------------
 12000 |         0 |      12000
```

**Honest statement of the coverage limit.** These tests require `SLDP_PG_DSN` and **SKIP** in CI.
A green CI run is therefore *not* evidence that they passed — the alias SQL still executes zero
times in the lane that gates merge, which is the very defect this suite was written to fix, now
wearing a green tick. `TestAliasPG_GateIsHonest` always runs and logs that gap explicitly, so a
skipped verification cannot be mistaken for a passed one. The run recorded above was manual, on
2026-09-14, against a throwaway `postgres:16-alpine` container.

**Naming the skips.** `make test-signal-ingest` reports **539 PASS / 0 FAIL / 7 SKIP**. All seven
skips are the live-Postgres tests in this file, by name:
`TestAliasPG_MigrationEncryptsEveryExistingRow`, `TestAliasPG_RollbackRestoresCleartext`,
`TestAliasPG_CleartextIndexesAreGone`, `TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace`,
`TestAliasPG_TriggerRejectsUnpseudonymisedInsert`, `TestAliasPG_DuplicateAliasStillRefused`,
`TestAliasPG_NeverMergeSurvivesEpochRotation`. With `SLDP_PG_DSN` exported, the identity package
runs **67 tests, all passing**.

**Standing up a Postgres service in the merge-gate CI lane is the single highest-value follow-up
from this card** and is recommended to the phase Governor.

**A real defect was found only by this suite.** The first rollback run failed:

```
pq: pseudonymisation invariant violated: alias_value_encrypted must not be NULL
    for actor actor-rb (23514)
```

The 005 trigger is `BEFORE INSERT OR UPDATE`, so the fail-closed arm fired on the *rollback's own*
UPDATEs — the rollback's entire job is to produce rows with NULL ciphertext. `RollbackAliasEncryption`
now drops the trigger inside its transaction; the rollback SQL re-creates the original trigger as
its first act. No static test could have found this.

### 3.4 Lookup latency — measured, with conditions stated

Conditions: `postgres:16-alpine` in Docker, 12,000 alias rows on one actor, `ANALYZE` run, loopback
TCP on the dev host, single connection, `go test -bench -benchtime=2000x`.

| | Plan | Execution | Buffers |
|---|---|---|---|
| **Before** — `WHERE (alias_value = $1 OR alias_value_hash = $2)` with both cleartext indexes | `Bitmap Heap Scan` ← `BitmapOr` of 2 index scans | **0.072 ms** | 6 |
| **After** — `WHERE alias_value_hash = $1` | `Index Scan using idx_aliases_pseudonym_temporal` | **0.022 ms** | 3 |

End-to-end `FindAliasesAsOf` including envelope decrypt: **191,948 ns/op ≈ 0.19 ms** at 12,000
rows, 2,000 iterations.

The change **improves** the lookup. Dropping `idx_aliases_value_temporal` would have been a serious
regression had the `alias_value = $1` disjunct survived — Postgres cannot serve an OR across two
columns from one index, so the query would have degraded to a sequential scan. Removing the
predicate and the index in the same commit is what makes the drop safe.

Note on a figure in circulation: the "~22 µs/lookup" cited elsewhere in these docs comes from
`sublinear_test.go`, which scans a Go slice in `MemoryRepository` and never touches Postgres. It
was never evidence about the indexed path. The numbers above are.

### 3.5 Mutation checks — proof the tests can fail

Each mutation was applied to a backed-up copy, the suite run, and the file restored; restoration was
verified and the full suite re-run green afterwards.

| Mutation | Guard | Result |
|---|---|---|
| `Pseudonym` reverted to unkeyed `sha256.Sum256` | `TestAliasPseudonym_ResistsDictionaryAttack` | **FAILED** — inversions detected |
| Pseudonym-space comparison removed from the 005 trigger (`WHERE false`) | `TestAliasPG_NeverMergeTriggerStillFiresInPseudonymSpace` | **FAILED** — `FAIL OPEN: the database accepted an alias equating a delegate with its principal` |
| AAD reduced to a constant (row binding removed) | `TestAliasEnvelope_RejectsCrossRowSubstitution` | **FAILED** — `cross-row substitution accepted, yielding "alice@corp.internal"` |

A fourth control is mutation-proven by construction rather than by a separate run:
`TestAliasPG_NeverMergeSurvivesEpochRotation` performs the naive rotation itself and **asserts the
hazard is observable** before asserting the fix restores enforcement, so it is its own mutation.

### 3.7 Guards added for invariants the implementation silently depends on

- `TestAliasAAD_NoWritePathMutatesBoundColumns` — the AAD binds `(actor_id, alias_type, pseudonym)`,
  so any future `UPDATE aliases SET actor_id = …` would make that row's ciphertext permanently
  undecryptable. No such path exists today; this test makes that a checked invariant rather than a
  coincidence, and fails the moment someone adds a re-parenting path in this identity **graph**.
- `TestAliasPG_DuplicateAliasStillRefused` — 005 drops the UNIQUE index that enforced alias
  uniqueness on cleartext. Without this test, a failure of the pseudonymous replacement to take over
  would have deleted a dedup/integrity control while the card described itself as a privacy
  improvement, and every other test here would still have passed.

### 3.6 False-greens identified and closed

Two pre-existing tests assert that a literal `CREATE INDEX … idx_aliases_value_temporal` string is
**present** in `MigrationSQL()` (`sublinear_test.go:18`, `migration_test.go:19,30`). Migration 005
only adds a `DROP`, so 001's `CREATE` text is still there and both stay green whether or not the
index was ever removed. Presence of a `CREATE` proves nothing; only the matching `DROP` does.

Added:

- `TestMigrationSQL_CleartextIndexesAreDropped` — asserts the DROPs, the pseudonymous replacements,
  and that both triggers genuinely compare in pseudonym space rather than merely validating shape.
- `TestMigrationSQL_EveryFileIsEmbeddedAndExecuted` — walks `migrations/` and asserts every file is
  both `//go:embed`-ed and actually reachable in `MigrationSQL()`. `MigrationSQL()` and
  `ApplyMigrations` are hand-maintained lists; forgetting either produced a completely green suite
  while the migration never ran, because nothing counted files on disk against files wired up.
- `TestAliasPG_CleartextIndexesAreGone` — asserts against `pg_indexes` in a live database, not
  against SQL text, and re-applies migrations to confirm 001 re-creating the index each boot does
  not defeat 005's drop.

`MigrationSQL()` deliberately **excludes** the rollback script: including it would make its
`CREATE INDEX` statements satisfy a grep for the cleartext indexes and mask the drops.

---

## 4. Epoch rotation policy

**Rotation is a planned migration, never an automatic or time-triggered event.**

Incrementing `IDENTITY_PSEUDONYM_EPOCH` changes every pseudonym for every tenant simultaneously.
Because the pseudonym is the join key for the entire actor graph, and because it is the indexed
column, rotation re-keys the whole join surface at once.

**The hazard, confirmed empirically.** A naive rotation — bumping the epoch and leaving the stored
pseudonyms alone — reintroduces the exact fail-open this card closed, deferred by one rotation.
The never-merge triggers compare `aliases.alias_value_hash` against
`delegations.{delegate,principal}_actor_pseudonym`; both are epoch-bound, so after a bump every
comparison misses and the trigger silently becomes a no-op.
`TestAliasPG_NeverMergeSurvivesEpochRotation` demonstrates this against a live database:

```
CONFIRMED HAZARD: after a naive epoch rotation the illegal alias was ACCEPTED.
```

**The procedure.** Use `identity.RederivePseudonymsForEpoch(ctx, db, oldEnc, newEnc, tenant)`. In one
transaction it re-keys delegation pseudonyms first (the alias trigger consults them, so moving
aliases first would check against stale values), then for every alias row opens the envelope under
the outgoing key, re-derives the pseudonym at the new epoch, and **re-seals under the new AAD** —
the AAD embeds the pseudonym, so the ciphertext necessarily changes too. Alias writes must be
quiesced for the duration: a concurrent write at the old epoch produces a row the new index cannot
resolve.

**An earlier draft of this section was wrong and the test caught it.** It prescribed nulling the
delegation pseudonyms and re-running `EncryptExistingAliasValues`. That is impossible:
`EncryptExistingAliasValues` only populates pseudonyms that are `NULL`, and
`check_never_merge_delegation` refuses to let them *be* nulled — correctly, since a NULL pseudonym
is unverifiable:

```
pq: pseudonymisation invariant violated: delegation actor-delegate -> actor-principal
    must carry both 64-hex counterparty pseudonyms (23514)
```

The test now asserts that refusal explicitly, so nobody "simplifies" rotation back to
null-and-backfill and leaves the graph half-rotated. After the real tool runs, enforcement is
restored:

```
enforcement restored after re-deriving delegation pseudonyms at epoch 1:
pq: structural never-merge invariant violated: cannot alias actor actor-delegate
    to its delegation counterparty (pseudonym 34ce797ca3d94ba8…) (23514)
```

**It is a migration, not an outage**, provided writes are quiesced — the work is `O(rows)` and
transactional. `IDENTITY_PSEUDONYM_EPOCH` being set-but-unparseable is an **error**, not a silent
fallback to 0: silently reverting to epoch 0 after a rotation would resurrect every pre-rotation
pseudonym.

The domain constant is version-pinned (`…/v1`) and guarded by `TestPseudonym_DomainIsVersionPinned`.
A new scheme takes a new `/vN` suffix and a new epoch; editing it in place would invalidate every
stored pseudonym with no migration.

---

## 5. Residual exposure — what this change does NOT erase

Encrypting the `alias_value` column protects the *current heap tuple*. It does not reach, and
crypto-shredding the key cannot erase, any of the following. The proposal acknowledges none of
them, so they are stated here.

| Surface | Why the ciphertext does not reach it | Mitigation available |
|---|---|---|
| **Write-Ahead Log** | The backfill's `UPDATE … SET alias_value = NULL` is itself WAL-logged, and the WAL records the **old tuple** including the cleartext. Every cleartext identifier written before this migration is in the WAL. | WAL retention expiry only. `wal_keep_size`/archive retention bounds the window; nothing removes it sooner. |
| **Pre-VACUUM heap tuples** | Postgres MVCC does not overwrite on UPDATE; it writes a new tuple and marks the old dead. The cleartext row remains in the heap file until `VACUUM` reclaims it, and `VACUUM` does not zero the page — the bytes persist until the space is reused. | `VACUUM FULL` rewrites the table, but leaves the original file's blocks on disk unless the filesystem zeroes them. |
| **Index pages** | `idx_aliases_value_temporal` and `idx_aliases_idempotent_seed` contained the cleartext. `DROP INDEX` unlinks the relation; it does not shred the pages. | Filesystem-level or full-disk encryption. |
| **PITR / base backups** | Any base backup or continuous archive taken before this migration contains the cleartext heap **and** the cleartext indexes, in full. | Backup retention expiry only. A subject-erasure request cannot be satisfied within the retention window. |

The four above are the surfaces the card explicitly asked to be enumerated. They are not the whole
list, and stopping there would let a DPO conclude that "did cleartext leave this database?" had been
answered. It has not. Also outstanding:

| Surface | Why it matters |
|---|---|
| **TOAST relations** | An over-threshold `alias_value` lives in a separate TOAST heap with its own dead tuples and its own index. "Heap tuples" above does not cover it. |
| **Postgres server logs** | `log_statement` / `log_min_duration_statement` write bound parameters. More sharply: a unique-violation error echoes the conflicting key **verbatim**, and `idx_aliases_idempotent_seed` was UNIQUE on the cleartext — so cleartext identifiers are plausibly in the error log. Also `pg_stat_activity.query`, `pg_stat_statements`, `auto_explain`, temp-file spills. |
| **Logical replication slots / CDC** | A retained slot pins WAL indefinitely *against* VACUUM, and any subscriber has already **received** the cleartext. This is where "cleartext left the database" actually happens. |
| **Physical standbys and logical dumps** | Not only PITR. Any `pg_dump` taken before this migration is a full cleartext copy. |
| **Git history** | The scrubber salt was removed from `HEAD`, not from history. It remains in every clone, fork, CI cache and packfile. Removal from the working tree is not removal. |

**Therefore: crypto-shredding the identity key does NOT constitute erasure under Article 17 for
data written before this migration.** It makes the *current* table unreadable without the key. The
surfaces above require retention expiry, storage-level encryption, subscriber coordination, or
physical media disposal. Any claim that this milestone delivers erasure is an overclaim, and Phase
3's retention work must treat these as in-scope rather than assume this card covered them.

### 5.1 The classification point — read this before citing the 0/6 result

**A keyed HMAC pseudonym is pseudonymised data, not anonymised data. It remains personal data under
GDPR Recital 26, and every data-subject right still attaches to it.**

This is the single most important sentence in this document, because the adversarial result in §3.2
invites the opposite reading. "0/6 inverted against 1,446 candidates" holds **only against an
adversary who does not hold the HKDF root key**. The transformation is reversible by construction
for anyone who does — that reversibility is what makes the actor graph work at all.

Concretely, for a DPO assessment:

- **Custodian.** The root key is `IDENTITY_PSEUDONYM_KEY` (or, in the single-key configuration,
  `IDENTITY_ENCRYPTION_KEY`). Whoever holds it holds the re-identification capability for every
  tenant, because per-tenant keys are HKDF-derived from it rather than independently generated.
- **Blast radius of key compromise.** Total and retroactive. The identifier population is small and
  enumerable, so an attacker with the key re-identifies the entire graph by recomputing the table
  in §3.2 — the same attack, now succeeding.
- **No per-subject erasure path.** Keys are scoped per `(tenant, epoch)`, not per subject, so
  crypto-shredding one data subject is not possible: destroying the key erases the whole tenant.
  Article 17 for an individual is **not** satisfied by any mechanism in this card. That is Phase 3's
  to own, and it should not assume this card provided a foundation for it.

**Uniqueness semantics also changed.** `idx_aliases_idempotent_seed` enforced uniqueness on the
cleartext `(actor_id, alias_type, alias_value, valid_from)`. The replacement enforces it on the
keyed digest. Within a `(tenant, epoch)` scope these are equivalent — HMAC is a function, and a
SHA-256 collision is not a practical concern. But two consequences follow: uniqueness is now
scoped, so the *same* identifier under two tenants is two distinct rows (correct, and what tenant
isolation requires); and **two different identifiers can no longer be distinguished by inspecting
the table**, so any operational procedure that previously eyeballed `alias_value` to resolve a
duplicate now needs the key.

---

## 6. Assumption forced by an unowned prerequisite

`grep -rn 'tenant' identity/ main.go` returns **zero matches**: there is no `tenant_id` column
anywhere in the identity schema. It is SLDP-P2-2, migration `006`.

The HMAC is therefore parameterised by an explicit tenant string supplied by the caller, defaulting
to a repository-level tenant read from `IDENTITY_TENANT_ID` (falling back to `DefaultTenantID`,
never `""`). `AliasRecord` carries a `TenantID` field that is not yet persisted.

**This is an assumption this card had to make because a prerequisite left it open, recorded so the
phase governor can weigh it.** The key-derivation API is already per-tenant, so P2-2 wires per-row
tenants with **no change to the cryptography** — it needs only to populate `AliasRecord.TenantID`
from the new column and pass it through `tenantFor`.

---

## 7. Handoff

**To SLDP-P2-2 (migration 006, tenant + RLS).** The pseudonym API is already tenant-scoped. Populate
`AliasRecord.TenantID` from the new `tenant_id` column; `PostgresRepository.tenantFor` and
`MemoryRepository.tenantFor` already prefer a per-record tenant over the deployment default. Note
that `delegations.{delegate,principal}_actor_pseudonym` are computed under the repository tenant and
will need the same treatment. Adding a tenant column does **not** require re-pseudonymising unless
the tenant value for existing rows differs from `IDENTITY_TENANT_ID`.

**To SLDP-P2-3 (migration 007, never-merge pinning).** The trigger work is **done**, in 005 §6/§6b,
for the reasons in §2.4 — `007` is no longer needed for trigger replacement. Re-scope P2-3 to what
SLDP-P2-PRE §4.2.3 actually asked for and this card only partly delivered: comprehensive
`TestStructuralNeverMerge_*` negative assertions against **both** the in-memory and the PostgreSQL
implementations. Today all four `never_merge_test.go` cases are memory-only; this card added one
live-Postgres never-merge assertion, which is a floor and not coverage.

**Known gaps deliberately not closed by this card:**

1. `transform.AnonymizeHMAC` has **no tenant scope and no rotation epoch**, so one tenant's scrubbed
   labels are comparable with another's. Closing it requires plumbing a tenant through the ingest
   transform hot path — a different component than P2-1 owns. The salt is now fail-closed and the
   digest widened to 128 bits, but the tenant-blindness stands.
2. The pseudonym root defaults to being derived from `IDENTITY_ENCRYPTION_KEY`. HKDF domain
   separation means the derived key is not the AES key, but they share a root: anyone holding the
   encryption key can re-derive every tenant's pseudonym key. `NewAESGCMEncryptorWithKeys` accepts a
   separate `IDENTITY_PSEUDONYM_KEY` and the code warns when it is absent. **A KMS-backed deployment
   must set both.** `d2-signalloom/apps/fe-signalloom/base/secrets.yaml` currently sets only the
   encryption key.
3. `CREATE UNIQUE INDEX` inside `ApplyMigrations` cannot use `CONCURRENTLY` (the whole migration runs
   in one transaction), so it takes a write-blocking lock on `aliases` for the index build on every
   boot. Acceptable at demo scale; a production estate needs the migration split out of the boot path.

---

## 8. Verdict

| Deliverable | Status |
|---|---|
| Keyed, domain-separated HMAC replacing bare SHA-256 | **Delivered** — `identity/pseudonym.go`, HKDF + HMAC-SHA256 |
| AES-GCM envelope encryption, index on HMAC only | **Delivered** — with AAD row binding |
| Forward migration + rollback | **Delivered and both executed live** |
| Adversarial dictionary test failing on inversion | **Delivered** — with a positive control |
| HMAC key scoped to tenant and epoch | **Delivered**, domain separation documented §2.1 |
| Committed default salt removed, fail-closed | **Delivered** — plus 64→128-bit digest widening |
| Written residual: WAL, heap tuples, index pages, PITR | **Delivered** §5 |
| Epoch-rotation policy | **Delivered** §4 |

`make test-signal-ingest` **EXIT=0 — 539 PASS / 0 FAIL / 7 SKIP**. Live Postgres **6/6**.
Three mutation checks confirm the controls fail when removed.
