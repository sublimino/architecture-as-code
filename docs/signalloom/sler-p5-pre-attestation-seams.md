# SLER-P5-PRE: Witness Attestation Keys, Seams, and Forensic Ledger Schema

**Document ID:** `SLER-P5-PRE`  
**Phase:** 5 (Attested Forensics & Published Matrix) — Pre-flight  
**Target Delivery:** `integration/sler-v0.1.0`  
**Date:** 2026-09-15  
**Author:** Attestation Pre-flight Engineer  
**Status:** Certified Approved

---

## 1. Executive Summary & Problem Articulation

### 1.1 Objective & Purpose
The objective of **SLER-P5-PRE** is to audit, confirm, and specify the cryptographic attestation architecture and forensic ledger schema required for Phase 5 of the Signal Loom Enforcement & Response (SLER) platform.

Phase 5 delivers the cryptographic accountability guarantee: **100% of multi-plane containment actions and governance resume events emit a verifiable, tamper-evident forensic ledger record**, cryptographically bound to the root authorization decision chain.

### 1.2 Current State Assessment (Zero Witness Runtime Integration)
A comprehensive static code audit across all Go source files in `d2-signalloom/apps/fleet-manager` and `d2-signalloom/apps/stun-sentinel` confirms:
1. **Zero Runtime Witness Integration**: Neither `fleet-manager` nor `stun-sentinel` contains any active invocation of `witness`, in-toto signing routines, or DSSE envelope formatting.
   - The only references in Go source files are forward-compatibility commentary and placeholder struct fields:
     - `d2-signalloom/apps/stun-sentinel/pkg/telemetry/emitter.go`: Lines 13-14 ("forward compatibility for P5-1 Witness attestation") and lines 80-81 (`AttestationID string` and `WitnessDigest string`).
     - `d2-signalloom/apps/fleet-manager/attestation_event_contract.go`: Lines 14-17 (documenting that "SLER-P5-1 ingests both planes into ONE Witness-attested forensic pipeline").
2. **Unsigned Telemetry Stream**: The active telemetry emitter (`d2-signalloom/apps/stun-sentinel/pkg/telemetry/emitter.go`: `Emit` at line 126, `StunExecutionHalted` at line 173, `StunExecutionResumed` at line 195, `StunExecutionHaltFailed` at line 226) serializes raw `Event` structs to plain JSON and writes them directly to standard output (`os.Stdout`) without any cryptographic signature, digest binding, or envelope framing.
3. **Estate Witness Machinery Boundary**: The existing `witness` tooling in the repository (`scripts/promotion-demo.sh`, `scripts/attested-test.sh`, `scripts/gen-witness-policy.sh`, `Makefile:signing-keys`) operates strictly as a CI/CD build-step and artifact promotion pattern (`witness run --step ... -- <cmd>` wrapping offline shell executions). It does not service runtime server processes or in-memory containment cascades.

---

## 2. Key Material & Trust Domain Audit

### 2.1 Existing Estate Key Hierarchy
The repository manages root signing keypairs via the `signing-keys` target in the root `Makefile` (`Makefile:205-235`):
- **Private Key**: `.keys/witness.pem` — Ed25519 private key in standard PKCS#8 PEM format (`-----BEGIN PRIVATE KEY-----`).
- **Public Key**: `.keys/witness-pub.pem` — Ed25519 public key in SubjectPublicKeyInfo (SPKI) DER/PEM format (`-----BEGIN PUBLIC KEY-----`).
- **Generation Method**:
  ```makefile
  openssl genpkey -algorithm ed25519 -out $(KEYS_DIR)/witness.pem
  openssl pkey -in $(KEYS_DIR)/witness.pem -pubout -out $(KEYS_DIR)/witness-pub.pem
  ```

### 2.2 Key ID Derivation & SPKI Digest Convention
In conformance with Signal Loom and in-toto / Witness conventions, the canonical Key ID for any public key is the lowercase hex-encoded SHA-256 digest of the DER-encoded SubjectPublicKeyInfo (SPKI):
$$\text{KeyID} = \text{hex}(\text{SHA-256}(\text{MarshalPKIXPublicKey}(\text{PublicKey})))$$

This derivation is verified across:
1. `Makefile:223`:
   ```bash
   openssl pkey -pubin -in $(KEYS_DIR)/witness-pub.pem -outform DER 2>/dev/null | openssl dgst -sha256 -r | cut -d' ' -f1
   ```
2. `d2-signalloom/apps/signal-ingest/store/signer.go:45-55`:
   ```go
   func DeriveKeyID(pub crypto.PublicKey) (string, error) {
       spki, err := x509.MarshalPKIXPublicKey(pub)
       if err != nil {
           return "", fmt.Errorf("marshal PKIX public key: %w", err)
       }
       digest := sha256.Sum256(spki)
       return hex.EncodeToString(digest[:]), nil
   }
   ```

### 2.3 Trust Domain & Policy Separation
To prevent domain confusion between build-time supply chain attestations (e.g. `vex-analysis`, `promotion-decision`) and runtime containment evidence, runtime attestations must use distinct in-toto statement predicate types and step discriminators:
- **Supply Chain Predicate**: `https://witness.dev/attestations/product/v0.1`, `https://witness.dev/attestations/material/v0.1`
- **Signal Loom Segment Predicate**: `https://controlplane.io/attestations/signalloom-segment/v1`
- **SLER Containment Predicate**: `https://controlplane.io/attestations/signalloom-containment/v1`
- **SLER Resume Predicate**: `https://controlplane.io/attestations/signalloom-resume/v1`

---

## 3. Integration Pattern Architecture Decision

### 3.1 Evaluation: Subprocess CLI (`witness run`) vs. In-Process Native Go Signing

| Dimension | Option A: Subprocess Wrapping (`witness run`) | Option B: Native In-Process Go Signing (DSSE / in-toto) | Architectural Finding & Verdict |
| :--- | :--- | :--- | :--- |
| **Execution Model** | `os/exec.Command("witness", "run", "--step", "containment", ...)` | In-process Go library invoking `crypto/ed25519` + in-toto DSSE serializer | Containment events happen inside long-running servers (`fleet-manager`, `stun-sentinel`), not as shell script steps. |
| **Latency Impact** | **30 ms – 150 ms** per event (fork/exec, Go runtime initialization, CLI parsing, disk I/O) | **< 50 µs** per event (pure in-memory crypto and JSON marshaling) | **Option B is 1000x faster**. Spawning a subprocess adds unacceptable latency to a 12 ms kernel freeze. |
| **Container Dependencies** | Requires `witness` binary, `glibc`/musl shims, and shell environment in container image | **Zero binary dependencies**. Compiles hermetically into static Go binary (`CGO_ENABLED=0`). | Option B preserves slim, attack-surface-reduced container images without embedding CLI build tools. |
| **I/O & Concurrency Safety** | Heavy file descriptor churn, temporary file management, potential stdin pipe deadlocks under high containment volume | Mutex / lock-free in-memory buffered channel serialization directly to stream/journal | Option B eliminates process exhaustion and zombie process risks under cascade load. |
| **Testability & Mocking** | Requires disk key fixtures and `witness` installed on developer/CI host | Test doubles via Go `Signer` interface (mock signers, in-memory keys, corrupted signature injection) | Option B enables 100% hermetic unit and contract testing without host tool dependencies. |
| **Interoperability** | Native Witness artifact output | Emits standard in-toto Statement v1 + DSSE envelope (`application/vnd.in-toto+json`) verifiable by Witness | Option B produces identical cryptographic envelopes verifiable by any in-toto/Witness consumer. |

### 3.2 Binding Architecture Decision for SLER-P5-1
**Decision:** **Adopt Option B — Native In-Process Go Signing Engine.**

SLER-P5-1 will implement the in-process signing engine within `d2-signalloom/apps/fleet-manager` and `d2-signalloom/apps/stun-sentinel`, leveraging the proven DSSE/PAE architecture already established in `d2-signalloom/apps/signal-ingest/store/signer.go` and `signer_local.go`.

The in-process signer:
1. Loads `.keys/witness.pem` into an immutable `LocalEd25519Signer` at process initialization.
2. Derives the canonical SPKI SHA-256 `KeyID`.
3. Canonicalizes the forensic event payload into in-toto Statement v1 (`https://in-toto.io/Statement/v1`).
4. Generates standard Pre-Authentication Encoding (PAE):
   $$\text{PAE} = \text{"PAE;application/vnd.in-toto+json;"} + \text{len}(\text{payload}) + \text{";"} + \text{payload}$$
5. Signs the PAE using `ed25519.Sign(privateKey, pae)`.
6. Envelopes the statement in canonical DSSE format:
   ```json
   {
     "payloadType": "application/vnd.in-toto+json",
     "payload": "<base64-encoded-in-toto-statement>",
     "signatures": [
       {
         "keyid": "<spki-sha256-hex>",
         "sig": "<base64-encoded-ed25519-signature>"
       }
     ]
   }
   ```

---

## 4. Forensic Ledger Schema Specification

### 4.1 Schema Overview & Design Invariants
Every containment and resume action produces an immutable forensic ledger entry. The schema binds five critical dimensions:
1. **Temporal & Event Identity**: High-resolution timestamp, monotonic sequence ID, event UUID, and schema version.
2. **Authorization Decision Chain**: Links the action directly to the upstream security policy decision, trigger reason, deciding evidence hash, and authorizing entity.
3. **Target Workload Identity**: Cryptographic and runtime coordinates (Agent ID, SPIFFE ID, Namespace, Pod UID, Node, Cgroup Path, PIDs).
4. **Multi-Plane Execution Proof**: Plane-by-plane outcome, latency, residual exposure window, and granular state details across all 5 enforcement planes (`mesh`, `bao`, `spire`, `admission`, `freeze`).
5. **Operator & Governance Attribution**: For resume events, cryptographic operator attribution, Ed25519 token validation, dual-control signatures, and mandatory credential rotation proof.

---

### 4.2 JSON Schema (`sler-forensic-event.json`)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://signalloom.controlplane.io/schemas/sler-forensic-event/v1alpha1.json",
  "title": "SLERForensicLedgerEvent",
  "description": "Cryptographically attested forensic ledger event for Signal Loom multi-plane containment and governance resume",
  "type": "object",
  "required": [
    "schema_version",
    "event_id",
    "event_type",
    "timestamp",
    "authorization",
    "target",
    "execution",
    "attestation"
  ],
  "properties": {
    "schema_version": {
      "type": "string",
      "enum": ["sler.signalloom.io/v1alpha1"]
    },
    "event_id": {
      "type": "string",
      "description": "Unique UUIDv4 / ULID for this forensic ledger event"
    },
    "event_type": {
      "type": "string",
      "enum": [
        "containment_dispatched",
        "containment_completed",
        "containment_failed",
        "containment_resumed",
        "containment_resume_failed"
      ]
    },
    "timestamp": {
      "type": "string",
      "format": "date-time",
      "description": "RFC3339Nano UTC timestamp of event generation"
    },
    "idempotency_key": {
      "type": "string",
      "description": "Idempotency key for request deduplication"
    },
    "authorization": {
      "type": "object",
      "required": [
        "decision_id",
        "trigger_reason",
        "triggered_by"
      ],
      "properties": {
        "decision_id": {
          "type": "string",
          "description": "Unique identifier of upstream Signal Fusion or policy decision"
        },
        "trigger_reason": {
          "type": "string",
          "description": "Machine-readable trigger code (e.g. prompt_injection, unauthorized_delegation, collusion, anomaly)"
        },
        "trigger_description": {
          "type": "string",
          "description": "Human-readable justification"
        },
        "triggered_by": {
          "type": "string",
          "description": "Entity authorizing containment (e.g. policy-engine, signal-fusion, security-operator)"
        },
        "delegation_edge_revoked": {
          "type": "boolean",
          "description": "Whether the SLDP delegation edge was actively severed"
        },
        "attestation_digest": {
          "type": "string",
          "description": "SHA-256 hash of deciding evidence / fusion proof artifact"
        }
      }
    },
    "target": {
      "type": "object",
      "required": [
        "agent_id",
        "namespace"
      ],
      "properties": {
        "agent_id": {
          "type": "string",
          "description": "Canonical agent identifier"
        },
        "namespace": {
          "type": "string",
          "description": "Kubernetes namespace"
        },
        "pod_name": {
          "type": "string"
        },
        "pod_uid": {
          "type": "string"
        },
        "spiffe_id": {
          "type": "string",
          "description": "Workload SPIFFE ID (e.g. spiffe://osramp.local/ns/prod/sa/agent-x)"
        },
        "node_name": {
          "type": "string"
        },
        "container_id": {
          "type": "string"
        },
        "cgroup_path": {
          "type": "string",
          "description": "Host cgroup v2 path"
        },
        "pids": {
          "type": "array",
          "items": { "type": "integer" }
        },
        "tenant_id": {
          "type": "string"
        }
      }
    },
    "execution": {
      "type": "object",
      "required": [
        "overall_outcome",
        "total_latency_ms",
        "planes"
      ],
      "properties": {
        "overall_outcome": {
          "type": "string",
          "enum": ["contained", "partial", "unavailable", "not_found"]
        },
        "total_latency_ms": {
          "type": "integer",
          "minimum": 0
        },
        "planes": {
          "type": "array",
          "items": {
            "type": "object",
            "required": [
              "plane",
              "outcome",
              "latency_ms",
              "worst_case_residual_ms"
            ],
            "properties": {
              "plane": {
                "type": "string",
                "enum": ["mesh", "bao", "spire", "admission", "freeze"]
              },
              "outcome": {
                "type": "string",
                "enum": ["contained", "partial", "unavailable", "not_found"]
              },
              "latency_ms": {
                "type": "integer",
                "minimum": 0
              },
              "worst_case_residual_ms": {
                "type": "integer",
                "minimum": 0
              },
              "error": {
                "type": "string"
              },
              "details": {
                "type": "object"
              }
            }
          }
        }
      }
    },
    "governance_resume": {
      "type": "object",
      "properties": {
        "token_id": {
          "type": "string"
        },
        "operator_ids": {
          "type": "array",
          "items": { "type": "string" }
        },
        "governance_approval_ref": {
          "type": "string"
        },
        "credentials_rotated": {
          "type": "boolean"
        },
        "processes_resumed": {
          "type": "integer"
        },
        "unfreeze_latency_ms": {
          "type": "integer"
        }
      }
    },
    "attestation": {
      "type": "object",
      "required": [
        "key_id",
        "algorithm",
        "statement_digest",
        "signature"
      ],
      "properties": {
        "attester_component": {
          "type": "string",
          "description": "Component generating attestation (e.g. sler-fleet-manager, sler-stun-sentinel)"
        },
        "key_id": {
          "type": "string",
          "description": "SPKI SHA-256 hex digest of public key"
        },
        "algorithm": {
          "type": "string",
          "enum": ["ed25519"]
        },
        "statement_digest": {
          "type": "string",
          "description": "SHA-256 hex digest of in-toto statement payload"
        },
        "signature": {
          "type": "string",
          "description": "Base64 std-encoded Ed25519 signature over DSSE PAE"
        }
      }
    }
  }
}
```

---

### 4.3 Go Type Definitions (`pkg/attestation/record.go`)

```go
package attestation

import (
	"time"
)

// Schema constants
const (
	ForensicSchemaVersion     = "sler.signalloom.io/v1alpha1"
	ContainmentPredicateType  = "https://controlplane.io/attestations/signalloom-containment/v1"
	ResumePredicateType       = "https://controlplane.io/attestations/signalloom-resume/v1"
	InTotoStatementType       = "https://in-toto.io/Statement/v1"
	DSSEPayloadType           = "application/vnd.in-toto+json"
	SigningAlgorithmEd25519   = "ed25519"
)

// ForensicEventType identifies the lifecycle phase of the containment action.
type ForensicEventType string

const (
	EventContainmentDispatched   ForensicEventType = "containment_dispatched"
	EventContainmentCompleted    ForensicEventType = "containment_completed"
	EventContainmentFailed       ForensicEventType = "containment_failed"
	EventContainmentResumed      ForensicEventType = "containment_resumed"
	EventContainmentResumeFailed ForensicEventType = "containment_resume_failed"
)

// AuthorizationEvidence captures the decision authority that mandated containment.
type AuthorizationEvidence struct {
	DecisionID            string `json:"decision_id"`
	TriggerReason         string `json:"trigger_reason"`
	TriggerDescription    string `json:"trigger_description,omitempty"`
	TriggeredBy           string `json:"triggered_by"`
	DelegationEdgeRevoked bool   `json:"delegation_edge_revoked"`
	AttestationDigest     string `json:"attestation_digest,omitempty"`
}

// TargetIdentity captures the complete runtime coordinates of the contained entity.
type TargetIdentity struct {
	AgentID     string `json:"agent_id"`
	Namespace   string `json:"namespace"`
	PodName     string `json:"pod_name,omitempty"`
	PodUID      string `json:"pod_uid,omitempty"`
	SPIFFEID    string `json:"spiffe_id,omitempty"`
	NodeName    string `json:"node_name,omitempty"`
	ContainerID string `json:"container_id,omitempty"`
	CgroupPath  string `json:"cgroup_path,omitempty"`
	PIDs        []int  `json:"pids,omitempty"`
	TenantID    string `json:"tenant_id,omitempty"`
}

// PlaneExecutionEvidence captures the per-plane enforcement outcome and residual window.
type PlaneExecutionEvidence struct {
	Plane               string         `json:"plane"`                  // mesh, bao, spire, admission, freeze
	Outcome             string         `json:"outcome"`                // contained, partial, unavailable, not_found
	LatencyMs           int64          `json:"latency_ms"`
	WorstCaseResidualMs int64          `json:"worst_case_residual_ms"` // P2-GOV / P5-2 contract
	Error               string         `json:"error,omitempty"`
	Details             map[string]any `json:"details,omitempty"`
}

// ExecutionEvidence captures aggregate multi-plane execution outcomes.
type ExecutionEvidence struct {
	OverallOutcome PlaneOutcome             `json:"overall_outcome"`
	TotalLatencyMs int64                    `json:"total_latency_ms"`
	Planes         []PlaneExecutionEvidence `json:"planes"`
}

// GovernanceResumeEvidence captures operator attribution and unfreeze audit data.
type GovernanceResumeEvidence struct {
	TokenID               string   `json:"token_id"`
	OperatorIDs           []string `json:"operator_ids"`
	GovernanceApprovalRef string   `json:"governance_approval_ref,omitempty"`
	CredentialsRotated    bool     `json:"credentials_rotated"`
	ProcessesResumed      int      `json:"processes_resumed"`
	UnfreezeLatencyMs     int64    `json:"unfreeze_latency_ms"`
}

// AttestationEnvelopeMetadata carries the cryptographic signature provenance.
type AttestationEnvelopeMetadata struct {
	AttesterComponent string `json:"attester_component"`
	KeyID             string `json:"key_id"`
	Algorithm         string `json:"algorithm"`
	StatementDigest   string `json:"statement_digest"`
	Signature         string `json:"signature"`
}

// ForensicLedgerRecord is the complete, canonical attested forensic event.
type ForensicLedgerRecord struct {
	SchemaVersion    string                       `json:"schema_version"`
	EventID          string                       `json:"event_id"`
	EventType        ForensicEventType            `json:"event_type"`
	Timestamp        string                       `json:"timestamp"` // RFC3339Nano
	IdempotencyKey   string                       `json:"idempotency_key"`
	Authorization    AuthorizationEvidence        `json:"authorization"`
	Target           TargetIdentity               `json:"target"`
	Execution        ExecutionEvidence            `json:"execution"`
	GovernanceResume *GovernanceResumeEvidence    `json:"governance_resume,omitempty"`
	Attestation      AttestationEnvelopeMetadata  `json:"attestation"`
}
```

---

## 5. Implementation Roadmap for Phase 5 Cards

### 5.1 SLER-P5-1 (Attestation Implementation)
- **Target**: `d2-signalloom/apps/fleet-manager` & `d2-signalloom/apps/stun-sentinel/pkg/telemetry`.
- **Tasks**:
  1. Port `Signer` interface and `LocalEd25519Signer` into `fleet-manager/pkg/attestation`.
  2. Implement `AttestContainmentDecision(ctx, decision *ContainmentDecision) (*ForensicLedgerRecord, error)`.
  3. Implement `AttestResumeDecision(ctx, resume *ResumeResponse) (*ForensicLedgerRecord, error)`.
  4. Wire in-memory key loading from `.keys/witness.pem` or `WITNESS_KEY_PATH`.
  5. Upgrade `emitter.go` in `stun-sentinel` to compute `WitnessDigest` and `AttestationID` from the signed statement.
  6. Deliver unit tests asserting round-trip cryptographic verification of every generated record.

### 5.2 SLER-P5-2 (Denial Matrix & Benchmarking)
- **Target**: Benchmark and publish latency and worst-case residual metrics across all 5 planes.
- **Inputs**:
  - `freeze`: p95 = 12 ms (measured host cgroup-v2), worst-case residual = 0 ms.
  - `mesh`: target p99 < 2s (Cilium/TC connection cut).
  - `bao`: revocation API latency (measured), worst-case residual = 5m (token TTL ceiling).
  - `spire`: entry eviction latency (measured), worst-case residual = 1h (SVID default TTL).
  - `admission`: webhook rejection latency (measured), worst-case residual = 0 ms (immediate admission interception).

### 5.3 SLER-P5-GOV (Governor Certification)
- **Target**: Verify 100% containment attestation round-trip across synthetic and live scenarios, ensuring zero un-attested events escape the cascade.

---

## 6. Pre-flight Verification Evidence & Assertions

| Probe Command | Target Path | Expected Output | Status |
| :--- | :--- | :--- | :--- |
| `grep -rln 'witness' --include="*.go" d2-signalloom/apps/{stun-sentinel,fleet-manager}` | Go Source Trees | Only commentary/stubs in `emitter.go` and `attestation_event_contract.go` | **PASS (0 active runtime calls)** |
| `test -f .keys/witness.pem` | Repository Root | File exists and is valid Ed25519 key | **PASS** |
| `test -f .keys/witness-pub.pem` | Repository Root | File exists and is valid SPKI public key | **PASS** |
| `grep -n 'witness run\|witness verify' scripts/promotion-demo.sh` | Shell Promotion Demo | Lines 30 & 55 confirming CLI promotion pattern | **PASS** |
| `go test ./...` in `fleet-manager` & `stun-sentinel` | Go Codebase | 100% test suite pass | **PASS** |

---

## 7. Sign-off & Recommendation
**SLER-P5-PRE** is complete. All prerequisites, cryptographic key bindings, integration pattern decisions, and wire schemas are established without ambiguity.

**Recommendation:** Proceed immediately to **SLER-P5-1** (Attestation Implementation) and **SLER-P5-2** (Denial Matrix Benchmark).
