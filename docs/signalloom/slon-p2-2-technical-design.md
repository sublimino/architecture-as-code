# SLON-P2-2 Technical Design: Dynamic Nono Capability Detection & Signed Audit Ingest Architecture

**Document Version:** 1.0.0  
**Phase:** Mission SLON Phase 2 (Dual Demo Agent Onboarding & Live Demo)  
**Deliverable:** `SLON-P2-2`  
**Classification:** Enterprise Security & Governance Architecture Specification  

---

## 1. Architectural Context & Motivation

Enterprise platform operators demand verifiable proof that Signal Loom provides rigorous, cryptographic governance across heterogeneous agent runtimes:
1. **Evidenced Confinement Workloads (`agent-nono-evidenced`)**: Sandboxed under Linux Landlock LSM unprivileged user namespaces with hash-chained event logs and SPIFFE SVID detached cryptographic signatures.
2. **Standard Baseline Workloads (`agent-standard-baseline`)**: Conventional containerized workloads executing unconfined without Landlock.

To prevent deployment brittleness across diverse container substrates (Kind clusters, Docker-in-Docker, varied cloud kernel boot parameters), **SP-5** mandates that Nono is an **optional capability**:
- Workloads must run a pre-execution probe.
- If Nono binary and Landlock LSM ABI level >= 1 are detected, execute under `nono run` with cryptographic evidence logging.
- If absent, emit structured warning telemetry and gracefully fall back to unconfined execution without crashing or triggering `CrashLoopBackOff`.

---

## 2. Dynamic Capability Probe Specification (`probe-nono-capability.sh`)

### 2.1 Inspection Heuristics

The probe evaluates capability along two independent axes:
1. **Binary Availability**: Resolves `command -v nono` on PATH or `$NONO_BIN`.
2. **Kernel LSM / Landlock ABI Support**:
   - Inspects `/sys/kernel/security/lsm` for `landlock` registration.
   - Executes `nono why` / `nono --version` capability self-test.
   - Evaluates Linux kernel release (>= 5.13) and unprivileged user namespace clone enablement (`/proc/sys/kernel/unprivileged_userns_clone == 1`).

### 2.2 Telemetry Invariants

- **Detected State:**
  ```json
  {
    "timestamp": "2026-09-10T10:06:23Z",
    "event": "nono_probe",
    "status": "detected",
    "nono_capability_available": true,
    "binary": "/usr/bin/nono",
    "sandboxing": "landlock",
    "evidence_signing": "spiffe",
    "landlock_abi_version": 1
  }
  ```
- **Fallback State:**
  ```json
  {
    "timestamp": "2026-09-10T10:03:34Z",
    "event": "nono_probe",
    "status": "fallback",
    "nono_capability_available": false,
    "warning": "Nono binary or Landlock LSM not available on container substrate; executing unconfined without crashing or blocking pod scheduling",
    "fallback": "unconfined"
  }
  ```

---

## 3. Signed Audit Session Telemetry Ingest & Verification

### 3.1 Hash-Chain Verification Mathematics

Given a sequence of events $E = (e_1, e_2, \dots, e_n)$ in session $S$:
1. **Genesis Link**:
   $$H_0 = \text{SHA256}(0^{64}) \quad \text{or} \quad \text{SHA256}(S_{\text{id}} \parallel \text{"genesis"})$$
2. **Inductive Event Hashing**:
   For event $e_i = (\text{seq}_i, \text{ts}_i, \text{type}_i, \text{action}_i, \text{res}_i, \text{detail}_i)$:
   $$\text{Canonical}(e_i) = \text{RFC8785\_JSON}(e_i)$$
   $$H_i = \text{SHA256}(H_{i-1} \parallel ":" \parallel \text{Canonical}(e_i))$$
3. **Session Root Hash Verification**:
   $$H_{\text{root}} = H_n$$

Any modification to intermediate event details, ordering, or deletion alters subsequent hashes and causes immediate verification failure.

### 3.2 Signature Verification & Workload Identity

Detached cryptographic signatures over $H_{\text{root}}$ are verified against the agent's SPIFFE workload identity:
- **SPIFFE SVID Token HMAC**: `sig-spiffe-` prefix computed over `SHA256(root_hash || ":" || spiffe_id)`.
- **Asymmetric ECDSA (P-256 / SHA-256)**: Standard SECP256R1 signature verification against agent public key.
- **Asymmetric Ed25519 & RSA (RS256 / PKCS#1v15)**: Multi-algorithm support for enterprise PKI compatibility.

### 3.3 Storage Schema (`public.signed_audit_sessions`)

```sql
CREATE TABLE IF NOT EXISTS public.signed_audit_sessions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          TEXT        NOT NULL UNIQUE,
    tenant_id           TEXT        NOT NULL,
    agent_id            TEXT        NOT NULL,
    spiffe_id           TEXT        NOT NULL,
    started_at          TIMESTAMPTZ NOT NULL,
    ended_at            TIMESTAMPTZ,
    events_count        INTEGER     NOT NULL DEFAULT 0,
    root_hash           TEXT        NOT NULL,
    signature           TEXT        NOT NULL,
    algorithm           TEXT        NOT NULL DEFAULT 'ECDSA_SHA256',
    public_key          TEXT,
    verified            BOOLEAN     NOT NULL DEFAULT true,
    hash_chain_valid    BOOLEAN     NOT NULL DEFAULT true,
    signature_valid     BOOLEAN     NOT NULL DEFAULT true,
    events              JSONB       NOT NULL DEFAULT '[]'::jsonb,
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## 4. API Endpoints Contract

- `POST /api/audit/sessions`: Authenticated session ingest and cryptographic verification. Returns HTTP 201 on success or HTTP 400 with `hash_chain_verification_failed` / `signature_verification_failed` on tamper detection.
- `POST /api/audit/sessions/verify`: Diagnostic verification probe endpoint evaluating payload validity without state mutation.
- `GET /api/audit/sessions`: Tenant-isolated list of ingested sessions with optional `agent_id` filtering and offset/limit pagination.
- `GET /api/audit/sessions/{session_id}`: Detail retrieval for a specific session within caller's tenant boundary.
