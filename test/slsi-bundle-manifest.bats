#!/usr/bin/env bats
#
# SLSI-P1-3: Manifest compilation and bundle assembly acceptance suite.
# Hermetic, offline verification of MANIFEST.json schema, cryptographic gates,
# dual-aspect sealing (correctness & completeness), and archive determinism.
#
# @id     slsi-bundle-manifest-bats
# @target scripts/package-tenant-bundle.sh
# @schema schemas/slsi-appliance-manifest-schema.json
# @task   SLSI-P1-3

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA_FILE="$REPO_ROOT/schemas/slsi-appliance-manifest-schema.json"
  SCHEMA_VALIDATOR="$REPO_ROOT/scripts/lib/json-schema-lite.jq"
  DIST_DIR="$REPO_ROOT/dist"
  MANIFEST_JSON="$DIST_DIR/MANIFEST.json"
  ARCHIVE="$(ls "$DIST_DIR"/slsi-appliance-*.tar.gz 2>/dev/null | head -n 1 || true)"
}

@test "MANIFEST.json exists and conforms to slsi-bundle/v1 schema" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$SCHEMA_FILE" ]
  [ -f "$SCHEMA_VALIDATOR" ]

  run jq -e '.schema == "slsi-bundle/v1"' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]

  violations="$(jq -n -r --slurpfile schema "$SCHEMA_FILE" --slurpfile doc "$MANIFEST_JSON" --arg ptr '#' -f "$SCHEMA_VALIDATOR")"
  [ -z "$violations" ]
}

@test "MANIFEST.json carries all required root fields with non-empty type-correct values" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    .schema == "slsi-bundle/v1" and
    (.bundle.name | test("^slsi-appliance-")) and
    (.bundle.version | test("^[0-9]")) and
    (.git.commit | test("^[0-9a-f]{40}$")) and
    (.releaseKey.fingerprint | test("^[0-9a-f]{64}$")) and
    (.payload | length > 0) and
    (.images | length > 0) and
    ([.payload[].sha256] | map(select(test("^[0-9a-f]{64}$"))) | length) == (.payload | length)
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "Seal CORRECTNESS: every path listed in payload matches its claimed checksum" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  (
    cd "$bundle_root" && \
    jq -r '.payload[] | "\(.sha256) \(.path)"' MANIFEST.json | sha256sum -c --strict -
  )
  status_c=$?

  rm -rf "$bundle_root"
  [ "$status_c" -eq 0 ]
}

@test "Seal COMPLETENESS: no file exists in bundle that is unlisted in MANIFEST.json" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  on_disk="$(cd "$bundle_root" && find . -type f ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort)"
  declared="$(jq -r '.payload[].path' "$bundle_root/MANIFEST.json" | LC_ALL=C sort)"

  [ -n "$on_disk" ]
  [ -n "$declared" ]
  diff <(printf '%s\n' "$on_disk") <(printf '%s\n' "$declared")
  diff_status=$?

  rm -rf "$bundle_root"
  [ "$diff_status" -eq 0 ]
}

@test "Every image in MANIFEST.json is pinned by immutable digest with zero tag-only references" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$REPO_ROOT/bundle/images/index.json" ]

  run jq -e '
    ([.images[].digest] | map(select(test("^sha256:[0-9a-f]{64}$"))) | length) == (.images | length) and
    ([.images[] | select(.reference | test(":[^@/]+$"))] | length) == 0
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]

  diff <(jq -r '.images[].digest' "$MANIFEST_JSON" | LC_ALL=C sort -u) \
       <(jq -r '.manifests[].digest' "$REPO_ROOT/bundle/images/index.json" | LC_ALL=C sort -u)
}

@test "Decision 10 utility image is present, digest-pinned, and provides openssl and envsubst" {
  [ -f "$MANIFEST_JSON" ]
  [ -f "$REPO_ROOT/bundle/images/index.json" ]

  run jq -e '
    [.images[] | select(.role == "utility")] | length == 1 and
    (.[0].digest | test("^sha256:[0-9a-f]{64}$")) and
    (.[0].provides | sort == ["envsubst", "openssl"])
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]

  util_d="$(jq -r '.images[] | select(.role == "utility") | .digest' "$MANIFEST_JSON")"
  run jq -e --arg d "$util_d" '[.manifests[] | select(.digest == $d)] | length == 1' "$REPO_ROOT/bundle/images/index.json"
  [ "$status" -eq 0 ]
}

@test "bundle/bin/checksums.txt covers exactly the five staged binaries without openssl or envsubst" {
  [ -f "$REPO_ROOT/bundle/bin/checksums.txt" ]

  staged="$(grep -E '(amd64|arm64)/' "$REPO_ROOT/bundle/bin/checksums.txt" | cut -d' ' -f3- | xargs -n1 basename | LC_ALL=C sort -u)"
  diff <(printf '%s\n' "$staged") <(printf '%s\n' cosign flux jq kind kubectl)

  run bash -c "test \"\$(printf '%s\n' \"\$staged\" | grep -cE '^(openssl|envsubst)\$')\" -eq 0"
  [ "$status" -eq 0 ]
}

@test "No unresolved-digest sentinel reaches MANIFEST.json" {
  [ -f "$MANIFEST_JSON" ]
  run grep -cF 'DIGEST-UNRESOLVED' "$MANIFEST_JSON"
  [ "$output" = "0" ]

  run grep -cF 'UNRESOLVED_UPSTREAM' "$MANIFEST_JSON"
  [ "$output" = "0" ]
}

@test "Release public key fingerprint matches shipped release.pub" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]
  [ -f "$REPO_ROOT/scripts/lib/eap-evidence.sh" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  source "$REPO_ROOT/scripts/lib/eap-evidence.sh"
  fp="$(cd "$bundle_root" && eap_pubkey_fingerprint ./keys/release.pub)"
  [ -n "$fp" ]

  manifest_fp="$(jq -r .releaseKey.fingerprint "$bundle_root/MANIFEST.json")"
  rm -rf "$bundle_root"

  [ "$fp" = "$manifest_fp" ]
}

@test "Git metadata accurately describes source tree" {
  [ -f "$MANIFEST_JSON" ]
  expected_commit="$(git -c log.showSignature=false rev-parse HEAD)"
  expected_dirty="$([ -n "$(git status --porcelain)" ] && echo true || echo false)"

  run jq -r .git.commit "$MANIFEST_JSON"
  [ "$output" = "$expected_commit" ]

  run jq -r .git.dirty "$MANIFEST_JSON"
  [ "$output" = "$expected_dirty" ]
}

@test "Archive filesystem hierarchy contains exactly declared top-level trees" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]
  [ -f "$REPO_ROOT/test/fixtures/slsi/expected-toplevel.txt" ]

  members="$(tar -tzf "$ARCHIVE")"
  [ -n "$members" ]

  diff <(printf '%s\n' "$members" | awk -F/ 'NF>0 {print $1}' | LC_ALL=C sort -u) \
       "$REPO_ROOT/test/fixtures/slsi/expected-toplevel.txt"
}

@test "Manifest payload uses relative paths with dot verification root" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    (.payload | map(select(.path | test("^/") or test("^\\.\\.") or test("^\\./"))) | length == 0) and
    (.verify.root == "." and (.verify.command | test("sha256sum")))
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "Zero private keys or sensitive credentials exist in archive" {
  [ -n "$ARCHIVE" ]
  [ -f "$ARCHIVE" ]

  bundle_root="$(mktemp -d)"
  tar -xzf "$ARCHIVE" -C "$bundle_root"

  privkey_content="$(grep -rEn '-----BEGIN ([A-Z0-9 ]+)?PRIVATE KEY-----' "$bundle_root" || true)"
  privkey_files="$(find "$bundle_root" -type f \( -name "*.key" -o -name "cosign.key" -o -name "release.key" -o -name "*-escrow.tar.enc" \) || true)"
  rm -rf "$bundle_root"

  [ -z "$privkey_content" ]
  [ -z "$privkey_files" ]
}

@test "Gate G-COVERAGE: coverageExclusions reasons are restricted to permitted set" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    (.coverageExclusions | length > 0) and
    ([.coverageExclusions[] | select(.reason == "helm-chart-repository" or .reason == "local-never-pulled")] | length) == (.coverageExclusions | length)
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}

@test "Gate G-COVERAGE: utility image and flux controllers are digest-pinned in MANIFEST.json" {
  [ -f "$MANIFEST_JSON" ]
  run jq -e '
    ([.images[] | select(.ref | test("slsi-util"))] | length == 1) and
    ([.images[] | select(.ref | test("slsi-util"))][0].digest | test("^sha256:[0-9a-f]{64}$")) and
    ([.images[] | select(.ref | test("ghcr.io/fluxcd"))] | length >= 4)
  ' "$MANIFEST_JSON"
  [ "$status" -eq 0 ]
}
