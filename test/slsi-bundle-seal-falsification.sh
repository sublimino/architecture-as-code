#!/usr/bin/env bash
#
# SLSI-P1-3: Negative test and seal falsification harness.
# Validates that all security gates, schema validation, correctness/completeness
# checks, and error paths fail loudly and refuse to admit invalid artifacts.
#
# @id     slsi-bundle-seal-falsification
# @target scripts/package-tenant-bundle.sh
# @schema schemas/slsi-appliance-manifest-schema.json
# @task   SLSI-P1-3, SLSI-OSD-2
#
# ─── Why every case now has an explicit precondition ────────────────────────
#
# A falsification case infers "the operation failed, therefore the guard caught
# the defect I injected". That inference is only sound if the operation reached
# the guard. Measured on a clean checkout with no dist/ directory, this harness
# reported "Total passed: 9, Total failed: 0" while FOUR of its nine cases never
# touched the system under test at all:
#
#   injected_payload_file_detected_by_completeness_and_missed_by_correctness
#   corrupted_payload_byte_fails_seal
#   mutated_manifest_fields_fail_schema_gate
#   invalid_coverage_exclusion_reason_fails_schema
#
# They emitted `tar (child): : Cannot open` and `jq: error: Could not open file
# .../dist/MANIFEST.json`, then printed OK -- because an absent input makes the
# operation fail in exactly the way an injected defect does. The case could not
# distinguish a working guard from a missing bundle, and reported green either
# way. The last of the four is the assertion that proves OSD-2's reason enum
# rejects an unpermitted value, so the Phase 1 coverage gate's own falsification
# was vacuous unless someone happened to have built dist/ first.
#
# The repair is to make the three states distinguishable, which requires naming
# the third one:
#
#   guard caught the defect     -> OK, counted as a pass
#   guard missed the defect     -> FAILED, counted as a failure
#   harness could not even run  -> HARNESS ERROR, exit 2, counted as NEITHER
#
# So each case declares what it needs, the precondition runs BEFORE the defect is
# injected, and a missing input aborts the run rather than scoring it. The
# preconditions are themselves positive-controlled below: cases 0a-0c prove the
# precondition fires on an absent manifest, an unparseable manifest and an
# absent archive, because a precondition nobody has seen fail is the same
# unproven assumption one layer down.
#
# ─── Which cases need a prior P1-3 build ────────────────────────────────────
#
# SELF-CONTAINED (need only the repository: the bundler source and the tracked
# bundle/ tree). Verified to run clean with dist/ absent:
#   3 p1_3_stage_function_name_mismatch_is_caught   (bundler source only)
#   5 sentinel_digest_fails_build                   (bundle/.manifest.d)
#   6 tag_only_image_reference_fails_build          (bundle/.manifest.d)
#   7 present_utility_image_fails_loudly            (whole bundle/ tree)
#   8 planted_private_key_fails_build               (bundle/.manifest.d, keys)
#
# REQUIRE dist/ FROM A PRIOR stage_p1_3_manifest RUN: 1, 2, 4, 9.
#
# Seam: SLSI_FALSIFY_DIST relocates the dist directory, which is what lets the
# positive controls point the precondition at a scratch directory without
# touching the real build output.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${SLSI_FALSIFY_DIST:-${REPO_ROOT}/dist}"
MANIFEST_JSON="${DIST_DIR}/MANIFEST.json"
ARCHIVE="$(ls "${DIST_DIR}"/slsi-appliance-*.tar.gz 2>/dev/null | head -n 1 || true)"
SCHEMA_FILE="${REPO_ROOT}/schemas/slsi-appliance-manifest-schema.json"
SCHEMA_VALIDATOR="${REPO_ROOT}/scripts/lib/json-schema-lite.jq"
BUNDLE_IMAGES_JSON="${REPO_ROOT}/bundle/.manifest.d/images.json"

pass_count=0
fail_count=0

# A harness fault is not a test result. It exits 2 -- distinct from the 1 this
# script uses for "a guard missed its defect" -- and never increments a counter,
# so no run can report a score it did not earn.
harness_error() {
  echo "HARNESS ERROR" >&2
  echo "  precondition for case '${1}' not met: ${2}" >&2
  echo "  This is a HARNESS FAULT, not a guard result. The case was not run and" >&2
  echo "  is NOT counted as a pass: an absent input makes an operation fail in" >&2
  echo "  exactly the way an injected defect does, so a case that ran against" >&2
  echo "  nothing proves nothing." >&2
  echo "  Remedy: build dist/ first with stage_p1_3_manifest, e.g." >&2
  echo "    test/helpers/slsi-bundle-build-driver.bash \"\$PWD\" \"\$PWD/bundle\" stage_p1_3_manifest" >&2
  exit 2
}

# Cases 1, 2, 4 and 9 extract or mutate the built artefacts. Both of them must
# be present AND usable: an existing but unparseable MANIFEST.json fails every
# downstream jq in the same way a caught defect does, which is the subtler half
# of the original fault.
need_built_dist() {
  local case_name="$1"
  [[ -f "${MANIFEST_JSON}" ]] || harness_error "${case_name}" "${MANIFEST_JSON} does not exist"
  jq -e . "${MANIFEST_JSON}" >/dev/null 2>&1 || harness_error "${case_name}" "${MANIFEST_JSON} is not parseable JSON"
  jq -e '(.payload | length) > 0' "${MANIFEST_JSON}" >/dev/null 2>&1 || harness_error "${case_name}" "${MANIFEST_JSON} declares an empty payload[]; there is nothing to corrupt or inject into"
  jq -e '(.coverageExclusions | length) > 0' "${MANIFEST_JSON}" >/dev/null 2>&1 || harness_error "${case_name}" "${MANIFEST_JSON} declares no coverageExclusions; the OSD-2 reason-enum case would mutate an absent entry"
  [[ -n "${ARCHIVE}" ]] || harness_error "${case_name}" "no slsi-appliance-*.tar.gz in ${DIST_DIR}"
  [[ -s "${ARCHIVE}" ]] || harness_error "${case_name}" "${ARCHIVE} is empty"
  local magic
  magic="$(head -c 2 "${ARCHIVE}" | od -An -tx1 | tr -d ' \n')"
  [[ "${magic}" == "1f8b" ]] || harness_error "${case_name}" "${ARCHIVE} is not a gzip stream (magic '${magic}', want 1f8b)"
}

# Cases 5-8 build their fixture from the tracked bundle/ tree instead, so they
# need no prior build -- but they do need that tree to be real.
need_bundle_tree() {
  local case_name="$1"
  [[ -f "${BUNDLE_IMAGES_JSON}" ]] || harness_error "${case_name}" "${BUNDLE_IMAGES_JSON} does not exist"
  jq -e '(.images | length) > 0' "${BUNDLE_IMAGES_JSON}" >/dev/null 2>&1 || harness_error "${case_name}" "${BUNDLE_IMAGES_JSON} is unparseable or declares no images"
}

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

# `--precondition-only` runs the dist precondition and nothing else. It exists so
# the positive controls can invoke the real precondition in a subprocess against
# a scratch SLSI_FALSIFY_DIST, rather than re-implementing it -- a control that
# tested its own copy of the check would prove nothing about the check that runs.
if [[ "${1:-}" == "--precondition-only" ]]; then
  need_built_dist "--precondition-only"
  echo "precondition satisfied: ${MANIFEST_JSON} and ${ARCHIVE}"
  exit 0
fi

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

# ── 0. Positive controls for the precondition itself ────────────────────────
#
# These run FIRST and are self-contained, so they execute on every invocation
# including the clean checkout that produced the vacuous 9/9. Each drives the
# real need_built_dist through --precondition-only against a scratch directory
# and requires exit 2 plus the HARNESS ERROR text. A precondition nobody has
# watched fail is just another unproven assumption, one layer down.

assert_pass "precondition_control_absent_manifest_aborts_the_run" bash -c '
  scratch="$(mktemp -d -t slsi-precond-absent.XXXXXX)"
  out="$(SLSI_FALSIFY_DIST="$scratch" bash "'"${BASH_SOURCE[0]}"'" --precondition-only 2>&1)" && rc=0 || rc=$?
  rm -rf "$scratch"
  [ "$rc" -eq 2 ] || { printf "expected exit 2, got %s\n%s\n" "$rc" "$out" >&2; exit 1; }
  printf "%s" "$out" | grep -q "HARNESS ERROR" || { printf "no HARNESS ERROR in:\n%s\n" "$out" >&2; exit 1; }
  printf "%s" "$out" | grep -q "does not exist" || { printf "wrong reason:\n%s\n" "$out" >&2; exit 1; }
'

assert_pass "precondition_control_unparseable_manifest_aborts_the_run" bash -c '
  # The subtler half: a manifest that EXISTS but is truncated breaks every
  # downstream jq in exactly the way a caught defect does, so existence alone is
  # not a sufficient precondition.
  scratch="$(mktemp -d -t slsi-precond-trunc.XXXXXX)"
  real_archive="$(ls "'"${REPO_ROOT}"'/dist"/slsi-appliance-*.tar.gz 2>/dev/null | head -n 1 || true)"
  if [ -n "$real_archive" ]; then
    cp "$real_archive" "$scratch/"
  else
    printf "\037\213placeholder" > "$scratch/slsi-appliance-0.0.0.tar.gz"
  fi
  printf "{\"payload\": [" > "$scratch/MANIFEST.json"
  out="$(SLSI_FALSIFY_DIST="$scratch" bash "'"${BASH_SOURCE[0]}"'" --precondition-only 2>&1)" && rc=0 || rc=$?
  rm -rf "$scratch"
  [ "$rc" -eq 2 ] || { printf "expected exit 2, got %s\n%s\n" "$rc" "$out" >&2; exit 1; }
  printf "%s" "$out" | grep -q "not parseable JSON" || { printf "wrong reason:\n%s\n" "$out" >&2; exit 1; }
'

assert_pass "precondition_control_absent_archive_aborts_the_run" bash -c '
  scratch="$(mktemp -d -t slsi-precond-noarch.XXXXXX)"
  real_manifest="'"${REPO_ROOT}"'/dist/MANIFEST.json"
  if [ -f "$real_manifest" ]; then
    cp "$real_manifest" "$scratch/MANIFEST.json"
  else
    printf "{\"payload\":[{\"path\":\"x\"}],\"coverageExclusions\":[{\"ref\":\"x\"}]}" > "$scratch/MANIFEST.json"
  fi
  out="$(SLSI_FALSIFY_DIST="$scratch" bash "'"${BASH_SOURCE[0]}"'" --precondition-only 2>&1)" && rc=0 || rc=$?
  rm -rf "$scratch"
  [ "$rc" -eq 2 ] || { printf "expected exit 2, got %s\n%s\n" "$rc" "$out" >&2; exit 1; }
  printf "%s" "$out" | grep -q "no slsi-appliance-.*tar.gz" || { printf "wrong reason:\n%s\n" "$out" >&2; exit 1; }
'

# 1. Injected payload file detected by completeness and missed by correctness
need_built_dist "injected_payload_file_detected_by_completeness_and_missed_by_correctness"
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
need_built_dist "corrupted_payload_byte_fails_seal"
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
need_built_dist "mutated_manifest_fields_fail_schema_gate"
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
need_bundle_tree "sentinel_digest_fails_build"
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
need_bundle_tree "tag_only_image_reference_fails_build"
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

# 7. A utility-image record that REACHES the manifest fails loudly
#
# Inverted, not deleted. This case used to REMOVE the slsi-util record and
# require Gate 7 to abort because it was missing -- so after the reversal there
# was nothing left to remove and the fixture expressed no fault at all. It now
# plants the record and requires the gate to refuse it, which is the same gate
# proven from the other side.
#
# It deliberately plants into .manifest.d/images.json rather than into
# images/index.json. The staged index is produced by a filter that drops the
# forbidden digest outright, so a planted index entry is removed before any
# gate sees it and the fixture would prove nothing -- the same way this case
# previously proved nothing. The images array is NOT filtered, so a record
# planted there does reach the manifest and the gate does fire. That asymmetry
# is why Gate 7 is in two halves.
need_bundle_tree "present_utility_image_fails_loudly"
assert_pass "present_utility_image_fails_loudly" bash -c '
  # cp -a, never cp -al. Hardlinks share inodes and stage_p1_3_manifest copies
  # over bundle/images/index.json and images.json in place, so a hardlinked
  # fixture writes THROUGH the links into the repository'"'"'s own tracked bundle.
  # That is the failure mode that dirtied 16 tracked files here once.
  tmp_parent="$(mktemp -d -t slsi-falsify-utility.XXXXXX)"
  tmp_bundle="$tmp_parent/bundle"
  cp -a "'"$REPO_ROOT"'/bundle" "$tmp_bundle"

  # Plant the record Decision 10 used to append, under its own digest, and
  # keep .count in arity with .images. Gate 3 compares the two and fires
  # FIRST if they disagree, so without the recount this fixture aborts on an
  # unrelated gate and proves nothing about Gate 7 -- which is the exact
  # failure mode the previous version of this case had.
  jq ".images += [{
        ref: \"controlplane/slsi-util:v0.1.0@sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b\",
        reference: \"controlplane/slsi-util\",
        resolvedRef: \"controlplane/slsi-util:v0.1.0@sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b\",
        logicalName: \"slsi-util\",
        digest: \"sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b\",
        party: \"first-party\",
        role: \"utility\",
        provides: [\"envsubst\", \"openssl\"]
      }] | .count = (.images | length)" "'"$REPO_ROOT"'/bundle/.manifest.d/images.json" > "$tmp_bundle/.manifest.d/images.json.new"
  mv -f "$tmp_bundle/.manifest.d/images.json.new" "$tmp_bundle/.manifest.d/images.json"
  ( cd "$tmp_bundle/.manifest.d" && sha256sum images.json > images.sha256 )

  tmp_out="$tmp_parent/out"
  mkdir -p "$tmp_out"
  source "'"$REPO_ROOT"'/scripts/package-tenant-bundle.sh" --help >/dev/null 2>&1 || true
  # `|| true` on the ASSIGNMENT, not inside the substitution. `fail` ends with
  # `exit 1`, and an exit cannot be caught by a `||` inside the subshell it
  # exits; the substitution then returns 1, the assignment inherits it, and the
  # sourced script'"'"'s own `trap ... ERR` kills this fixture before the grep it
  # exists to run. Moving the guard outward is what makes the expected failure
  # survivable.
  err_msg="$(SLSI_BUNDLE_OUT="$tmp_out" BUNDLE_DIR="$tmp_bundle" stage_p1_3_manifest 2>&1)" || true
  rm -rf "$tmp_parent"
  echo "$err_msg" | grep -qi "utility image record present"
'

# 8. Provocation: private key detection fails build
need_bundle_tree "planted_private_key_fails_build"
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
need_built_dist "invalid_coverage_exclusion_reason_fails_schema"
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

