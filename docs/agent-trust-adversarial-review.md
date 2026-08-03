# SPIFFE Agent Trust Hierarchy — Adversarial Review

## Implementation-facing disposition ledger

| Threat | Disposition |
|---|---|
| Forged caller identity | Live receiver validates the planner JWT-SVID through an exact OpenBao role, then verifies an Ed25519 authorization context. |
| Cross-project or cross-tenant call | Receiver requires exact planner subject plus `tenant=acme` and `project=payments`; default-deny policies add reachability containment. |
| Wrong audience or expired token | Receiver rejects exact-audience mismatch and validates `nbf`/`exp`. |
| Replay | Context binds JWT, body, timestamp, nonce, and receiver-instance challenge; nonce reuse and pre-restart captures are denied. |
| Network policy mistaken for auth | Documentation and policy header explicitly limit NetworkPolicy to reachability. |
| Cloud attestation overclaim | Lambda, Cloud Run and Azure contracts are labeled modeled and enumerate deployment gaps. |
| Credential proliferation | Bootstrap creates roles and policies only; it carries no new reusable workload credential. |
