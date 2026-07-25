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
  .schemaVersion == 1 and
  (.repository | type == "string" and length > 0) and
  (.integrationBranch | type == "string" and test("^integration/[a-z][a-z0-9-]*-v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.releaseBranch == "main") and
  (.requiredRoots | type == "array" and length == 4) and
  (.deploymentGuard | type == "string" and length > 0)
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
git merge-base --is-ancestor "$contract_release" "$contract_branch" || die "$contract_release is not an ancestor of $contract_branch"

printf 'Signal Loom delivery contract passed: %s → %s → %s; deployment guard is active.\n' \
	"$contract_release" "$contract_branch" "$contract_repo"
