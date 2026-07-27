#!/usr/bin/env bash

set -Eeuo pipefail

die() {
	printf 'signalloom-contract-check: %s\n' "$1" >&2
	exit 1
}

[[ "$#" -eq 2 ]] || die "usage: $0 CONTRACT_PATH INTEGRATION_BRANCH"

contract_path="$1"
integration_branch="$2"

[[ -f "$contract_path" ]] || die "missing contract: $contract_path"
command -v jq >/dev/null 2>&1 || die "jq is required to validate the delivery contract"

jq -e '
  .schemaVersion == 2 and
  (.repository | type == "string" and length > 0) and
  (.integrationBranch | type == "string" and test("^integration/[a-z][a-z0-9-]*-v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.releaseBranch == "main") and
  (.requiredRoots | type == "array" and length == 4) and
  (.deploymentGuard | type == "string" and length > 0) and
  (.signer.ci.provider == "cosign-keyless-oidc") and
  (.signer.ci.issuer == "https://token.actions.githubusercontent.com") and
  (.signer.ci.subjectRegex | type == "string" and startswith("^https://github\\.com/controlplaneio-in-toto/osramp-demo/")) and
  (.signer.local.provider == "cosign-key") and
  (.signer.local.trustAnchorPath == ".keys/cosign.pub") and
  (.signer.local.scope == "local-demo-only") and
  (.immutableDigest.algorithm == "sha256") and
  (.immutableDigest.referenceRegex == "^sha256:[a-f0-9]{64}$") and
  (.immutableDigest.tagPolicy | type == "string" and length > 0) and
  (.sbomProvenance.sbomRequired == true) and
  (.sbomProvenance.sbomFormat == "spdx-json") and
  (.sbomProvenance.provenanceRequired == true) and
  (.sbomProvenance.provenancePredicateType == "https://slsa.dev/provenance/v1") and
  (.verification.failClosed == true) and
  (.verification.requiredEvidence == ["signature", "resolved-digest", "sbom", "provenance"]) and
  (.securityAssurance.evidenceScope == "candidate-only; repository-local definition; no production credentials, data, cloud resources, external scans, or release action") and
  (.securityAssurance.requiredGates == ["sast", "dast", "sca", "secret-scan", "sbom", "pentest"]) and
  (.securityAssurance.acceptedDispositions == ["pass", "risk-accepted-exception", "not-applicable"]) and
  (.securityAssurance.rejectedDispositions == ["not-run", "warning-only", "unverified", "digest-mismatch", "expired-exception"]) and
  (.securityAssurance.releasePack.path == "docs/signalloom/security-release-pack.md") and
  (.securityAssurance.releasePack.requiredFields == ["candidate-identity", "evidence-ledger", "gate-dispositions", "exceptions", "approvals", "rollback-reference", "release-decision"]) and
  (.securityAssurance.releasePack.releaseDecision == "fail-closed; no-go until every required gate has a current accepted disposition bound to the candidate digest") and
  (.revocationRotation.revocation | type == "string" and length > 0) and
  (.revocationRotation.rotation | type == "string" and length > 0)
' "$contract_path" >/dev/null || die "contract schema or branch policy is invalid"

contract_branch="$(jq -r '.integrationBranch' "$contract_path")"
contract_release="$(jq -r '.releaseBranch' "$contract_path")"
contract_repo="$(jq -r '.repository' "$contract_path")"

[[ "$integration_branch" == "$contract_branch" ]] || die "Makefile integration branch ($integration_branch) differs from contract ($contract_branch)"

git rev-parse --show-toplevel >/dev/null 2>&1 || die "must run inside a git repository"
common_git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
[[ "$(basename "$(dirname "$common_git_dir")")" == "$contract_repo" ]] || die "repository basename differs from contract: expected $contract_repo"
git rev-parse --verify "refs/heads/$contract_branch" >/dev/null || die "missing local integration branch: $contract_branch"
git rev-parse --verify "refs/heads/$contract_release" >/dev/null || die "missing local release branch: $contract_release"
git merge-base --is-ancestor "$contract_branch" HEAD || die "$contract_branch is not an ancestor of HEAD"

printf 'Signal Loom delivery contract passed: %s → %s → %s; supply-chain evidence guard is active.\n' \
	"$contract_release" "$contract_branch" "$contract_repo"
