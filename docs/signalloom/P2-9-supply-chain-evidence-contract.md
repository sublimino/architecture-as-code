# P2-9 supply-chain evidence contract

<!-- machine-tag: signalloom-p2-9-supply-chain-evidence -->
<!-- generated-at: 2026-07-26T04:59:59+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- baseline-sha: 6d1eab6 -->

This repository-local contract defines the evidence that a Signal Loom artifact
must carry before it can be considered for delivery. It is a static,
non-production control definition: it does not provision infrastructure, create
keys, publish artifacts, or assert that a live environment has accepted one.

`docs/signalloom/delivery-contract.json` is the machine-checked source of the
requirements below. `make signalloom-contract-check` fails if a required
constraint is removed or weakened.

## Signer constraints

| Context | Required signer | Constraint | Evidence retained |
| --- | --- | --- | --- |
| CI | Cosign keyless OIDC | Issuer is `https://token.actions.githubusercontent.com`; certificate subject matches only the named `push-images`, `push-artifacts`, or `release-artifacts` workflow in `controlplaneio-in-toto/osramp-demo`, from `main` or a semver tag. | Verification command, certificate identity/issuer, signature reference, resolved digest, and verifier exit status. |
| Local demo | Cosign key | Trust is rooted only at `.keys/cosign.pub`; scope is `local-demo-only`. Local keys are not release authority. | Public-key fingerprint, verification command, signature reference, resolved digest, and verifier exit status. |

The CI subject expression is deliberately narrower than a repository-wide
identity. A workflow rename, repository move, unexpected branch, or an
unrecognised workflow requires an explicit contract change and review.

## Immutable digest and evidence binding

An artifact identity is `repository@sha256:<64 lowercase hex characters>`.
Tags are discovery pointers only and must be resolved before verification.
Every signature, SBOM, provenance statement, promotion decision, rollback
record, and revocation event records that same digest. A digest mismatch is a
verification failure, even if a tag still resolves successfully.

Required evidence set, all bound to one resolved digest:

1. Cosign signature and the accepted signer identity/trust anchor.
2. The resolved SHA-256 digest and immutable repository reference.
3. SPDX JSON SBOM for that digest.
4. SLSA v1 provenance for that digest.

Verification is fail-closed: absent, unverifiable, malformed, or
digest-mismatched evidence rejects the artifact. The verifier records the exact
command, input reference, verifier version, result, timestamp with offset, and
the four evidence references. Do not turn a failed verification into a warning.

## SBOM and provenance minimums

The SBOM is required in `spdx-json` form and identifies the artifact digest it
`https://slsa.dev/provenance/v1`; it records the build identity, source revision,
subject digest to the resolved artifact digest before accepting either document.

This contract names evidence requirements, not an unearned runtime claim. The
existing workflow declarations produce image SBOM and provenance, while an
attestation-verification command and durable storage location must be captured
by the delivery run that seeks release qualification.

## Revocation and rotation evidence

**Revocation:** withdraw the affected signer identity or trust anchor, reject
newly resolved artifacts dependent on it, and retain the failed verification
record with the digest, rejected identity, policy/trust-anchor version, and
timestamp. Existing cached success is not evidence for a newly resolved digest.

**Rotation:** introduce the replacement trust anchor under an explicit overlap
window; record successful verification of a known digest by both old and new
anchors; remove the old anchor; then record a negative verification proving the
old anchor is rejected. The evidence ledger includes old/new fingerprints,
policy version, overlap start/end, commands, digests, and all exit statuses.

The local `make revocation-demo` remains a demonstration mechanism only. It is
not evidence of a production revocation service or a completed rotation.

## ISO-offset errata

<!-- machine-tag: P2-9-ERRATA-2026-07-26T04:59:59+01:00 -->
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

This P2-9 errata records a prior ambiguity: a signed tag alone did not specify
the signer identity boundary, immutable digest binding, SBOM/provenance subject
comparison, or the evidence required to prove revocation and rotation. The
version-2 delivery contract now makes those boundaries machine-checkable. This
PASS applies to the static contract and its tests only; no production acceptance
or external verification is implied.
