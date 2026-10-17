#!/usr/bin/env bats
#
# @id      sl-upgrade-scan
# @target  .agents/skills/sl-upgrade-scan/Tools/upgrade-scan
# @target  .agents/skills/sl-upgrade-scan/Tools/upgrade-scan.ts
# @doc     .agents/skills/sl-upgrade-scan/SKILL.md
#
# Offline contracts for the upgrade-scan CLI. Every HTTP response comes from
# a canned fixture file (UPGRADE_SCAN_HTTP_FIXTURES); grype and syft are fake
# binaries. No network, no registry, no image pull. Assertions check versions,
# source URLs, fetch times and file:line, not just exit codes.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  tool="${repo_root}/.agents/skills/sl-upgrade-scan/Tools/upgrade-scan"
  fx="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$fx/infra" "$fx/svc" "$fx/scripts"
  printf 'kind: Deployment\nspec:\n  containers:\n    - image: quay.io/openbao/openbao:2.1.1\n' >"$fx/infra/bao.yaml"
  printf 'module example.com/svc\n\ngo 1.22.0\n\nrequire github.com/golang-jwt/jwt/v5 v5.2.0\n' >"$fx/svc/go.mod"
  printf '#!/usr/bin/env bash\nCHART_VERSION="0.9.9"\n' >"$fx/scripts/setup.sh"

  export UPGRADE_SCAN_NOW="2026-10-17T09:00:00.000Z"
  export UPGRADE_SCAN_NO_GH_CLI=1
  unset GITHUB_TOKEN GH_TOKEN GRYPE TRIVY SYFT
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  export UPGRADE_SCAN_HTTP_FIXTURES="$BATS_TEST_TMPDIR/http.json"
  cat >"$UPGRADE_SCAN_HTTP_FIXTURES" <<'JSON'
{
  "https://quay.io/v2/openbao/openbao/tags/list?n=1000": { "json": { "tags": ["2.1.1", "2.7.1", "2.7.1-amd64", "2.8.0-rc1"] } },
  "https://api.github.com/repos/openbao/openbao/releases?per_page=100": { "json": [
    { "tag_name": "v2.8.0-rc.1", "prerelease": true, "draft": false, "html_url": "https://github.com/openbao/openbao/releases/tag/v2.8.0-rc.1", "published_at": "2026-10-10T00:00:00Z" },
    { "tag_name": "v2.7.1", "prerelease": false, "draft": false, "html_url": "https://github.com/openbao/openbao/releases/tag/v2.7.1", "published_at": "2026-10-01T12:00:00Z" }
  ] },
  "https://proxy.golang.org/github.com/golang-jwt/jwt/v5/@latest": { "json": { "Version": "v5.3.0" } },
  "https://endoflife.date/api/go.json": { "json": [
    { "cycle": "1.27", "eol": false, "latest": "1.27.2" },
    { "cycle": "1.22", "eol": "2025-02-11", "latest": "1.22.12" }
  ] },
  "POST https://api.osv.dev/v1/querybatch": { "json": { "results": [ { "vulns": [ { "id": "GHSA-fix" } ] }, {} ] } },
  "https://api.osv.dev/v1/vulns/GHSA-fix": { "json": {
    "id": "GHSA-fix", "aliases": ["CVE-2025-30204"], "database_specific": { "severity": "HIGH" },
    "affected": [ { "package": { "name": "github.com/golang-jwt/jwt/v5", "ecosystem": "Go" },
      "ranges": [ { "type": "SEMVER", "events": [ { "introduced": "5.0.0" }, { "fixed": "5.2.2" } ] } ] } ]
  } }
}
JSON
  # PATH without syft: bun, git and coreutils only.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -sf "$(command -v bun)" "$bin/bun"
  ln -sf "$(command -v git)" "$bin/git"
  export PATH="$bin:/usr/bin:/bin"
}

@test "unit suites (version, inventory, sources, risk and ranking) pass" {
  run bun test "$repo_root/test/unit/sl-upgrade-scan/"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *" 0 fail"* ]]
}

@test "inventory is offline and gives exact file:line" {
  unset UPGRADE_SCAN_HTTP_FIXTURES
  run "$tool" inventory --root "$fx" --json -
  [ "$status" -eq 0 ]
  [ "$(jq -r '.items[] | select(.name=="quay.io/openbao/openbao") | "\(.current) \(.locations[0].file):\(.locations[0].line)"' <<<"$output")" = "2.1.1 infra/bao.yaml:4" ]
  [ "$(jq -r '.items[] | select(.name=="github.com/golang-jwt/jwt/v5") | .locations[0].line' <<<"$output")" = "5" ]
}

@test "scan reports OpenBao 2.1.1 -> 2.7.1 with source URL, fetch time and file:line" {
  run "$tool" scan --root "$fx" --json "$BATS_TEST_TMPDIR/r.json" --md "$BATS_TEST_TMPDIR/r.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  j="$BATS_TEST_TMPDIR/r.json"
  [ "$(jq -r '.findings[] | select(.name=="quay.io/openbao/openbao") | .recommended' "$j")" = "2.7.1" ]
  [ "$(jq -r '.findings[] | select(.name=="quay.io/openbao/openbao") | .latest.sourceUrl' "$j")" = "https://quay.io/v2/openbao/openbao/tags/list?n=1000" ]
  [ "$(jq -r '.findings[] | select(.name=="quay.io/openbao/openbao") | .latest.fetchedAt' "$j")" = "2026-10-17T09:00:00.000Z" ]
  [ "$(jq -r '.findings[] | select(.name=="quay.io/openbao/openbao") | .upstream_release.version' "$j")" = "v2.7.1" ]
  row="$(grep -F 'quay.io/openbao/openbao' "$BATS_TEST_TMPDIR/r.md")"
  [[ "$row" == *"| 2.1.1 | 2.7.1 | minor |"* ]]
  [[ "$row" == *"infra/bao.yaml:4"* ]]
  [[ "$row" == *"https://github.com/openbao/openbao/releases/tag/v2.7.1 published 2026-10-01"* ]]
}

@test "the CVE fixed by the upgrade ranks the jwt bump first; the EOL Go runtime is flagged" {
  run "$tool" scan --root "$fx" --json "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].name' "$BATS_TEST_TMPDIR/o.json")" = "github.com/golang-jwt/jwt/v5" ]
  [ "$(jq -r '.findings[0].vulns.fixedByUpgrade[0].aliases[0]' "$BATS_TEST_TMPDIR/o.json")" = "CVE-2025-30204" ]
  [ "$(jq -r '.findings[] | select(.name=="go") | .eol.eol' "$BATS_TEST_TMPDIR/o.json")" = "true" ]
}

@test "an unmapped tool is reported unknown with its reason, never given a version" {
  run "$tool" scan --root "$fx" --md -
  [ "$status" -eq 0 ]
  line="$(grep -F 'tool-pin chart 0.9.9' <<<"$output")"
  [[ "$line" == *"no upstream mapping"* ]]
  [ "$(grep -c '| tool-pin chart' <<<"$output")" -eq 0 ]
}

@test "the disk cache serves a second run with zero network calls" {
  run "$tool" scan --root "$fx" --json "$BATS_TEST_TMPDIR/o.json"
  [ "$(jq -r '.network_calls' "$BATS_TEST_TMPDIR/o.json")" -gt 0 ]
  echo '{}' >"$UPGRADE_SCAN_HTTP_FIXTURES"
  run "$tool" scan --root "$fx" --json "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.network_calls' "$BATS_TEST_TMPDIR/o.json")" = "0" ]
  [ "$(jq -r '.findings[] | select(.name=="quay.io/openbao/openbao") | .recommended' "$BATS_TEST_TMPDIR/o.json")" = "2.7.1" ]
}

@test "--fail-on high exits 1 when an upgrade fixes a HIGH, 0 at critical" {
  run "$tool" scan --root "$fx" --json /dev/null --fail-on high
  [ "$status" -eq 1 ]
  run "$tool" scan --root "$fx" --json /dev/null --fail-on critical
  [ "$status" -eq 0 ]
}

@test "--image-scanner grype diffs current and recommended image scans" {
  cat >"$bin/fake-grype" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/grype.log"
case "$1" in
  *:2.1.1) echo '{"matches":[{"vulnerability":{"id":"CVE-2026-0001","severity":"Critical"}},{"vulnerability":{"id":"CVE-2026-0002","severity":"Low"}}]}' ;;
  *) echo '{"matches":[{"vulnerability":{"id":"CVE-2026-0002","severity":"Low"}}]}' ;;
esac
SH
  chmod +x "$bin/fake-grype"
  GRYPE="$bin/fake-grype" run "$tool" scan --root "$fx" --image-scanner grype --json "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'registry:quay.io/openbao/openbao:2.7.1' "$BATS_TEST_TMPDIR/grype.log"
  [ "$(jq -r '.findings[0].name' "$BATS_TEST_TMPDIR/o.json")" = "quay.io/openbao/openbao" ]
  [ "$(jq -r '.findings[0].vulns.fixedByUpgrade | map(.id) | join(",")' "$BATS_TEST_TMPDIR/o.json")" = "CVE-2026-0001" ]
}

@test "--sbom-out says syft is not installed and writes nothing" {
  run "$tool" scan --root "$fx" --sbom-out "$BATS_TEST_TMPDIR/sbom" --json "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sbom.status' "$BATS_TEST_TMPDIR/o.json")" = "unavailable" ]
  [[ "$(jq -r '.sbom.reason' "$BATS_TEST_TMPDIR/o.json")" == *"syft is not installed"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/sbom/sbom.spdx.json" ]
}

@test "--sbom-out runs syft for SPDX and CycloneDX when it is present" {
  cat >"$bin/syft" <<'SH'
#!/usr/bin/env bash
echo "$*" >"$BATS_TEST_TMPDIR/syft.args"
for a in "$@"; do case "$a" in *=*) : >"${a#*=}" ;; esac; done
SH
  chmod +x "$bin/syft"
  run "$tool" scan --root "$fx" --sbom-out "$BATS_TEST_TMPDIR/sbom" --json "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sbom.status' "$BATS_TEST_TMPDIR/o.json")" = "written" ]
  [ -e "$BATS_TEST_TMPDIR/sbom/sbom.spdx.json" ]
  [ -e "$BATS_TEST_TMPDIR/sbom/sbom.cdx.json" ]
  grep -qF "dir:$fx" "$BATS_TEST_TMPDIR/syft.args"
}

@test "usage errors exit 2" {
  run "$tool" --bogus
  [ "$status" -eq 2 ]
  run "$tool" --image-scanner clair
  [ "$status" -eq 2 ]
}
