---
task: Correct Zot artifact signing for Flux verification
slug: 20260726-221800_sign-zot-artifact-flux-verification
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-26T22:18:00+01:00
updated: 2026-07-26T22:32:00+01:00
---

## Context

Andrew asked to correct signing for the local D2 Zot OCI artifacts, prove Flux accepts the signature, and research the authoritative online Flux and Sigstore guidance. Docker image handling is explicitly out of scope. The live `flux-system` OCIRepository currently reports `no matching signatures` for the new Zot-hosted fleet digest, even though a local Cosign command can verify it when transparency-log verification is ignored. The implementation must preserve local key-based verification and make the signing subject discoverable under the exact registry name Flux uses.

### Risks

- Signing through `localhost:5001` can store signatures under a subject identity Flux never queries at `zot.registry.svc.cluster.local:5000`.
- Disabling verification or removing the verify block would hide rather than fix the trust-chain defect.
- A local CLI verification can differ from Flux because the verifier’s registry endpoint and tlog policy differ.

### Plan

Use official Flux and Sigstore documentation to confirm Cosign’s signature-discovery behavior. Compare the currently signed subject reference with Flux’s cluster-visible OCI URL. Make the smallest signing-script change that signs the identical Zot hostname and digest Flux verifies, preserve key verification, then reconcile and record direct cluster evidence.

## Criteria

- [x] ISC-1: Flux documentation source is captured with canonical URL.
- [x] ISC-2: Sigstore documentation source is captured with canonical URL.
- [x] ISC-3: Flux OCIRepository verifies signatures by exact artifact digest.
- [x] ISC-4: Flux OCIRepository accepts a local public-key secret reference.
- [x] ISC-5: Cosign signature repository follows subject registry naming.
- [x] ISC-6: Cosign signature repository follows subject repository naming.
- [x] ISC-7: Local signing uses Zot’s host-forward endpoint consistently.
- [x] ISC-8: Local signing subject uses the pushed artifact digest.
- [x] ISC-9: Local signing disables transparency-log upload explicitly.
- [x] ISC-10: Flux verifies local tlogless key signatures successfully.
- [x] ISC-11: Fleet artifact is pushed before signing begins.
- [x] ISC-12: Signature verification succeeds through Zot cluster service address.
- [x] ISC-13: Flux source reports Ready after reconciliation.
- [x] ISC-14: Flux source reports the freshly signed fleet digest.
- [x] ISC-15: Evidence records commands and authoritative documentation conclusions.
- [x] ISC-16: Docker image behavior remains outside this change.

## Decisions

- Publish local artifacts to `:staging`, sign the resulting digest, then promote that digest to `:latest`. Flux therefore sees `latest` only after its signature is available.
- Continue signing through the localhost Zot port-forward: live Flux verification proves both references front the same repository; changing hostnames is unnecessary.
- The live `cosign-pub` Secret hash differs from `.keys/cosign.pub`; refresh the Secret from the current local public key before reconciling.

## Verification

- Flux documentation: https://fluxcd.io/flux/components/source/ocirepositories/ specifies `provider: cosign` plus a public-key `secretRef`, then requires `SourceVerified=True` for successful verification.
- Sigstore documentation: https://docs.sigstore.dev/cosign/signing/signing_with_containers/ states that container signatures use OCI 1.1 referrers; https://docs.sigstore.dev/cosign/verifying/verify/ states that verification validates the container digest embedded in the signature payload.
- Root cause: `.keys/cosign.pub` SHA-256 was `763f4c…004b`, while the live Flux `cosign-pub` Secret held `bffd0e…77cb`. The local signing key had rotated after bootstrap.
- Refreshed the live Secret using the repository’s bootstrap-local creation command, then `flux reconcile source oci flux-system -n flux-system --timeout=2m` fetched `latest@sha256:c9bd1741d4e8185f7dc1b2b07e70f4ed4c84148cfbefc757bac023ef710c715c`.
- The OCIRepository now reports `Ready=True`, `ArtifactInStorage=True`, and `SourceVerified=True` for `oci://zot.registry.svc.cluster.local:5000/acme/fleet`.
- `bash -n scripts/push-local.sh` and `git diff --check` passed.
