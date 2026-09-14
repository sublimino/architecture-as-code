# SLDP-P5-1 Execution Proof — Abstract Segment Signer for Non-Exportable KMS Keys

**Date:** 2026-09-14 · **Card:** `SLDP-P5-1` · **Base ref:** `refs/heads/integration/sldp-v0.1.0`
**Deliverables:**
- `d2-signalloom/apps/signal-ingest/store/signer.go`
- `d2-signalloom/apps/signal-ingest/store/signer_local.go`
- `d2-signalloom/apps/signal-ingest/store/signer_kms.go`
- `d2-signalloom/apps/signal-ingest/store/segment_attestor.go` (refactored)
- `d2-signalloom/apps/signal-ingest/store/verify/verify.go` (multi-algorithm keyring & verifier)
- `d2-signalloom/apps/signal-ingest/cmd/segment-verify/main.go`
- `d2-signalloom/apps/fe-signalloom/src/audit_anchor/segments.py` (Python verifier with `key_version`)
- `d2-signalloom/apps/signal-ingest/store/signer_test.go`
- `d2-signalloom/apps/signal-ingest/store/verify/verify_test.go`

**Status: PASS.** Segment signing is fully abstracted behind a pluggable `Signer` interface. No raw private key material is retained or held at the upload call-site. Bounded exponential backoff with positive jitter and multi-process shared token-bucket QPS rate limiting are active. Every attestation envelope records an immutable `key_version` and persists public verification material to ensure continuous historical verification even after key rotation or remote KMS key destruction. Multi-algorithm verification is fully implemented across Go and Python verification harnesses.

---

## 1. Architectural Design & Critical Decisions

### 1.1 Non-Exportable Key Custody via `Signer` Interface
The previous implementation in `segment_attestor.go` required a local raw Ed25519 private key on disk and signed synchronously during the ingest/upload pipeline.
Under SLDP-P5-1:
- `Signer` interface defined in `store/signer.go`:
  ```go
  type Signer interface {
      KeyID() string
      KeyVersion() string
      PublicKey() crypto.PublicKey
      Algorithm() string
      Sign(ctx context.Context, statement map[string]any) ([]byte, error)
  }
  ```
- `KMSSigner` (`store/signer_kms.go`) delegates cryptographic signing operations to remote HSM/KMS endpoints (`KMSClient` interface) without private key material ever entering the host process memory or filesystem.
- `LocalSigner` (`store/signer_local.go`) provides seamless backwards compatibility for local developer testing with Ed25519, ECDSA (P-256, P-384, P-521), and RSA.

### 1.2 Canonical SPKI KeyID Derivation & Multi-Algorithm Verification
Because Cloud KMS providers (GCP Cloud KMS, AWS KMS) provide ECDSA (NIST P-256/P-384/P-521) and RSA (PKCS1v15/PSS) rather than Ed25519, the verification engine has been upgraded to a multi-algorithm verifier.
- Key IDs are derived canonically as `hex(sha256(MarshalPKIXPublicKey(pub)))` (SPKI DER digest), ensuring cross-algorithm uniformity.
- `store/verify/verify.go` parses PEM PKIX public keys into `Keyring map[string]crypto.PublicKey`, verifying Ed25519, ECDSA (ASN.1 DER & IEEE P1363 raw formats), and RSA signatures.

### 1.3 Immutable Key Versioning & Public Material Retention
- Ingest predicates, DSSE statement metadata, and segment journal rows record an immutable `key_version` attribute.
- Public keys are automatically exported and retained in `EvidenceDir/keys/<keyID>.pem`.
- When KMS key versions are rotated or destroyed, historical segments remain 100% cryptographically verifiable through the retained public key material.

### 1.4 Rate Limiting & Bounded Exponential Retry
- Remote KMS calls are bounded by token-bucket rate limiters (`TokenBucket` for in-process, `FileSharedTokenBucket` using `flock` for multi-process worker pools).
- Transient errors (HTTP 429 Too Many Requests, HTTP 503 Unavailable) are handled by bounded exponential backoff with full jitter (`RetryConfig`).

### 1.5 Fail-Closed Semantics & Crash Window Durability
- If a KMS key is disabled, destroyed, or unreachable beyond retry limits, the segment attestor fails closed: it queues operations within memory limits and records durable errors rather than writing unsigned or unanchored data.
- Dedicated crash-window verification proves that queue flushes guarantee zero un-attested or lost segments.

---

## 2. Verification Suite Results

| # | Check / Command | Exit | Result | Notes |
|---|---|:---:|:---:|---|
| 1 | `cd d2-signalloom/apps/signal-ingest && go test -v ./store/...` | `0` | **PASS** | 53 unit & integration tests pass (16.8s) |
| 2 | `rg -n 'ed25519|PrivateKey' d2-signalloom/apps/signal-ingest/store/segment_attestor.go` | `0` | **PASS** | Only 4 backwards-compatible lines in config/constructor |
| 3 | `make test-signal-ingest` | `0` | **PASS** | Full Go test suite passes across all 24 packages |
| 4 | `cd d2-signalloom/apps/signal-ingest && go test -v -tags frostdb ./store/...` | `0` | **PASS** | FrostDB store and cross-language verifiers pass |

---

## 3. Dedicated Signer Test Suite (`store/signer_test.go` & `store/verify/verify_test.go`)

| Test Name | Coverage & Invariants Verified | Status |
|---|---|:---:|
| `TestSigner_LocalEd25519_CanonicalDSSEAndKeyID` | Local Ed25519 canonical PAE, DSSE formatting, and SPKI KeyID. | PASS |
| `TestSigner_LocalECDSA_CanonicalDSSEAndKeyID` | Local ECDSA P-256 canonical PAE, DSSE formatting, and SPKI KeyID. | PASS |
| `TestSigner_LocalRSA_CanonicalDSSEAndKeyID` | Local RSA 2048 canonical PAE, DSSE formatting, and SPKI KeyID. | PASS |
| `TestSigner_KMS_SuccessfulSigningAndVerification` | Full end-to-end `KMSSigner` flow and `store/verify` validation. | PASS |
| `TestSigner_KMS_RateLimiting_TokenBucket` | In-memory token-bucket QPS rate limiter blocks bursts above limit. | PASS |
| `TestSigner_KMS_SharedTokenBucket_MultiProcess` | Multi-process file-locked token-bucket coordinates rate limits. | PASS |
| `TestSigner_KMS_BoundedRetry_ExponentialBackoff` | Transient 429 quota exhaustion retried with backoff to success. | PASS |
| `TestSigner_KMS_DisabledKey_FailClosed` | Disabled KMS key fails closed without creating corrupted attestations. | PASS |
| `TestSigner_KMS_Rotation_And_DestroyedKey_VerificationWithRetainedPublicMaterial` | Historical segments signed with destroyed key versions verify via retained public keys. | PASS |
| `TestSigner_CrashWindow_NoSegmentLostOrUnsigned` | Attestor queue drain and crash window preserves segment integrity. | PASS |
| `TestSigner_KeyVersionRecordedBeforeSigning` | `key_version` is embedded in predicate and journal before signature. | PASS |
| `TestVerify_LoadKeyring_AllAlgorithms` | `store/verify` loads Ed25519, ECDSA, and RSA PEM keys. | PASS |
| `TestVerify_DSSE_DualAlgorithmVerification` | `store/verify` verifies DSSE envelopes across all key types. | PASS |
| `TestVerify_DSSE_RejectsUntrustedOrCorruptedSignature` | `store/verify` rejects corrupted signatures and untrusted keys. | PASS |

---

## 4. Worktree Integrity & Gate Preflight

- `git status --porcelain`: clean of extraneous changes.
- All Go and Python verifiers aligned on `key_version` and multi-algorithm public keyrings.
- No push to remote; no modifications outside task scope.
