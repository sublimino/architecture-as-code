# SPIFFE Agent Trust Hierarchy — Adversarial Review

## Implementation-facing disposition ledger

| Threat | Disposition |
|---|---|
| Forged caller identity | Receiver verifies RS256 fixture signatures using only a public key. Production issuance is delegated to SPIRE. |
| Cross-project or cross-tenant call | Receiver requires exact planner subject plus `tenant=acme` and `project=payments`; default-deny policies add reachability containment. |
| Wrong audience or expired token | Receiver rejects exact-audience mismatch and validates `nbf`/`exp`. |
| Replay | Receiver-owned `jti` store denies second use. Production needs durable bounded replay storage. |
| Network policy mistaken for auth | Documentation and policy header explicitly limit NetworkPolicy to reachability. |
| Cloud attestation overclaim | Lambda, Cloud Run and Azure contracts are labeled modeled and enumerate deployment gaps. |
| Credential proliferation | Bootstrap creates roles and policies only; it carries no new reusable workload credential. |
