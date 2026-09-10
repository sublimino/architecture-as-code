# Signal Ingest Automated Containment Trigger & Alert Dispatch Architecture

**Component**: `d2-signalloom/apps/signal-ingest/correlation`  
**Implementation**: `QuarantineEngine` (`correlation/quarantine.go`, `correlation/stun_client.go`)  
**Phase**: SFAS Phase 3 (`SFAS-P3-2`)  

---

## Architecture Overview

The Signal Ingest `QuarantineEngine` serves as the automated security circuit-breaker between multi-agent autonomous execution and kernel-enforced containment. When an agent attempts privileged or high-severity operations under an unverified delegation chain, the correlation engine autonomously intervenes without human operator lag.

```
┌────────────────────────────────────────────────────────────────────────┐
│ Signal Ingest Correlation Engine                                       │
│                                                                        │
│   Incoming Observation (Audit/Telemetry)                              │
│                │                                                       │
│                ▼                                                       │
│     [IsHighSeverityAction?] ─────── NO ───────► Normal Graph Ingestion │
│                │ YES                                                   │
│                ▼                                                       │
│     [Evaluate 7 Violation Rules]                                       │
│                │                                                       │
│       ┌────────┴────────┐                                              │
│       ▼ Clean           ▼ VIOLATION DETECTED                           │
│   Authorized       ┌────────────────────────────────────────────────┐  │
│                    │ 1. Set Status = 'quarantined'                  │  │
│                    │ 2. Inc Prometheus Metrics Counters             │  │
│                    │ 3. Append Immutable Store Record (FrostDB)     │  │
│                    │ 4. Dispatch Freeze Request to Stun Sentinel    │  │
│                    └───────────────────────┬────────────────────────┘  │
└────────────────────────────────────────────┼───────────────────────────┘
                                             │ HTTP POST /api/v1/stun/{pod}
                                             ▼
                               ┌───────────────────────────┐
                               │ Stun Sentinel Controller  │
                               │ - cgroup v2 freeze        │
                               │ - eBPF tc_drop egress cut │
                               └───────────────────────────┘
```

---

## Seven Canonical Violation Rules

1. **Depth Exceeded**: Cascading delegation depth `> 7` hops.
2. **Forged Claim / Tampered Signature**: Non-authentic cryptographic signatures or circumstantial tampering.
3. **Missing Cosign Signature**: Container image executing privileged actions without detached Cosign signature.
4. **Missing Landlock Attestation**: Process attempting high-severity egress or filesystem actions without Landlock confinement.
5. **Shadow Identity**: Unknown, anonymous, or synthetic identities attempting privileged operations.
6. **Incomplete Delegation Chain**: Delegation chain severed or missing required links for privileged actions.
7. **Untrusted Delegation Hop**: Borrowed authority lacking verified delegation edge.

---

## Defensive Safeguards

- **Baseline Exemptions**: Verified baseline demo agents (`agent-baseline`) are explicitly exempted to prevent false positives during synthetic estate monitoring.
- **Debounce / Rate Limiting**: Per-actor TTL rate-limiting prevents dispatch storms during cascading anomaly alerts.
- **Fail-Safe Ring Buffer**: If Stun Sentinel is temporarily unreachable, containment records are preserved in an in-memory ring buffer and definitive audit logs.
