# SLDPB25-P2-2 — Dashboard image supply-chain evidence

Regenerate with `make signalloom-dashboard-image` (wraps `scripts/build-sign-dashboard.sh`).
The resolved image digest, signature, SBOM, and provenance are recorded here.
The binding limitations for the local-demo evidence are described below.

| Artifact | File | Producer |
|----------|------|----------|
| Resolved digest | `dashboard-signalloom.digest.txt` | `crane digest` of the pushed image |
| SBOM (SPDX-2.3, spdx-json) | `dashboard-signalloom.sbom.spdx.json` | BuildKit syft scanner (`--sbom=true`) |
| Provenance (SLSA) | `dashboard-signalloom.provenance.slsa.json` | BuildKit (`--provenance=mode=max`) |
| Signature | in-registry cosign signature on the digest | `cosign sign --key .keys/cosign.key` |

Verify the signature (with the zot registry port-forwarded to `localhost:5001`):

```bash
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog --allow-insecure-registry \
  "localhost:5001/acme/images/signalloom/apps/dashboard-signalloom@$(cat docs/signalloom/evidence/dashboard-signalloom.digest.txt)"
```

## Known scoped delta — provenance predicate version

The delivery contract (`docs/signalloom/delivery-contract.json`) targets
`provenancePredicateType: https://slsa.dev/provenance/v1`. Docker BuildKit v0.23 (the local
builder) emits **`https://slsa.dev/provenance/v0.2`**. For the local-demo TRL-2 scope this is a
`risk-accepted-exception`: the provenance is genuine, tool-produced BuildKit provenance; only the
predicate schema version differs. The CI/release path (`cosign-keyless-oidc`, GitHub Actions) is
where a v1 predicate is produced for the promotion decision. Do not fabricate a v1 predicate locally.

## Known scoped delta — evidence/signature digest binding (cross-vendor audit: CONCERNS, not-a-blocker)

Two limitations, confirmed by an independent GPT-5.4 supply-chain audit this session, are acceptable
for local-demo TRL-2 and are the explicit handoff to **SLDPB25-P2-GOV / P3-1**:

1. **Two-build binding.** The SBOM/provenance are extracted from a `buildx --output type=oci` build,
   while the cosign signature binds to the digest of a second `buildx --load` build (docker store →
   `crane push`). Same Dockerfile/context/content, but the two builds can resolve to different digests
   (BuildKit metadata, timestamps, manifest conversion). The evidence is representative, not
   cryptographically pinned to the signed subject. **Hardening (P2-GOV):** single `buildx --push` to
   an OCI-index-capable registry, then sign that index digest and attach the SBOM/provenance to it.
2. **Deploy-by-tag.** `dashboard-deployment.yaml` references `…:${ARTIFACT_TAG}` (mutable tag), and the
   kyverno signature policy enforces only in namespace `admission-demo`. So runtime does not yet *prove*
   it runs the signed digest. **Hardening (P3-1):** digest-pin the manifest and extend the kyverno
   `verifyImages` match to the signalloom namespace.

Neither is a P2-2 blocker: P2-2's contract is "build/sign the image + deploy nginx Service/SPA/readiness
+ unit/container tests" — all met and tool-verified. Digest-pinning and admission enforcement are the
governor/gateway cards by design.
