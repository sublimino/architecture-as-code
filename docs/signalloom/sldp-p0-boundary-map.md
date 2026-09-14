# SLDP-P0 implementation boundary map

Status: **PASS — baseline mapped; later phases may proceed**
Evidence revision: `a5de246158ca472d719315159da787cb4d39e81d`
Scope: `d2-signalloom/apps/signal-ingest/{identity,store,transform,audit,api}` and `d2-signalloom/apps/fe-signalloom/src/audit_anchor`

## Interpretation fixed by the Governor and Council

P0 asks whether the proposal has components on which later phases can build. It does not require attestation-specific revocation to be complete before those phases start. The existing foundation is:

- `SegmentAttestor` provides segment signing, checkpointing, local evidence and optional Archivista publication.
- `audit_anchor` provides Python library and CLI verification for persisted segments and checkpoint chains.
- Delegation revocation terminates authority edges and marks the affected actor revoked.
- Later cards productionise verification and compose attested tombstones plus crypto-shred erasure.

There is no public Go `SegmentAttestor.Verify*` or `SegmentAttestor.Revoke` entrypoint today. Segment and checkpoint verification nevertheless exists through the Python `audit_anchor` library and CLI. The missing Go entrypoint and attestation-specific revocation/tombstones are explicit future boundaries, not P0 blockers. The proposal assigns verifier acceptance to P1-3 and tombstones to P4-2 (`Proposal — Signal Loom Production and Data-Protection Hardening (2026-Q3).md:250-252,262,275`).

## Claimed-primitive verdicts

`EXISTS` means the named component has a callable implementation. `PARTIAL` means code exists but the relevant production path does not yet enforce it. `ABSENT` is retained for expected future composition seams so later cards do not mistake them for shipped controls.

| Primitive | Verdict | Repository evidence | Boundary consequence |
|---|---|---|---|
| Secret scrubber | **PARTIAL** | `CryptographicSecretScrubber`, `ScrubText`, recursive map scrubbing and `ScrubObservation` exist at `d2-signalloom/apps/signal-ingest/transform/secrets_scrubber.go:49-169`. Production collectors construct a direct store sink at `main.go:125-135`; `collectors/sink.go:20-25` appends directly. HTTP ingestion validates then appends directly at `api/handlers.go:279-315`. | P2/P3 must place scrubbing before every persistence boundary rather than merely reuse the type. |
| HMAC anonymiser | **PARTIAL** | `AnonymizeHMAC` computes deterministic HMAC-SHA256 then returns a 16-hex-character (64-bit) truncation at `transform/secrets_scrubber.go:53-71`; scrubber methods use it at `:95-104,154-166`. No production caller constructs the scrubber. Empty configuration selects a fixed fallback salt at `:54-60`. | P2-1 must provide managed key material, remove the fallback, assess truncation/collision handling and wire pseudonymisation before storage. |
| Tenant-scoped claims | **PARTIAL** | FastAPI validates JWT claims and resolves a principal at `d2-signalloom/apps/fe-signalloom/src/api_compat.py:1440-1519`. Signal Fusion routes depend on that principal but do not propagate tenant scope at `signal_fusion.py:53-63,118-160`. Go registers a bare mux at `d2-signalloom/apps/signal-ingest/main.go:224-250`; its observation and query contracts have no tenant key at `model/signal.go:99-119` and `store/store.go:19-26`. | P1/P2 must carry tenant identity across the proxy boundary, authenticate Go routes and enforce storage predicates plus PostgreSQL RLS. |
| Segment attestation | **EXISTS** | `SegmentAttestorConfig`, `SegmentAttestor`, constructor and lifecycle methods exist at `store/segment_attestor.go:49-125,233-271,538-598`. `attestingBucket.Upload` signs persisted segment objects through asynchronous processing at `:931-949`; `WithSegmentAttestation` integrates it at `store/frostdb.go:56-95`. | P1-3 can add a public Go verification boundary without rewriting existing segment bytes. P4-2 can add tombstone semantics on top. |
| Delegation revocation | **EXISTS** | The route is registered at `api/handlers.go:89`. The handler calls `RevokeActiveDelegations` at `api/revocation_handler.go:52-67`. PostgreSQL recursively clamps delegation validity and marks actor state revoked at `identity/repository.go:320-368`; memory behavior exists at `identity/memory.go:235-273`. | Existing authority revocation is the proposal's revocation primitive. It is not evidence revocation or erasure. |
| Segment/checkpoint verification | **EXISTS** | `TrustedKeyring.verify` enforces pinned, non-revoked signing keys at `audit_anchor/segments.py:26-45`; `JournalSegmentDigestReader` verifies persisted bytes and signed predicates at `:67-97,128-158`. Its protected high-water checks are conditional on a supplied path at `:160-242`. The CLI makes trusted key IDs and protected high-water mandatory before invoking chain verification at `audit_anchor/cli.py:262-284`; `verify --source segments` is registered at `:406-412`. | P1-3 can productionise and acceptance-test this verifier rather than create verification from nothing. Rollback detection depends on preserving high-water state in a trust boundary that evidence rollback cannot also replace. |
| Go `SegmentAttestor` verification entrypoint | **ABSENT — expected future seam** | `SegmentAttestor` receiver methods cover status, startup validation, queueing, processing, publication and lifecycle at `store/segment_attestor.go:113,274,372,420,520,538,583,601-929`; none is `Verify`. | Later Go integration must preserve the Python verifier's trust-pinning, freshness and rollback checks. |
| Attestation-specific revocation/tombstones | **ABSENT — expected future seam** | The same receiver inventory contains no `Revoke`; existing revocation affects identity authority edges only. | P4-2 must build non-linkable attested tombstones. Acceptance must not claim evidence revocation works beforehand. |

## Interfaces later phases touch

### `AESGCMEncryptor`

The identity package contract is defined at `identity/encryption.go:21-35`:

```go
type Encryptor interface {
    Encrypt(plaintext []byte) ([]byte, error)
    Decrypt(ciphertext []byte) ([]byte, error)
    Hash(value string) string
}

func NewAESGCMEncryptor(key []byte) (*AESGCMEncryptor, error)
func NewEncryptorFromKeyString(keyStr string) (Encryptor, error)
```

`AESGCMEncryptor.Encrypt`, `Decrypt` and `Hash` are at `identity/encryption.go:49-100`. Encryption is AES-256-GCM with a fresh nonce. `Hash` is unkeyed SHA-256. `NewEncryptorFromKeyString("")` returns `NoopEncryptor` at `:103-134`, and `NewPostgresRepository` also substitutes that passthrough when passed `nil` at `identity/repository.go:45-58`. Production construction occurs at `main.go:176-190`; the checked deployment does not supply `IDENTITY_ENCRYPTION_KEY` (`base/deployment.yaml:66-94`). P1-2 must make both missing-key paths fail closed.

### Alias repository

The complete `identity.Repository` contract begins at `identity/repository.go:23-42`. The alias seam is:

```go
AddAlias(context.Context, AliasRecord) error
FindAliasesAsOf(context.Context, string, time.Time) ([]AliasRecord, error)
GetAliasesForActorAsOf(context.Context, string, time.Time) ([]AliasRecord, error)
```

`AliasRecord` and half-open temporal validity are defined at `identity/model.go:18-40`. Implementations are:

- Memory: constructor and methods at `identity/memory.go:16-40,88-170`.
- PostgreSQL: constructor and methods at `identity/repository.go:45-58,145-224`.

PostgreSQL currently stores both plaintext `alias_value` and unkeyed `alias_value_hash` (`identity/migrations/001_identity_graph.sql:16-26`; insertion at `identity/repository.go:159-176`). P2-1 therefore changes schema, write, lookup and migration semantics together. P2-2 must add tenant keys and RLS without weakening half-open temporal lookup or P2-3's never-merge invariant.

### FrostDB schema builder

The durable implementation is build-tagged `frostdb` at `store/frostdb.go:1`. Its relevant API is:

```go
type FrostDBStoreOption func(*frostDBStoreConfig)
func WithSegmentAttestation(SegmentAttestorConfig) FrostDBStoreOption
func NewFrostDBStoreWithBucket(string, ...FrostDBStoreOption) (*FrostDBStore, error)
func schemaDef() *schemapb.Schema
```

`FrostDBStore` implements `SignalStore` (`store/store.go:11-17`) through `Append`, `QueryRange`, `DropPartition` and `Close` at `store/frostdb.go:167-303,463-482`. `schemaDef` declares fixed columns at `:138-164`; append builds physical Arrow fields plus dynamic `labels.*` columns at `:167-250`. Direct identifier columns include `actor_hint`, `principal_id`, `actor_id`, `session_id` and `impersonated_user`; free-form `description`, `raw_evidence_ref` and labels can also retain personal data.

The shipped Dockerfile builds without `-tags frostdb` (`signal-ingest/Dockerfile:4-7`), so the untagged factory returns `MemoryStore` (`store/factory.go:1-8`). The checked deployment sets `SIGNAL_STORE_DIR` but not `SIGNAL_STORE=frostdb` (`base/deployment.yaml:66-68`). P3 must add a schema version and preserve old bytes; it must not pretend the current deployment exercises Parquet.

### `SegmentAttestor`

The public boundary is:

```go
func NewSegmentAttestor(SegmentAttestorConfig) (*SegmentAttestor, error)
func (a *SegmentAttestor) Status() SegmentAttestorStatus
func (a *SegmentAttestor) Wait(context.Context) error
func (a *SegmentAttestor) Close() error
```

Types and signatures are at `store/segment_attestor.go:49-125,233-271,538-598`. The object-store decorator is `attestingBucket.Upload` at `:931-949`. Successful processing writes DSSE evidence, optional Archivista publication, a checkpoint, a journal entry and protected high-water state at `:673-845`.

The Parquet upload completes before asynchronous enqueue. Queue-full and closed-attestor conditions are recorded but do not fail the upload (`store/segment_attestor.go:520-535,940-949`); `FrostDBStore.Flush` explicitly does not await attestation (`store/frostdb.go:485-512`). Later acceptance must test this fail-open seam rather than only check that Parquet exists.

## Personal-data storage-copy inventory

| Sink or copy | Status in checked deployment | Personal or linkable content | Evidence and ownership |
|---|---|---|---|
| Identity PostgreSQL: `actors` | **Implementation present; active only with usable `DATABASE_URL`** | Actor identifier, metadata, status and timestamps | Schema `identity/migrations/001_identity_graph.sql:5-14`; writes `identity/repository.go:66-103`; selection `main.go:71-81,176-190`. Additional attributes may appear inside metadata, which becomes plaintext under `NoopEncryptor`. Manifests alone do not prove runtime writes. |
| Identity PostgreSQL: `aliases` | **Implementation present; active only with usable `DATABASE_URL`** | Actor identifier, alias type, plaintext alias, SHA-256 alias hash, fidelity, validity | Schema `identity/migrations/001_identity_graph.sql:16-26`; writes `identity/repository.go:145-183`; selection `main.go:71-81,176-190`. Manifests alone do not prove runtime writes. |
| Identity PostgreSQL: `delegations` | **Implementation present; active only with usable `DATABASE_URL`** | Principal, delegate, authorization reference, metadata, validity, revocation state | Schema `identity/migrations/001_identity_graph.sql:29-42`; writes `identity/repository.go:255-300`; selection `main.go:71-81,176-190`. Manifests alone do not prove runtime writes. |
| Signal audit PostgreSQL | **Implementation present; active only with usable `DATABASE_URL`** | Tenant, optional actor, event type, arbitrary detail JSON, timestamp | Insert boundary `audit/postgres.go:130-152`; handlers include actor and correlation details at `api/handlers.go:409-460`; selection `main.go:57-119`. Manifests alone do not prove runtime writes. |
| Portal `audit_events` PostgreSQL | **Configured external input to anchor plane** | Tenant, actor, agent, event type, arbitrary detail JSON | `d2-signalloom/contracts/discovery-portal-bootstrap.sql:336-358`; raw rows are read by `audit_anchor/reader.py:26-40`. |
| Observation memory store | **Active shipped signal-ingest store** | Complete `Observation`, including identifiers, descriptions, references and labels | Untagged factory `store/factory.go:1-8`; in-memory slice `store/memory.go:11-27`; model `model/signal.go:99-119`. Process-local, lost on restart. |
| Identity memory repository | **Fallback** | Actors, plaintext aliases, delegations and metadata | `identity/memory.go:16-39`; selection at `main.go:176-190`. Process-local. |
| FrostDB/Parquet objects | **Implemented, inactive in shipped image** | Identifier columns, free text, evidence references, dynamic labels | `store/frostdb.go:138-250`; excluded by current Docker build and deployment configuration. If enabled, immutable bytes are attestation inputs and must be versioned rather than rewritten. |
| Segment evidence directory | **Implemented, inactive unless attestation enabled** | Segment path, digest, size, signer identity, checkpoint chain, errors and signed envelopes | Structures and writes `store/segment_attestor.go:128-179,673-929`; activation `store/factory_frostdb.go:22-53`. Linkable metadata may remain after source pseudonymisation. |
| Segment protected high-water file | **Implemented, inactive unless attestation enabled** | Maximum sequence, journal size, evidence counts, segment tip, historical segment inventory and lost-error count | Configuration and default path `store/factory_frostdb.go:36-39`; schema `store/segment_attestor.go:159-168`; mode-0600 atomic replacement `:905-910`. This distinct durable copy enables rollback detection only when its trust boundary prevents evidence rollback from replacing it too. |
| Audit-anchor local output and verifier | **CLI capability; no deployed scheduler found** | Tenant scope, time window, row count, chained hashes, Merkle root and DSSE envelope | Checkpoint `audit_anchor/checkpoint.py:84-118`; statement `audit_anchor/anchor.py:87-104`; file write `audit_anchor/anchor.py:240-246`; segment verification `audit_anchor/cli.py:262-284`. Raw rows are not embedded. |
| Archivista | **Optional target; no Signal Loom URL configured** | Audit-anchor or segment DSSE envelopes containing hashes and metadata | Uploads `audit_anchor/anchor.py:269-336` and `store/segment_attestor.go:704-708,764-767`. Repository infrastructure persists envelope bytes in MinIO (`d2-osramp-apps/components/backend/base/archivista-secret.yaml:6-14`; `minio.yaml:9-18,55-77`). |
| Rekor | **Not implemented** | No current copy | Audit-anchor rejects configured Rekor publication at `audit_anchor/anchor.py:392-407`. Treat future publication as a new retention sink. |
| Kubernetes-audit receiver channel | **Active when receiver runs; process-local** | Normalized principal, impersonated user, object names, namespace, URI, user agent and labels | Channel and conversion `api/audit/receiver.go:108-145,196-211,245-353`. |
| Segment-attestor queues | **Inactive unless attestation enabled; process-local** | Segment path, digest, byte count and processing errors | Queue structures `store/segment_attestor.go:80-104,128-179`; enqueue/error paths `:520-535,620-670`. Durable error files are a separate evidence-directory copy. |
| Identity event bus | **Process-local** | Actor, SPIFFE identity, pod, namespace, process identifiers, IP and revocation reason | Payloads/subscribers `identity/eventbus.go:17-70`. |
| Quarantine caches | **Process-local plus observation copy** | Actor, pod, namespace, reason, action, evidence reference, timestamps | `correlation/quarantine.go:23-55,265-335`; fallback ring `correlation/stun_client.go:341-388`. |
| Redis | **Configured infrastructure; target use not found** | No confirmed target-component copy | Shared deployment `d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml:36-59`; no requested component reference found. |
| Signal Loom MinIO | **Configured infrastructure; target use not found** | No confirmed target-component copy | Shared deployment `d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml:61-88`; no target write path found. |
| Backups/snapshots | **Not found for target datasets** | No confirmed copy | Tracked repository search covered `pg_dump`, Velero, restic, backup and `VolumeSnapshot`; matches were unrelated workloads or comments. Absence in source does not prove infrastructure operators never snapshot volumes. |
| Application/container logs | **Emission confirmed; retention external and unproven** | Actor IDs, IPs, reasons, pod names, segment paths and error text | JSON stdout setup `main.go:30-32`; examples `identity/stun_listener.go:72-112`, `api/promote.go:18-41`, `store/segment_attestor.go:913-929`. Cluster logging policy is outside this repository boundary. |

## Migration sequence

Identity migrations present:

1. `001_identity_graph.sql`
2. `002_delegation_indices.sql`
3. `003_idempotent_seeding.sql`
4. `004_delegation_revocation.sql`

The executable migration list contains those four in order (`identity/migrations.go:11-25,41-54`). The next free sequence is therefore **`005`** at this evidence revision. P0 does not claim or create it; P2-PRE must recheck immediately before allocation because sibling cards can race this directory.

## Shared-file collision map

| Shared surface | P0 action | Required later coordination |
|---|---|---|
| Proposal errata | Update only the qualified SLDP-P0 block after commit | Preserve prior timestamps and sibling blocks. |
| `identity/migrations/` | Read-only; confirm `005` | P2 Governor allocates the number immediately before creating a migration. |
| `store/frostdb.go` | Read-only; record schema seam | P3 Governor coordinates schema-version columns; never rewrite existing segment bytes. |
| Attestation journal/checkpoints | Read-only | P1/P4 must preserve verification compatibility and checkpoint continuity. |

## Revised milestone estimates

These are engineering ranges derived from the interfaces above, not contractual deadlines. They include implementation, tests, migration/recovery work and governor evidence. External legal/DPO review and production observation windows remain separate.

| Proposal milestone | Duration | Consultants | Person-days | Evidence-based sizing change |
|---|---:|---:|---:|---|
| M1: pseudonymisation, re-identification separation, allow-list | 15–20 working days | 2 | 24–32 | Scrubber/HMAC are unwired; aliases and authz references remain plaintext; Parquet requires additive schema versioning. |
| M2: retention, crypto-shred, attested tombstones | 20–30 working days | 2–3 | 38–55 | No deletion controller exists; Parquet bytes and checkpoint continuity cannot be rewritten; every sink needs receipts and recovery tests. |
| M3: graph encryption, tenant isolation | 12–18 working days | 2 | 20–30 | Go is unauthenticated and tenant-blind; PostgreSQL lacks RLS; current key and audit fallbacks fail open. |
| M4: region pinning, KMS signing, DPIA pack | 15–22 working days | 2–3 | 25–38 | Signer abstraction, deployment evidence, customer-self-host proof and GRC/legal review cross code and operational boundaries. |
| Mid-project review | 0.25 working days | 2 | 0.5 | Retain proposal value. |
| Signoff and evidence reconciliation | 2–3 working days | 2 | 4–6 | Requires technical, GRC and operational evidence reconciliation. |
| **Total** | **64.25–93.25 working days elapsed before parallelism** | **2–3** | **111.5–161.5** | Team planning must set calendar deadlines from staffing and legal availability. |

Critical path: P1 authentication, fail-closed controls and verifier productionisation precede privacy claims; P2 establishes identity pseudonyms and tenancy; P3 adds Parquet schema versioning; P4 composes erasure with immutable proof; P5/P6 close KMS, rights, retention and deployment evidence. The historical selective FrostDB benchmark measured 2.75 ms p95 at 12,000 observations, while its tagged regression guard used a 10 ms ceiling (`docs/signalloom/sfdp-p4-gov-acceptance-evidence.md:58,77`). P0 did not rerun that tagged benchmark, so neither value is presented as a newly measured gate.

## P0 proceed decision

**Proceed: yes.** The map confirms usable component seams and makes every missing composition explicit. No existing segment or checkpoint was changed; no migration was claimed; no control was described as already enforcing behavior it does not enforce.
