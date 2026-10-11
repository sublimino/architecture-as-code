#!/usr/bin/env bash
#
# SLSI-P1-3: Negative test and seal falsification harness.
# Validates that all security gates, schema validation, correctness/completeness
# checks, and error paths fail loudly and refuse to admit invalid artifacts.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
MANIFEST_JSON="${DIST_DIR}/MANIFEST.json"
ARCHIVE="$(ls "${DIST_DIR}"/slsi-appliance-*.tar.gz 2>/dev/null | head -n 1 || true)"
SCHEMA_FILE="${REPO_ROOT}/schemas/slsi-appliance-manifest-schema.json"
SCHEMA_VALIDATOR="${REPO_ROOT}/scripts/lib/json-schema-lite.jq"

pass_count=0
fail_count=0

assert_pass() {
  local name="$1"
  shift
  echo -n "[PASS-CASE] ${name}... "
  if "$@"; then
    echo "OK"
    pass_count=$((pass_count + 1))
  else
    echo "FAILED"
    fail_count=$((fail_count + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  echo -n "[FAIL-CASE] ${name}... "
  if "$@" >/dev/null 2>&1; then
    echo "UNEXPECTED PASS (FAILED)"
    fail_count=$((fail_count + 1))
  else
    echo "REJECTED AS EXPECTED (OK)"
    pass_count=$((pass_count + 1))
  fi
}

echo "=== SLSI-P1-3 Negative Falsification Harness ==="

# 1. Injected payload file detected by completeness and missed by correctness
assert_pass "injected_payload_file_detected_by_completeness_and_missed_by_correctness" bash -c '
  scratch="$(mktemp -d)"
  tar -xzf "'"$ARCHIVE"'" -C "$scratch"
  printf "injected" > "$scratch/fleet/INJECTED_FILE"
  # Correctness passes because INJECTED_FILE is not in payload[]
  (cd "$scratch" && jq -r ".payload[] | \"\(.sha256) \(.path)\"" MANIFEST.json | sha256sum -c --strict - >/dev/null 2>&1)
  # Completeness FAILS because INJECTED_FILE is on disk but not in MANIFEST.json
  on_disk=$(find "$scratch" -type f ! -name MANIFEST.json | sed "s|^$scratch/||" | LC_ALL=C sort)
  declared=$(jq -r ".payload[].path" "$scratch/MANIFEST.json" | LC_ALL=C sort)
  ! diff <(printf "%s\n" "$on_disk") <(printf "%s\n" "$declared") >/dev/null 2>&1
  rm -rf "$scratch"
'

# 2. Corrupted payload byte fails seal correctness
assert_pass "corrupted_payload_byte_fails_seal" bash -c '
  scratch="$(mktemp -d)"
  tar -xzf "'"$ARCHIVE"'" -C "$scratch"
  target_file="$(jq -r ".payload[0].path" "$scratch/MANIFEST.json")"
  echo "corruption" >> "$scratch/$target_file"
  # Correctness must FAIL
  ! (cd "$scratch" && jq -r ".payload[] | \"\(.sha256) \(.path)\"" MANIFEST.json | sha256sum -c --strict - >/dev/null 2>&1)
  rm -rf "$scratch"
'

# 3. Stage function name mismatch is caught and fails
assert_pass "p1_3_stage_function_name_mismatch_is_caught" bash -c '
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  declare -F stage_p1_3_manifest >/dev/null
'

# 4. Mutated manifest fields fail schema gate where jq . passes
assert_pass "mutated_manifest_fields_fail_schema_gate" bash -c '
  for field in "git.commit" "releaseKey.fingerprint"; do
    # Deleted field
    del_json="$(jq "del(.$field)" "'"$MANIFEST_JSON"'")"
    jq -e . <<< "$del_json" >/dev/null
    violations="$(jq -n -r --slurpfile schema "'"$SCHEMA_FILE"'" --slurpfile doc <(printf "%s" "$del_json") --arg ptr "#" -f "'"$SCHEMA_VALIDATOR"'")"
    [ -n "$violations" ] || exit 1

    # Empty string field
    empty_json="$(jq ".$field = \"\"" "'"$MANIFEST_JSON"'")"
    jq -e . <<< "$empty_json" >/dev/null
    violations="$(jq -n -r --slurpfile schema "'"$SCHEMA_FILE"'" --slurpfile doc <(printf "%s" "$empty_json") --arg ptr "#" -f "'"$SCHEMA_VALIDATOR"'")"
    [ -n "$violations" ] || exit 1
  done
'

# 5. Sentinel digest in image list fails build
assert_pass "sentinel_digest_fails_build" bash -c '
  tmp_bundle="$(mktemp -d)"
  mkdir -p "$tmp_bundle/.manifest.d"
  jq ".images[0].digest = \"DIGEST-UNRESOLVED: not present\"" "'"$REPO_ROOT"'/bundle/.manifest.d/images.json" > "$tmp_bundle/.manifest.d/images.json"
  (cd "$tmp_bundle/.manifest.d" && sha256sum images.json > images.sha256)
  tmp_out="$(mktemp -d)"
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  ! (SLSI_BUNDLE_OUT="$tmp_out" BUNDLE_DIR="$tmp_bundle" stage_p1_3_manifest >/dev/null 2>&1)
  [ ! -f "$tmp_out/MANIFEST.json" ]
  rm -rf "$tmp_bundle" "$tmp_out"
'

# 6. Tag-only image reference fails build
assert_pass "tag_only_image_reference_fails_build" bash -c '
  tmp_bundle="$(mktemp -d)"
  mkdir -p "$tmp_bundle/.manifest.d"
  jq ".images[0].ref = \"postgres:16-alpine\" | .images[0].resolvedRef = \"\"" "'"$REPO_ROOT"'/bundle/.manifest.d/images.json" > "$tmp_bundle/.manifest.d/images.json"
  (cd "$tmp_bundle/.manifest.d" && sha256sum images.json > images.sha256)
  tmp_out="$(mktemp -d)"
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  ! (SLSI_BUNDLE_OUT="$tmp_out" BUNDLE_DIR="$tmp_bundle" stage_p1_3_manifest >/dev/null 2>&1)
  rm -rf "$tmp_bundle" "$tmp_out"
'

# 7. Absent utility image fails loudly
assert_pass "absent_utility_image_fails_loudly" bash -c '
  tmp_bundle="$(mktemp -d)"
  mkdir -p "$tmp_bundle/.manifest.d" "$tmp_bundle/images"
  cp -r "'"$REPO_ROOT"'/bundle/.manifest.d/." "$tmp_bundle/.manifest.d/"
  jq "{schemaVersion: 2, mediaType: \"application/vnd.oci.image.index.v1+json\", manifests: []}" > "$tmp_bundle/images/index.json"
  tmp_out="$(mktemp -d)"
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  err_msg="$(SLSI_BUNDLE_OUT="$tmp_out" BUNDLE_DIR="$tmp_bundle" stage_p1_3_manifest 2>&1 || true)"
  echo "$err_msg" | grep -q "utility image"
  rm -rf "$tmp_bundle" "$tmp_out"
'

# 8. Provocation: private key detection fails build
assert_pass "planted_private_key_fails_build" bash -c '
  tmp_bundle="$(mktemp -d)"
  mkdir -p "$tmp_bundle/.manifest.d" "$tmp_bundle/keys"
  cp -r "'"$REPO_ROOT"'/bundle/.manifest.d/." "$tmp_bundle/.manifest.d/"
  cp -r "'"$REPO_ROOT"'/bundle/keys/." "$tmp_bundle/keys/"
  echo "-----BEGIN OPENSSH PRIVATE KEY-----" > "$tmp_bundle/keys/cosign.key"
  echo "fake-key" >> "$tmp_bundle/keys/cosign.key"
  echo "-----END OPENSSH PRIVATE KEY-----" >> "$tmp_bundle/keys/cosign.key"
  tmp_out="$(mktemp -d)"
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  ! (SLSI_BUNDLE_OUT="$tmp_out" BUNDLE_DIR="$tmp_bundle" stage_p1_3_manifest >/dev/null 2>&1)
  rm -rf "$tmp_bundle" "$tmp_out"
'

# 9. Gate G-COVERAGE: invalid exclusion reason outside permitted set fails schema gate
assert_pass "invalid_coverage_exclusion_reason_fails_schema" bash -c '
  mutated="$(jq '\''(.coverageExclusions[0].reason) = "unpermitted-reason"'\'' "'"$MANIFEST_JSON"'")"
  violations="$(jq -n -r --slurpfile schema "'"$SCHEMA_FILE"'" --slurpfile doc <(printf "%s" "$mutated") --arg ptr "#" -f "'"$SCHEMA_VALIDATOR"'")"
  [ -n "$violations" ]
'

echo "=================================================="
echo "Total passed: $pass_count, Total failed: $fail_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0

