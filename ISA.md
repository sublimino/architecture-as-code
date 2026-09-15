---
task: "SLER-P4-3: Implement governance-gated resume with mandatory credential rotation"
slug: sler-p4-3-governance-resume-rotation
project: osramp-demo
effort: e3
effort_source: classifier
phase: observe
progress: 36/36
mode: algorithm
started: 2026-09-15T06:04:00+01:00
updated: 2026-09-15T06:16:00+01:00
---

## Problem

The containment engine previously relied on a single shared-secret `STUN_RESUME_TOKEN` read from the environment and compared via a constant-time string comparison (`stun-sentinel/cmd/stun-sentinel/main.go:56,272`). Because the identical token was injected cluster-wide across all DaemonSet nodes, operator attribution was structurally absent: the bytes compared carried zero information about who presented them. Furthermore, resuming an agent without rotating its active credentials left the agent running on the very credentials active during containment, defeating the security guarantee of containment.

## Vision

An attributable, governance-gated unfreeze and resume system:
1. **Ed25519 Dual-Operator Signature Verification**: Verifies tokens against P1-3's frozen v1alpha1 spec with length-prefixed domain-separated canonical signing inputs.
2. **Node-Local Operator Key Distribution**: Distributed public key registry loaded on sentinel nodes via file/directory/env bundles with self-certifying `sha256:<hex>` KeyIDs.
3. **Cryptographic Attribution**: Operator identities extracted from verified signatures and recorded in forensic telemetry events and audit logs.
4. **Mandatory Credential Rotation**: Automatic rotation of OpenBao leases and SPIRE SVIDs on resume before marking resume complete.
5. **Replay & Idempotency Ledger**: Single-use token ledger keyed on `token_id` and `idempotency_key`, preventing token replay while guaranteeing safe idempotency under retry.

## Out of Scope

- Contacting live customer infrastructure or real production clusters.
- Modifying SLDP identity contracts or changing the frozen v1alpha1 schema without version bump.
- Python runtime scripts or non-standard tooling.

## Principles

- **Attribution is a Property of Keys**: A single shared secret is structurally unattributable; attribution requires individual asymmetric keys bound to operator identities.
- **Mandatory Credential Rotation**: A resumed agent must never continue using credentials that were live during its containment.
- **Fail-Closed Safe Defaults**: Missing or invalid credentials deny resume unconditionally.
- **Replay Protection with Idempotent Retry**: Replay of consumed tokens is denied, while identical requests with the same idempotency key return cached results without double-rotation.

## Constraints

- Pure Go implementation in `apps/stun-sentinel` and `apps/fleet-manager`.
- Conformance with `docs/signalloom/sler-p1-3-frozen-contract.md`.
- Zero compiler errors with `CGO_ENABLED=0`.
- All tests passing in `stun-sentinel` and `fleet-manager`.

## Goal

Implement Ed25519-signed governance resume token verification, node-local per-operator key distribution, operator identity attribution in telemetry, and mandatory OpenBao/SPIRE credential rotation on resume.

## Criteria

- [x] ISC-1: `stun-sentinel` replaces symmetric string comparison with Ed25519 resume token verification.
- [x] ISC-2: `stun-sentinel` supports loading operator key registry from file, directory, or JSON environment configuration.
- [x] ISC-3: `stun-sentinel` operator key registry validates self-certifying `sha256:<hex>` key fingerprints.
- [x] ISC-4: `stun-sentinel` validates Ed25519 token signatures over length-prefixed canonical signing inputs.
- [x] ISC-5: `stun-sentinel` enforces validity window (`issued_at`, `expires_at`, and clock skew).
- [x] ISC-6: `stun-sentinel` enforces distinct operator and distinct key invariants for multi-signature tokens.
- [x] ISC-7: `stun-sentinel` enforces `max(policy.RequiredSignatures, token.RequiredSignatures)` quorum rule.
- [x] ISC-8: `stun-sentinel` extracts verified operator identities from signature entries.
- [x] ISC-9: `stun-sentinel` records verified operator identity in `StunExecutionResumed` telemetry events.
- [x] ISC-10: `stun-sentinel` rejects tokens signed with unknown or unregistered keys.
- [x] ISC-11: `stun-sentinel` rejects tokens signed with revoked operator keys.
- [x] ISC-12: `stun-sentinel` rejects tokens with mismatched agent_id or namespace.
- [x] ISC-13: `stun-sentinel` rejects tokens with mismatched audience or trust_root_id.
- [x] ISC-14: `stun-sentinel` rejects tokens with invalid or forged Ed25519 signatures.
- [x] ISC-15: `stun-sentinel` implements single-use token replay protection keyed on `token_id`.
- [x] ISC-16: `stun-sentinel` supports idempotent retry when identical `token_id` and `idempotency_key` are presented.
- [x] ISC-17: `fleet-manager` `RestoreCredentials` triggers credential rotation across OpenBao and SPIRE planes.
- [x] ISC-18: `fleet-manager` `OpenBaoClient` supports rotating agent credentials/leases on resume.
- [x] ISC-19: `fleet-manager` `SpireClient` supports re-entering agent SPIFFE registration entries on resume.
- [x] ISC-20: `fleet-manager` `CascadeOrchestrator.Recover` / `Resume` triggers mandatory credential rotation.
- [x] ISC-21: `fleet-manager` `ResumeResponse` sets `credentials_rotated: true` only after successful rotation.
- [x] ISC-22: `fleet-manager` emits structured machine-readable `governance_resume_decision` audit log events.
- [x] ISC-23: `fleet-manager` resume decision audit logs include operator identity, target, token ID, and rotation outcome.
- [x] ISC-24: Unit test in `stun-sentinel` proves valid Ed25519 resume token from authorized operator succeeds.
- [x] ISC-25: Unit test in `stun-sentinel` proves invalid/unauthorized token is rejected with 401 Unauthorized.
- [x] ISC-26: Unit test in `stun-sentinel` proves revoked operator key is rejected.
- [x] ISC-27: Unit test in `stun-sentinel` proves replayed token with different idempotency key is rejected.
- [x] ISC-28: Unit test in `stun-sentinel` proves idempotent retry with same idempotency key succeeds without re-executing unfreeze.
- [x] ISC-29: Unit test in `fleet-manager` proves resume triggers both OpenBao lease rotation and SPIRE SVID re-entry.
- [x] ISC-30: Unit test in `fleet-manager` proves failed credential rotation fails the resume operation.
- [x] ISC-31: Unit test in `fleet-manager` proves retried resume for already resumed agent is idempotent and does not double-rotate.
- [x] ISC-32: Documentation `docs/signalloom/sler-p4-3-proof.md` is authored with complete mechanism details.
- [x] ISC-33: Sample structured resume decision log is documented in proof markdown.
- [x] ISC-34: `cd d2-signalloom/apps/stun-sentinel && go test ./...` passes.
- [x] ISC-35: `cd d2-signalloom/apps/fleet-manager && go test ./...` passes.
- [x] ISC-36: Anti: Resumed agent must NOT continue operating with pre-containment credentials.

## Test Strategy

- ISC-1..16: Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/` and `pkg/cgroup/`.
- ISC-17..23: Unit tests in `d2-signalloom/apps/fleet-manager/`.
- ISC-24..28: Table-driven test suite in `stun-sentinel` verifying authorization, attribution, and replay paths.
- ISC-29..31: Test suite in `fleet-manager` testing credential rotation fan-out and idempotency.
- ISC-32..33: File inspection of `docs/signalloom/sler-p4-3-proof.md`.
- ISC-34..35: `go test` runs across both Go modules.
- ISC-36: Explicit test assertion verifying credential rotation status before reporting resume success.

## Features

- Feature 1: `stun-sentinel` Ed25519 token verifier and operator key registry (`pkg/auth` or `pkg/token`).
- Feature 2: `stun-sentinel` telemetry attribution enhancement.
- Feature 3: `fleet-manager` OpenBao and SPIRE credential rotation clients.
- Feature 4: `fleet-manager` cascade resume integration with mandatory rotation.
- Feature 5: Comprehensive unit and integration test suites.
- Feature 6: Proof and attribution documentation (`docs/signalloom/sler-p4-3-proof.md`).

## Decisions

- **Token Parser & Verifier in `stun-sentinel`**: Implement standalone Ed25519 verification conforming to P1-3 wire format in `stun-sentinel/pkg/auth` so `stun-sentinel` has no cross-module runtime dependency on `fleet-manager`.
- **Key Distribution Formats**: Support loading operator key entries from a JSON file path (`OPERATOR_KEY_BUNDLE_FILE`), a directory of key files (`OPERATOR_KEY_DIR`), or inline JSON (`OPERATOR_KEYS_JSON`), accommodating DaemonSet ConfigMap volume mounts.
- **Attribution Propagation**: `stun-sentinel` extracts the signers' operator IDs and passes them to `telemetry.Emitter` so `StunExecutionResumed` includes `operator_ids` in its JSON payload.

## Changelog

- 2026-09-15: Initialized ISA for SLER-P4-3 governance-gated resume with mandatory credential rotation.

## Verification

- (Pending execution)
