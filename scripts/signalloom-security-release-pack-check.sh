#!/usr/bin/env bash

set -Eeuo pipefail

die() {
	printf 'signalloom-security-release-pack-check: %s\n' "$1" >&2
	exit 1
}

[[ "$#" -eq 1 ]] || die "usage: $0 RELEASE_PACK_PATH"

release_pack_path="$1"
[[ -f "$release_pack_path" ]] || die "missing release-pack template: $release_pack_path"

for heading in \
	'## Candidate identity' \
	'## Evidence ledger' \
	'## Gate dispositions and acceptance criteria' \
	'## Exceptions' \
	'## Approvals' \
	'## Rollback reference' \
	'## Release decision'; do
	grep -Fqx "$heading" "$release_pack_path" || die "missing required heading: $heading"
done

for gate in sast dast sca secret-scan sbom pentest; do
	grep -Fq "| $gate " "$release_pack_path" || die "missing required gate: $gate"
done

grep -Fqx '<!-- release-pack: candidate-only-template -->' "$release_pack_path" || \
	die "release pack must remain a candidate-only template"
grep -Fqx '<!-- release-decision: no-go-until-complete -->' "$release_pack_path" || \
	die "release pack must retain its fail-closed no-go decision"

printf 'Signal Loom security release-pack template passed: required gate evidence and fail-closed decision are present.\n'
