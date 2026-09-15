---
task: "SLER-P5-1: Emit Witness-attested forensic records linking authorization to containment"
project: "osramp-demo"
slug: "sler-p5-1"
effort: "E4"
effort_source: "explicit"
phase: "verify"
progress: "36/36"
mode: "algorithm"
started: "2026-09-15T07:23:29+01:00"
updated: "2026-09-15T07:35:00+01:00"
---

# ISA: SLER-P5-1 Cryptographic Witness Attestation & Forensic Ledger Engine

## Problem
Prior to Phase 5, all telemetry generated across the multi-plane containment cascade (`fleet-manager`) and the node freezer daemon (`stun-sentinel`) consisted exclusively of unauthenticated, unsigned JSON strings written to stdout via `pkg/telemetry/emitter.go`. While these logs recorded operational outcomes, they lacked cryptographic integrity, tamper-evidence, and non-repudiation. An attacker or rogue process on a node could forge or alter containment logs, and compliance auditors could not mathematically prove that a given containment action was genuinely authorized by upstream security policy decisions (Signal Fusion).

## Vision
Every multi-plane containment action (across mesh, OpenBao, SPIRE, admission controller, and cgroup-v2 freezer) and every governance-authorized resume event emits a cryptographically signed, tamper-evident forensic ledger record in in-toto Statement v1 / DSSE format. The record irrevocably binds the root authorization decision chain to the multi-plane containment outcome, enabling instant cryptographic verification via Witness / DSSE tooling and surviving key rotations across historical archives.

## Out of Scope
- Contacting live customer infrastructure or production clusters.
- Modifying upstream SLDP identity derivation or external key schemas.
- Ingesting customer sensitive payload contents, prompt text, or raw secrets.
- Claiming synthetic latency figures not grounded in actual execution benchmarks.

## Principles
1. **Cryptographic Non-Repudiation**: Evidence must be self-authenticating via asymmetric cryptography (Ed25519) and DSSE Pre-Authentication Encoding (PAE).
2. **Fail-Closed Accountability**: Containment actions must not be reported as successful if the cryptographic attestation pipeline fails to produce a valid record.
3. **Causal Traceability ("Why" and "What")**: The forensic record must bind the root authorization decision chain (`why`) to the execution outcome (`what`).
4. **Key Rotation Survivability**: Records signed under previous keys must remain verifiable via an immutable key history ledger.
5. **Zero Key Leakage**: Private key material must never cross into logs, error messages, or record payloads.

## Constraints
1. **Schema Freeze**: Conformance with `sler.signalloom.io/v1alpha1` and in-toto Statement v1 (`https://in-toto.io/Statement/v1`).
2. **In-Process Performance**: In-memory signing must complete in microseconds to prevent degradation of kernel-level containment latency.
3. **Target Identity Alignment**: Target representation must exactly match `admission_client` and `mesh_client` contracts.
4. **Forward Compatibility**: Verifiers built against older schema versions must continue to verify valid signatures over newer additive fields.

## Goal
Implement and wire a production-grade in-process cryptographic attestation engine (`pkg/attestation`) across `fleet-manager` and `stun-sentinel` that produces, signs, and verifies DSSE-enveloped in-toto forensic ledger records for 100% of containment and resume actions, providing tamper-evidence, rotation-resilient key history, and sub-millisecond attestation latency.

## Criteria
- [x] ISC-1: Define `ForensicLedgerRecord`, `AuthorizationEvidence`, `TargetIdentity`, `ExecutionEvidence`, and `AttestationEnvelopeMetadata` Go types matching P5-PRE specification.
- [x] ISC-2: Implement in-process `LocalEd25519Signer` supporting PKCS#8 / PEM key loading and DER SPKI KeyID derivation.
- [x] ISC-3: Implement in-toto Statement v1 formatting with `https://controlplane.io/attestations/signalloom-containment/v1` and `https://controlplane.io/attestations/signalloom-resume/v1` predicate types.
- [x] ISC-4: Implement canonical DSSE Pre-Authentication Encoding (`PAE;application/vnd.in-toto+json;...`) formatting and Ed25519 signing.
- [x] ISC-5: Implement `AttestationEngine` in `d2-signalloom/apps/fleet-manager/pkg/attestation` providing `AttestContainmentDecision` and `AttestResumeDecision`.
- [x] ISC-6: Implement cryptographic `ForensicVerifier` validating DSSE signatures, KeyID matching, and payload digests.
- [x] ISC-7: Implement `KeyHistoryStore` supporting key rotation and multi-key historical verification.
- [x] ISC-8: Wire `AttestationEngine` into `d2-signalloom/apps/fleet-manager/cascade.go` so containment actions emit signed forensic records.
- [x] ISC-9: Wire `AttestationEngine` into governance resume handling in `cascade.go` so resume actions emit signed forensic records.
- [x] ISC-10: Update `d2-signalloom/apps/stun-sentinel/pkg/telemetry/emitter.go` to carry `AttestationID` and `WitnessDigest` on operational telemetry events.
- [x] ISC-11: Implement round-trip unit test verifying genuine containment forensic records pass cryptographic verification.
- [x] ISC-12: Implement tamper-evidence test mutating single bytes in payload or signature and proving verification fails closed.
- [x] ISC-13: Implement failure-injection test proving containment fails closed and is not reported as success when attestation signing fails.
- [x] ISC-14: Implement key rotation test proving records signed under rotated keys remain verifiable against retained key history.
- [x] ISC-15: Implement secret leakage prevention test asserting zero private key bytes appear in logs, errors, or serialized records.
- [x] ISC-16: Implement trusted timestamp test proving record timestamps originate from an authenticated, monotonic UTC time source.
- [x] ISC-17: Implement schema forward-compatibility test proving verifiers accept records with additive fields without breaking signature validation.
- [x] ISC-18: Implement target identity alignment test verifying exact match with `admission_client` and `mesh_client` data structures.
- [x] ISC-19: Implement 100-event concurrent batch load test asserting 100% attestation success and measuring p50/p95/p99 latency.
- [x] ISC-20: Implement causal chain verification test cross-referencing `authorization.decision_id` and `attestation_digest` against root triggers.
- [x] ISC-21: Benchmark and publish microsecond-level in-process attestation latency.
- [x] ISC-22: Create comprehensive proof documentation in `docs/signalloom/sler-p5-1-proof.md`.
- [x] ISC-23: Pass `cd d2-signalloom/apps/fleet-manager && go test ./...`.
- [x] ISC-24: Pass `cd d2-signalloom/apps/stun-sentinel && go test ./...`.
- [x] ISC-25: Ensure `grep -rn 'witness' --include=*.go` in `fleet-manager` and `stun-sentinel` finds genuine runtime attestation code.
- [x] ISC-26: Pass `bash scripts/run-redteam-suite.sh`.
- [x] ISC-27: Verify `Makefile` signing-key dependencies and references.
- [x] ISC-28: Append qualified `Errata — SLER-P5-1` block with `status=pass` to Obsidian proposal.
- [x] ISC-29: Update `Result` column in proposal Work Decomposition table.
- [x] ISC-30: Create clean conventional git commit for SLER-P5-1.
- [x] ISC-31: Anti: Must NOT report containment success if cryptographic signing fails.
- [x] ISC-32: Anti: Must NOT log or expose private key material under any error path.
- [x] ISC-33: Anti: Must NOT use subprocess shell calls (`os/exec`) on the latency-sensitive fast path.
- [x] ISC-34: Anti: Must NOT break backwards compatibility when adding new forensic ledger fields.
- [x] ISC-35: Anti: Must NOT use mismatched target identity schemas across admission, mesh, and attestation.
- [x] ISC-36: Anti: Must NOT allow unsigned or partially signed records into the forensic ledger.

## Test Strategy
- `pkg/attestation` Unit Tests: Pure Go tests asserting crypto signing, DSSE formatting, PAE generation, and verifier logic.
- Round-trip & Tamper Tests: Bit-flip mutation testing on payload, signature, keyid, and timestamp.
- Failure Injection Tests: Mock signers returning errors or simulated inaccessible keys verifying fail-closed cascade behavior.
- Concurrency & Load Benchmarks: `sync.WaitGroup` parallel test executing 100+ concurrent containment events measuring latency distribution.
- Key Rotation Tests: Multi-generation keypair fixtures validating history lookup and signature retention.
- End-to-End Cascade Tests: Verification of full containment cascade resulting in verified forensic records.

## Features
- `pkg/attestation` Core: Types, Signer interface, `LocalEd25519Signer`, `ForensicVerifier`, `KeyHistoryStore`.
- `fleet-manager` Integration: Attestation engine wiring in `cascade.go` for containment dispatch and governance resume.
- `stun-sentinel` Telemetry Upgrade: Attestation digest binding in `emitter.go`.
- Verification & Benchmarking Suite: Unit tests, benchmarks, tamper-evidence tests, and documentation.

## Decisions
- 2026-09-15: Selected Option B (Native In-Process Go Signing) per P5-PRE architecture decision for <50µs latency and zero external binary dependencies.
- 2026-09-15: Adopted standard in-toto Statement v1 + DSSE envelope (`application/vnd.in-toto+json`) for universal compatibility with Witness and in-toto verifiers.

## Changelog
- 2026-09-15: Initial articulation of SLER-P5-1 ISA.
- 2026-09-15: Completed implementation, integration, benchmarks, proof documentation, and verification for SLER-P5-1.

## Verification
- ISC-1..7: Verified by 100% pass of unit tests in `d2-signalloom/apps/fleet-manager/pkg/attestation`.
- ISC-8..9: Verified by `cascade.go` and `resume_token.go` attestation wiring and `contract_freeze_test.go`.
- ISC-10: Verified by `emitter_test.go:TestStunExecutionCarriesWitnessAttestationDigest`.
- ISC-11..20: Verified by 11/11 dedicated unit & contract tests in `attestation_test.go`.
- ISC-21: Verified by `BenchmarkAttestationLatency` (36.7 µs) and `BenchmarkVerificationLatency` (94.5 µs).
- ISC-22: Verified by publication of `docs/signalloom/sler-p5-1-proof.md`.
- ISC-23..24: Verified by `go test -count=1 ./...` in `fleet-manager` and `stun-sentinel`.
- ISC-25: Verified by `grep -rn 'witness' --include=*.go` returning 20+ runtime code occurrences.
- ISC-26: Verified by `bash scripts/run-redteam-suite.sh` (15/15 passed).
- ISC-27: Verified by `grep -n 'witness.pem\|witness-pub.pem' Makefile`.
- ISC-28..29: Verified by Obsidian bridge updates to proposal errata and work decomposition table.
- ISC-30: Verified by git commit on worktree branch.
- ISC-31..36: Anti-requirements verified green by fail-closed, zero-leak, and forward-compatibility tests.
