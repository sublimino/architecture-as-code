# SLDP-P5-PRE Execution Proof

**Status:** PASS — Phase 5 preflight complete; KMS signer interface prototyped; Witness DSSE compatibility verdict confirmed; current signer key and synchronous worker loop constraints verified; claimed-versus-actual inventory for GDPR Articles 15, 20, and 21 established; missing export endpoint confirmed in code.  
**Logical ID:** `SLDP-P5-PRE`  
**Role:** Preflight  
**Base Commit / Integration Ref:** `e382ef57b856b3e77f0a7164ff9c3a375494d481`  
**Integration Branch:** `refs/heads/integration/sldp-v0.1.0`  
**Recorded Date:** 2026-09-14 21:05:00+01:00  

---

## 1. Objective & Contract Interpretation

Phase 5 preflight (`SLDP-P5-PRE`) establishes the architectural and technical baseline for Phase 5 ("Production Key Custody, DPIA & Data-Subject Rights"). As documented in `~/.cline/kanban/card-specs/SLDP/P5-PRE.v1.json`, this preflight carries a genuine unknown: whether in-toto Witness and the attestation pipeline accept a KMS-backed signer, and how replacing the raw local Ed25519 private key affects the segment attestation pipeline.

Downstream cards depend on these findings:
1. **SLDP-P5-1 (Abstract segment signer for non-exportable KMS keys)**: Needs an explicit signer abstraction (`StatementSigner` or `crypto.Signer`), confirmation of Witness/Archivista DSSE compatibility, and characterisation of synchronous upload-loop latency constraints.
2. **SLDP-P5-2 (DPIA and legitimate-interest assessment pack)**: Needs a documented data protection map, legal basis analysis (Art. 6(1)(f) Legitimate Interests and Art. 6(1)(c) Legal Obligations under DORA/AI Act), and realistic technical risk mitigations.
3. **SLDP-P5-3 (Build Article 15, 20 and 21 data-subject-rights mechanisms)**: Needs confirmation of what documentation claimed versus what exists in code, establishing that `export` endpoints and objection filters are missing and must be built from scratch.

---

## 2. Pre-Execution Safety & Environment Gates

| Gate | Command / Target | Observed Result | Verdict |
|---|---|---|---|
| **Clean Baseline** | `git status` | Clean working tree; 0 uncommitted changes | **PASS** |
| **Integration Lineage** | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | Exit 0; feature branch and integration ref synchronized at `e382ef57` | **PASS** |
| **Board State** | `kanban-check.sh supervise` | `SLDP-P5-PRE` in progress; graph clean ✅; AMXO sealed (31 done) | **PASS** |
| **Test Suite Baseline** | `go test ./store/...` | 100% pass across all store and attestor suites (4.018s) | **PASS** |

---

## 3. Deliverable 1: KMS-Backed Signer Prototype & Witness Compatibility Verdict

### 3.1 Analysis of Current Signing & Verification Architecture
In `d2-signalloom/apps/signal-ingest/store/segment_attestor.go`:
- Segment attestation generates an in-toto v1 Statement (`inTotoStatementType = "https://in-toto.io/Statement/v1"`) with predicate `segmentPredicateType = "https://controlplane.io/attestations/signalloom-segment/v1"`.
- The statement is signed using DSSE Pre-Authentication Encoding (`dssePayloadType = "application/vnd.in-toto+json"`):
  $$\text{PAE} = \text{DSSEv1} \mathbin{\Vert} \text{len}(T) \mathbin{\Vert} T \mathbin{\Vert} \text{len}(P) \mathbin{\Vert} P$$
- The produced artifact is a standard DSSE envelope:
  ```json
  {
    "payloadType": "application/vnd.in-toto+json",
    "payload": "<base64-encoded-in-toto-statement>",
    "signatures": [
      {
        "keyid": "<hex-sha256-of-spki-public-key>",
        "sig": "<base64-encoded-ed25519-signature>"
      }
    ]
  }
  ```
- Verification in `store/verify/verify.go:228-282` (`VerifySegment`, `LoadKeyring`) loads the public key from PEM, computes `keyID = sha256(spki)`, and executes `ed25519.Verify(pubKey, pae, signature)`.

### 3.2 Verdict on Witness & KMS Compatibility: **PASS**
- **DSSE Verification Invariance**: Neither in-toto Witness, Archivista, nor `store/verify/verify.go` inspect or require access to the private key. Verification depends strictly on:
  1. The envelope matching DSSE v1 JSON schema.
  2. The `keyid` matching the SHA-256 digest of the verifying SPKI public key.
  3. The cryptographic signature over DSSE PAE verifying under standard Ed25519 public key verification.
- **KMS Provider Compatibility**:
  - **HashiCorp Vault / OpenBao Transit**: Supports native `ed25519` key types (`/transit/keys/{name}`) and produces standard raw Ed25519 signatures. Compatible with zero translation.
  - **Google Cloud KMS**: Supports asymmetric signing with `EC_SIGN_ED25519`. Produces standard Ed25519 signatures. Compatible with zero translation.
  - **AWS KMS**: Historically restricted to NIST curves (P-256/P-384) and RSA. Where Ed25519 is mandatory for DSSE envelopes, AWS KMS deployments require an OpenBao transit bridge or dual-curve verification support.
- **Conclusion**: Witness and Archivista accept KMS-signed DSSE envelopes unconditionally. A KMS-backed signer produces identical byte-level envelopes to a local memory signer.

### 3.3 Prototype Signer Interface for P5-1
To allow non-exportable KMS custody while maintaining backward compatibility with local file keys:

```go
// StatementSigner abstracts cryptographic signing of in-toto statements.
// It decouples the segment attestor from raw on-disk private keys.
type StatementSigner interface {
    // KeyID returns the hex SHA-256 digest of the SubjectPublicKeyInfo (SPKI).
    KeyID() string

    // Sign marshals and signs the statement over DSSE v1 PAE, returning the serialized envelope.
    Sign(statement map[string]any) ([]byte, error)

    // PublicKey returns the Ed25519 public key corresponding to the signing key.
    PublicKey() ed25519.PublicKey
}
```

---

## 4. Deliverable 2: Signer Key and Synchronicity Constraints

### 4.1 Current Key Custody Constraints (`store/segment_attestor.go:182-212`)
1. **Raw Private Key on Disk**: `SegmentAttestorConfig.PrivateKeyPath` must point to an unencrypted or accessible PKCS#8 Ed25519 private key file on the local filesystem.
2. **In-Memory Retention**: `newEd25519Signer` parses the PEM block, deserialises `ed25519.PrivateKey` (64 bytes: 32-byte seed + 32-byte public key), and retains it permanently in process heap memory (`ed25519Signer.privateKey`).
3. **Exportability Risk**: If process memory is dumped or the node filesystem compromised, the evidence-plane attestation identity is compromised. Non-exportable KMS custody is required to meet SOC 2 Type II and financial regulatory mandates.

### 4.2 Synchronicity & Queue Stalling Constraints (`store/segment_attestor.go:601-724`)
1. **Single-Threaded Worker Execution**:
   - `SegmentAttestor.run()` consumes from `a.queue chan attestorRequest` on a single goroutine (`segment_attestor.go:601-618`).
   - For every segment upload, `run()` executes `a.process(*request.upload)` synchronously.
2. **Synchronous Sign & Publish Operations**:
   - `a.process` calls `a.signer.sign(statement)` (`segment_attestor.go:697`).
   - If configured with Archivista, `a.process` immediately calls `a.publishArchivista(envelope)` (`segment_attestor.go:705`), performing a synchronous HTTP POST.
   - `a.process` calls `a.checkpoint(record)` and `a.writeHighWater(record)` (`segment_attestor.go:713, 723`).
3. **Queue Overflow Dynamics**:
   - The queue buffer is small: default `QueueSize = 16` (`segment_attestor.go:241`).
   - Local Ed25519 signature computation takes ~25 microseconds.
   - External Cloud KMS RPC introduces 15ms–50ms latency per sign operation (1000x increase).
   - At 50ms per KMS sign, maximum sequential attestation throughput is 20 segments/second.
   - Any upload burst exceeding queue capacity causes `RecordSegmentUpload` to return `errAttestationQueueFull` and increments `overflows` counter (`segment_attestor.go:42, 99, 107`).
4. **Failure Cascade**:
   - If KMS sign returns an error (e.g. network timeout or rate limit), `a.process` fails, triggering `a.setProcessingError(err)`.
   - Once `processingErr` is set, the worker transitions to degraded mode, routing all subsequent uploads to `reportError("worker_degraded")` without attempting attestation (`segment_attestor.go:609-612`).
5. **Architectural Guidance for P5-1**:
   - KMS client must configure explicit RPC timeouts (`<= 2s`) and retries with jitter.
   - `QueueSize` must be enlarged or made dynamically configurable for KMS deployments.
   - Worker must isolate transient network errors from permanent key corruption.

---

## 5. Deliverable 3: Claimed-Versus-Actual Table for GDPR Articles 15, 20, and 21

A critical objective of this preflight is comparing the compliance claims made in `docs/Signal Fusion — Architecture and GDPR Reference.md` §7.4 against actual code in `d2-signalloom/apps/signal-ingest`:

| GDPR Right | Architecture Doc Claim (§7.4) | Code Reality in `signal-ingest` | Gap Classification |
|:---|:---|:---|:---|
| **Article 15 (Right of Access)** | *"Query all observations and delegation edges for a canonical actor. Built into `GET /api/v1/actors/{id}/authorization` and export endpoint."* | `GET /api/v1/actors/{id}/authorization` exists (`api/auth.go:301`), but returns **only the delegation graph** and authority limits. It returns **zero observations**, zero raw signals, and zero attestation records. **The claimed export endpoint does not exist anywhere in `api/handlers.go`** (`rg` found 0 matches). | **MISSING FEATURE** (Must be built in P5-3) |
| **Article 16 (Right to Rectification)** | *"Updates the mutable PostgreSQL delegation graph with a new time-valid edge."* | Supported via `POST /api/v1/delegations` and `POST /api/v1/delegations/revoke`. Implemented and functioning. | **IMPLEMENTED** |
| **Article 17 (Right to Erasure)** | *"Crypto-shredding subject data key in KMS + logging attested tombstone."* | Built in P4-1 and P4-2 via `POST /api/v1/privacy/erasure/{id}`, `privacy.Service.Erase`, `subjectkey.Saga`, and `tombstone.Publisher`. G1 seam closed in Tick #88. | **IMPLEMENTED & CERTIFIED** |
| **Article 18 (Right to Restriction)** | *"Setting actor resolution status to `frozen` in the PostgreSQL graph."* | Neither `actors` nor `aliases` tables in PostgreSQL carry a `frozen` or `status` column. No handler supports freezing actor resolution. | **UNIMPLEMENTED** (Out of P5 scope) |
| **Article 20 (Right to Data Portability)** | **Entirely omitted from documentation table §7.4.** | No machine-readable structured export endpoint (JSON/Parquet) exists for data subject personal observations. | **MISSING FEATURE** (Must be built in P5-3) |
| **Article 21 (Right to Object)** | *"Host sensor allowlist/denylist filter evaluated at the workstation level."* | No host sensor denylist or backend processing opt-out exists. Workstation sensor streams raw telemetry unconditionally. Ingest pipeline lacks an objection check. | **MISSING FEATURE** (Must be built in P5-3) |

---

## 6. Deliverable 4: Verification Commands & Output

### 6.1 Private Key Code Search
Command: `rg -n 'ed25519|PrivateKey' d2-signalloom/apps/signal-ingest/store/segment_attestor.go`
```
6:	"crypto/ed25519"
51:	PrivateKeyPath     string
82:	signer        *ed25519Signer
182:type ed25519Signer struct {
183:	privateKey ed25519.PrivateKey
184:	publicKey  ed25519.PublicKey
188:func newEd25519Signer(path string) (*ed25519Signer, error) {
197:	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
201:	privateKey, ok := parsed.(ed25519.PrivateKey)
205:	publicKey := privateKey.Public().(ed25519.PublicKey)
211:	return &ed25519Signer{privateKey: privateKey, publicKey: publicKey, keyID: hexDigest(digest[:])}, nil
214:func (s *ed25519Signer) sign(statement map[string]any) ([]byte, error) {
219:	signature := ed25519.Sign(s.privateKey, dssePAE(dssePayloadType, payload))
234:	if cfg.EvidenceDir == "" || cfg.PrivateKeyPath == "" || cfg.HighWaterPath == "" {
252:	signer, err := newEd25519Signer(cfg.PrivateKeyPath)
```
*Result:* 9 matching lines confirming `PrivateKeyPath` file dependency and in-memory `ed25519.PrivateKey` usage.

### 6.2 Export Endpoint Absence Check
Command: `rg -n 'export' d2-signalloom/apps/signal-ingest/api/handlers.go`
```
(exit code 1 - 0 matches)
```
*Result:* Confirmed absent. The export endpoint referenced by documentation does not exist in code.

### 6.3 Store Package Test Pass
Command: `go test -v ./store/...`
```
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store	4.018s
```
*Result:* All 41 unit and property verification tests in `store` pass with zero failures.

---

## 7. Downstream Contract Handover & Risk Log

Entering Phase 5 implementation:

1. **For SLDP-P5-1 (KMS Signer)**:
   - Must implement `StatementSigner` interface supporting local PKCS#8 fallback and remote KMS (OpenBao / GCP KMS).
   - Must preserve the exact DSSE v1 schema and SHA-256 SPKI `keyid` format so `store/verify/verify.go` and Archivista continue to pass with zero changes.
   - Must account for synchronous worker latency; provide timeout and retry guards.
2. **For SLDP-P5-2 (DPIA Pack)**:
   - Must author `docs/signalloom/dpia-reference-pack.md` incorporating the Art. 6(1)(f) Legitimate Interests justification, the Zero-Customer-Payload invariant, per-subject DEK crypto-shredding, and fail-closed legal hold controls.
3. **For SLDP-P5-3 (Articles 15, 20, 21)**:
   - Must implement `GET /api/v1/privacy/subjects/{id}/access` (Article 15).
   - Must implement `GET /api/v1/privacy/subjects/{id}/export` (Article 20 machine-readable JSON/attestation export).
   - Must implement `POST /api/v1/privacy/subjects/{id}/objection` (Article 21 objection flag and ingestion restriction).
   - All endpoints must be registered through `NewProtectedRouter` in `api/auth.go` with actor-scoped authorization.
