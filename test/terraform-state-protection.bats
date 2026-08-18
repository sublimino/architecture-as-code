#!/usr/bin/env bats
#
# Secondary surface. Per CONTRACT §7a, `terraform/bootstrap/tests/state-bucket.tftest.hcl` is the
# primary one: it asserts on the attributes Terraform actually evaluated, which a grep over HCL
# text cannot do. Assertions on `public_access_prevention`, `force_destroy`,
# `uniform_bucket_level_access` and versioning were moved there and deliberately deleted here
# rather than kept in both places — a duplicated check drifts, and the weaker of the two is the
# one that keeps passing.
#
# What remains is what a plan structurally cannot see:
#
#   * Absence across the whole tree. A plan only sees what it evaluated, so it can never prove
#     that `allUsers` or `roles/storage.admin` appears in NO file anywhere.
#   * `lifecycle { prevent_destroy }`. This is a meta-argument, not a resource attribute; it is
#     not addressable in a plan at all. Verified, not assumed — asserting
#     `google_storage_bucket.terraform_state.lifecycle[0].prevent_destroy` in a scratch tftest
#     fails with "Unsupported attribute". bats is the only surface that can check it.
#   * The absence of a `backend` block, which is a property of the source, not of a plan.
#   * Backend prefix strings, which live in `-backend-config=` arguments rather than in HCL.
#   * Roots that do not exist yet, which cannot be planned.
#
# This suite never runs `terraform plan`, never contacts GCP, and therefore cannot prove the
# bucket that actually exists still matches the checked-in code.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  BOOTSTRAP_DIR="${REPO_ROOT}/terraform/bootstrap"
  FIXTURE_DIR="${REPO_ROOT}/test/fixtures/terraform/bootstrap"
}

fixture_drift_message() {
  local fixture="$1"
  local real="$2"

  echo "fixture drifted: ${fixture} no longer faithfully copies ${real}; regenerate with test/fixtures/terraform/bootstrap/GENERATE.sh"
}

assert_fixture_is_faithful_copy() {
  local fixture="$1"
  local real="$2"
  local fixture_lines real_lines changed_lines

  [ -f "$fixture" ] || {
    fixture_drift_message "$fixture" "$real"
    echo "missing fixture file: $fixture"
    return 1
  }
  [ -f "$real" ] || {
    fixture_drift_message "$fixture" "$real"
    echo "missing real file: $real"
    return 1
  }

  if cmp -s "$fixture" "$real"; then
    fixture_drift_message "$fixture" "$real"
    echo "fixture is identical to the real file, so the mutation is gone"
    return 1
  fi

  changed_lines="$(
    diff -u "$real" "$fixture" || true
  )"
  changed_lines="$(
    printf '%s\n' "$changed_lines" | awk '
      /^[+-]/ && $0 !~ /^(---|\+\+\+)/ { count++ }
      END { print count + 0 }
    '
  )"
  if [ "$changed_lines" -gt 8 ]; then
    fixture_drift_message "$fixture" "$real"
    echo "fixture differs by ${changed_lines} changed lines; expected at most 8"
    return 1
  fi

  real_lines="$(wc -l <"$real")"
  fixture_lines="$(wc -l <"$fixture")"
  if [ $((fixture_lines * 100)) -lt $((real_lines * 80)) ]; then
    fixture_drift_message "$fixture" "$real"
    echo "fixture has ${fixture_lines} lines; expected at least 80% of ${real_lines}"
    return 1
  fi
}

guard_directory_contains_tf_files() {
  local dir="$1"
  local -a tf_files

  [ -d "$dir" ] || {
    echo "guard target missing: $dir"
    return 1
  }

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  [ "${#tf_files[@]}" -gt 0 ] || {
    echo "no Terraform files found in: $dir"
    return 1
  }
}

guard_named_block_contains_literal() {
  local file="$1"
  local block_name="$2"
  local literal_pattern="$3"
  local missing_block_reason="$4"
  local missing_literal_reason="$5"

  [ -f "$file" ] || {
    echo "guard target missing: $file"
    return 1
  }

  awk \
    -v block_name="$block_name" \
    -v literal_pattern="$literal_pattern" \
    -v missing_block_reason="$missing_block_reason" \
    -v missing_literal_reason="$missing_literal_reason" '
      function brace_delta(line, tmp, opens, closes) {
        tmp = line
        opens = gsub(/\{/, "{", tmp)
        closes = gsub(/\}/, "}", tmp)
        return opens - closes
      }

      {
        if (!in_block && $0 ~ "^[[:space:]]*" block_name "[[:space:]]*\\{") {
          saw_block = 1
          in_block = 1
          depth = brace_delta($0)
          if ($0 ~ literal_pattern) {
            found_in_block = 1
          }
          if (depth <= 0) {
            if (found_in_block) {
              success = 1
              exit
            }
            in_block = 0
            depth = 0
            found_in_block = 0
          }
          next
        }

        if (in_block) {
          if ($0 ~ literal_pattern) {
            found_in_block = 1
          }
          depth += brace_delta($0)
          if (depth <= 0) {
            if (found_in_block) {
              success = 1
              exit
            }
            in_block = 0
            depth = 0
            found_in_block = 0
          }
        }
      }

      END {
        if (success) {
          exit 0
        }
        if (!saw_block) {
          print missing_block_reason
          exit 1
        }
        print missing_literal_reason
        exit 1
      }
    ' "$file"
}

strip_whole_line_comments() {
  local file="$1"

  [ -f "$file" ] || {
    echo "guard target missing: $file"
    return 1
  }

  awk '!/^[[:space:]]*(#|\/\/)/' "$file"
}

guard_bootstrap_declares_no_backend_block() {
  local dir="$1"
  local -a tf_files
  local file

  guard_directory_contains_tf_files "$dir" || return 1

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  for file in "${tf_files[@]}"; do
    if grep -Eq '^[[:space:]]*backend([[:space:]]+"|[[:space:]]*\{)' "$file"; then
      echo "backend block declared in bootstrap root: $file"
      return 1
    fi
  done
}

guard_state_bucket_prevents_destroy() {
  local file="$1"

  guard_named_block_contains_literal \
    "$file" \
    "lifecycle" \
    '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "lifecycle block missing from state bucket configuration: $file" \
    "prevent_destroy = true missing from lifecycle block: $file"
}

guard_bootstrap_has_no_public_principals() {
  local dir="$1"
  local -a tf_files

  guard_directory_contains_tf_files "$dir" || return 1

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  # Match the QUOTED literal rather than the bare word, and search every line rather than only
  # `members = ...` lines.
  #
  # Both choices are load-bearing. Restricting the search to `members =` lines misses the
  # multi-line list form that terraform fmt produces for any list with more than one entry:
  #
  #   members = [
  #     "allUsers",
  #   ]
  #
  # Requiring the surrounding quotes is what keeps the broadened search precise: variables.tf
  # legitimately names both principals inside a validation regex and its error_message, in order
  # to REJECT them, and neither spelling puts a quote immediately against the principal name.
  for file in "${tf_files[@]}"; do
    if strip_whole_line_comments "$file" | grep -Fq -e '"allUsers"' -e '"allAuthenticatedUsers"'; then
      echo "public principal found in bootstrap Terraform root: $file"
      return 1
    fi
  done
}

guard_bootstrap_grants_object_admin_but_not_storage_admin() {
  local dir="$1"
  local -a tf_files
  local file
  local saw_object_admin=0

  guard_directory_contains_tf_files "$dir" || return 1

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  for file in "${tf_files[@]}"; do
    # Whole-line comment stripping is enough here because every comment in these
    # files is a whole-line comment, so prose about roles/storage.admin must not
    # be mistaken for a real grant.
    if strip_whole_line_comments "$file" | grep -Fq 'roles/storage.admin'; then
      echo "bucket-admin grant found in bootstrap Terraform root: $file"
      return 1
    fi
    if strip_whole_line_comments "$file" | grep -Fq 'roles/storage.objectAdmin'; then
      saw_object_admin=1
    fi
  done

  [ "$saw_object_admin" -eq 1 ] || {
    echo "roles/storage.objectAdmin grant missing from bootstrap Terraform root: $dir"
    return 1
  }
}

guard_bootstrap_uses_authoritative_bucket_iam_binding() {
  local dir="$1"
  local -a tf_files
  local saw_binding=0
  local saw_member=0

  guard_directory_contains_tf_files "$dir" || return 1

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  if grep -Eq '^[[:space:]]*resource[[:space:]]+"google_storage_bucket_iam_binding"[[:space:]]+"' "${tf_files[@]}"; then
    saw_binding=1
  fi

  if grep -Eq '^[[:space:]]*resource[[:space:]]+"google_storage_bucket_iam_member"[[:space:]]+"' "${tf_files[@]}"; then
    saw_member=1
  fi

  [ "$saw_binding" -eq 1 ] || {
    if [ "$saw_member" -eq 1 ]; then
      echo "bootstrap Terraform root uses only google_storage_bucket_iam_member; expected authoritative binding: $dir"
      return 1
    fi
    echo "google_storage_bucket_iam_binding resource missing from bootstrap Terraform root: $dir"
    return 1
  }
}

guard_directory_declares_no_storage_bucket_resources() {
  local dir="$1"
  local -a tf_files

  guard_directory_contains_tf_files "$dir" || return 1

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  if grep -Eq '^[[:space:]]*resource[[:space:]]+"google_storage_bucket"[[:space:]]+"' "${tf_files[@]}"; then
    echo "google_storage_bucket resource found in consuming root: $dir"
    return 1
  fi
}

guard_platform_backend_prefix_is_exact() {
  local dir="$1"
  local repo_root makefile
  local -a tf_files

  guard_directory_contains_tf_files "$dir" || return 1

  repo_root="$(cd "$dir/../.." && pwd)"
  makefile="${repo_root}/Makefile"
  [ -f "$makefile" ] || {
    echo "guard target missing: $makefile"
    return 1
  }

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  grep -Eq 'osramp/platform(["'"'"'"'"'"'"'"'"'[:space:]]|$)' "$makefile" "${tf_files[@]}" || {
    echo "exact backend prefix osramp/platform not found in ${dir} or ${makefile}"
    return 1
  }
}

guard_environments_backend_prefix_template_is_present() {
  local dir="$1"
  local repo_root makefile
  local -a tf_files

  guard_directory_contains_tf_files "$dir" || return 1

  repo_root="$(cd "$dir/../.." && pwd)"
  makefile="${repo_root}/Makefile"
  [ -f "$makefile" ] || {
    echo "guard target missing: $makefile"
    return 1
  }

  shopt -s nullglob
  tf_files=("$dir"/*.tf)
  shopt -u nullglob

  grep -Fq 'osramp/environments/' "$makefile" "${tf_files[@]}" || {
    echo "backend prefix template osramp/environments/ not found in ${dir} or ${makefile}"
    return 1
  }
}

@test "fixture broken-prevent-destroy stays a faithful mutation" {
  assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-prevent-destroy/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf"
}

@test "fixture broken-public-principal stays a faithful mutation" {
  assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-public-principal/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf"
}

@test "fixture broken-public-principal-multiline stays a faithful mutation" {
  assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-public-principal-multiline/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf"
}

@test "fixture broken-storage-admin stays a faithful mutation" {
  assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-storage-admin/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf"
}

@test "fixture broken-backend-block stays a faithful mutation" {
  assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-backend-block/versions.tf" \
    "${BOOTSTRAP_DIR}/versions.tf"
}

@test "bootstrap root declares no backend block" {
  run guard_bootstrap_declares_no_backend_block "$BOOTSTRAP_DIR"
  [ "$status" -eq 0 ]
}

@test "MUTATION: backend-block guard fails on a broken copy" {
  local broken_root="${BATS_TEST_TMPDIR}/bootstrap"

  mkdir -p "$broken_root"
  cp "${FIXTURE_DIR}/broken-backend-block/versions.tf" "${broken_root}/versions.tf"

  run guard_bootstrap_declares_no_backend_block "$broken_root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backend block declared"* ]]
}

@test "state bucket declares prevent_destroy in lifecycle" {
  run guard_state_bucket_prevents_destroy "${BOOTSTRAP_DIR}/main.tf"
  [ "$status" -eq 0 ]
}

@test "MUTATION: prevent_destroy guard fails on a broken copy" {
  run guard_state_bucket_prevents_destroy "${FIXTURE_DIR}/broken-prevent-destroy/main.tf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prevent_destroy = true missing"* ]]
}

@test "bootstrap root declares no public principals" {
  run guard_bootstrap_has_no_public_principals "$BOOTSTRAP_DIR"
  [ "$status" -eq 0 ]
}

@test "MUTATION: public-principal guard fails on a broken copy" {
  run guard_bootstrap_has_no_public_principals "${FIXTURE_DIR}/broken-public-principal"
  [ "$status" -ne 0 ]
  [[ "$output" == *"public principal found"* ]]
}

# The single-line and multi-line list forms are separate fixtures on purpose. An earlier draft of
# this guard matched only `members = ...` lines and passed the multi-line copy, which is the form
# terraform fmt actually produces once a list has more than one entry.
@test "MUTATION: public-principal guard fails on a multi-line members list" {
  run guard_bootstrap_has_no_public_principals "${FIXTURE_DIR}/broken-public-principal-multiline"
  [ "$status" -ne 0 ]
  [[ "$output" == *"public principal found"* ]]
}

@test "bootstrap root grants object admin but not storage admin" {
  run guard_bootstrap_grants_object_admin_but_not_storage_admin "$BOOTSTRAP_DIR"
  [ "$status" -eq 0 ]
}

@test "MUTATION: storage-admin guard fails on a broken copy" {
  run guard_bootstrap_grants_object_admin_but_not_storage_admin "${FIXTURE_DIR}/broken-storage-admin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bucket-admin grant found"* ]]
}

@test "bootstrap root uses authoritative bucket IAM binding" {
  run guard_bootstrap_uses_authoritative_bucket_iam_binding "$BOOTSTRAP_DIR"
  [ "$status" -eq 0 ]
}

@test "platform root declares no storage bucket resources" {
  local dir="${REPO_ROOT}/terraform/platform"

  [ -d "$dir" ] || skip "terraform/platform not present yet (built by F6)"

  run guard_directory_declares_no_storage_bucket_resources "$dir"
  [ "$status" -eq 0 ]
}

@test "environments root declares no storage bucket resources" {
  local dir="${REPO_ROOT}/terraform/environments"

  [ -d "$dir" ] || skip "terraform/environments not present yet (built by F2)"

  run guard_directory_declares_no_storage_bucket_resources "$dir"
  [ "$status" -eq 0 ]
}

@test "platform backend prefix is exactly osramp/platform" {
  local dir="${REPO_ROOT}/terraform/platform"

  [ -d "$dir" ] || skip "terraform/platform not present yet (built by F6)"

  run guard_platform_backend_prefix_is_exact "$dir"
  [ "$status" -eq 0 ]
}

@test "environments backend prefix template contains osramp/environments/" {
  local dir="${REPO_ROOT}/terraform/environments"

  [ -d "$dir" ] || skip "terraform/environments not present yet (built by F2)"

  run guard_environments_backend_prefix_template_is_present "$dir"
  [ "$status" -eq 0 ]
}
