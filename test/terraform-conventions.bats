#!/usr/bin/env bats
#
# Static repository conventions only. This suite never runs `terraform init`, never loads a
# provider schema, and never contacts GCP, so it cannot prove a configuration would apply.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TERRAFORM_DIR="${REPO_ROOT}/terraform"
  BOOTSTRAP_DIR="${TERRAFORM_DIR}/bootstrap"
  FIXTURE_DIR="${REPO_ROOT}/test/fixtures/terraform/bootstrap"
}

assert_fixture_is_faithful_copy() {
  local fixture="$1" real="$2" max_changed="${3:-8}"
  local changed_lines real_lines fixture_lines

  [ -f "$fixture" ] || { echo "missing fixture file: $fixture"; return 1; }
  [ -f "$real" ] || { echo "missing real file: $real"; return 1; }

  if cmp -s "$fixture" "$real"; then
    echo "fixture ${fixture} is identical to ${real}, so the mutation is gone; regenerate with test/fixtures/terraform/bootstrap/GENERATE.sh"
    return 1
  fi

  changed_lines="$(diff -u "$real" "$fixture" | awk '/^[+-]/ && $0 !~ /^(---|\+\+\+)/ { n++ } END { print n + 0 }')"
  if [ "$changed_lines" -gt "$max_changed" ]; then
    echo "fixture ${fixture} differs by ${changed_lines} changed lines, expected at most ${max_changed}; regenerate with test/fixtures/terraform/bootstrap/GENERATE.sh"
    return 1
  fi

  real_lines="$(wc -l <"$real")"
  fixture_lines="$(wc -l <"$fixture")"
  if [ $((fixture_lines * 100)) -lt $((real_lines * 80)) ]; then
    echo "fixture ${fixture} has ${fixture_lines} lines, expected at least 80% of ${real_lines}; regenerate with test/fixtures/terraform/bootstrap/GENERATE.sh"
    return 1
  fi
}

guard_directory_has_tf_files() {
  local target="$1"
  local first_tf

  [ -d "$target" ] || { echo "directory missing: $target"; return 1; }

  first_tf="$(rg --files "$target" -g '*.tf' | head -1)"
  [ -n "$first_tf" ] || { echo "no .tf files found under $target"; return 1; }
}

guard_terraform_layout() {
  local target="$1"
  local target_rel tracked_entry

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  target_rel="$target"
  case "$target_rel" in
    "$REPO_ROOT"/*) target_rel="${target_rel#"$REPO_ROOT"/}" ;;
  esac

  tracked_entry="$(cd "$REPO_ROOT" && git ls-files -- "$target_rel" | head -1)"
  [ -n "$tracked_entry" ] || { echo "terraform/ is not tracked by git"; return 1; }

  [ -f "$target/README.md" ] || { echo "missing README: $target/README.md"; return 1; }
  [ -d "$target/bootstrap" ] || { echo "missing bootstrap directory: $target/bootstrap"; return 1; }

  guard_directory_has_tf_files "$target/bootstrap" || return 1
}

guard_modules_layout() {
  local target="$1"
  local module_count

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  module_count="$(find "$target" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
  [ "$module_count" -ge 6 ] || { echo "expected at least six module directories under $target"; return 1; }
}

guard_terraform_fmt_check() {
  local target="$1"
  local fmt_output fmt_status

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  fmt_output="$(terraform fmt -recursive -check "$target" 2>&1)"
  fmt_status="$?"
  if [ "$fmt_status" -ne 0 ]; then
    echo "terraform fmt -recursive -check failed for $target"
    echo "$fmt_output"
    return 1
  fi
}

extract_provider_version() {
  local versions_file="$1"
  local provider="$2"

  awk -v provider="$provider" '
    BEGIN {
      in_block = 0
      depth = 0
    }

    $0 ~ "^[[:space:]]*" provider "[[:space:]]*=[[:space:]]*\\{" {
      in_block = 1
      depth = 1
      next
    }

    in_block {
      if ($0 ~ /^[[:space:]]*version[[:space:]]*=/) {
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*$/, "", line)
        print line
        exit
      }

      depth += gsub(/\{/, "{")
      depth -= gsub(/\}/, "}")
      if (depth <= 0) {
        in_block = 0
      }
    }
  ' "$versions_file"
}

guard_version_pins() {
  local target="$1"
  local required_version google_version google_beta_version

  [ -f "$target" ] || { echo "guard target missing: $target"; return 1; }

  required_version="$(awk -F'"' '/required_version[[:space:]]*=/ { print $2; exit }' "$target")"
  [ "$required_version" = ">= 1.9" ] || {
    echo "$target: required_version must be >= 1.9"
    return 1
  }

  google_version="$(extract_provider_version "$target" "google")"
  [ -n "$google_version" ] || {
    echo "$target: missing hashicorp/google version pin"
    return 1
  }

  google_beta_version="$(extract_provider_version "$target" "google-beta")"
  [ -n "$google_beta_version" ] || {
    echo "$target: missing hashicorp/google-beta version pin"
    return 1
  }

  [ "$google_version" = "~> 6.8" ] || {
    echo "$target: hashicorp/google must be pinned to ~> 6.8"
    return 1
  }

  [ "$google_beta_version" = "~> 6.8" ] || {
    echo "$target: hashicorp/google-beta must be pinned to ~> 6.8"
    return 1
  }

  [ "$google_version" = "$google_beta_version" ] || {
    echo "$target: google and google-beta provider pins must match"
    return 1
  }
}

guard_variable_metadata() {
  local target="$1"
  local file
  local -a files

  [ -e "$target" ] || { echo "guard target missing: $target"; return 1; }

  if [ -d "$target" ]; then
    mapfile -t files < <(rg --files "$target" -g '*.tf' | LC_ALL=C sort)
  else
    files=("$target")
  fi

  [ "${#files[@]}" -gt 0 ] || { echo "no .tf files found under $target"; return 1; }

  for file in "${files[@]}"; do
    awk '
      function brace_delta(line,    i, c, prev, in_string, delta) {
        in_string = 0
        prev = ""
        delta = 0
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "\"" && prev != "\\") {
            in_string = !in_string
          } else if (!in_string) {
            if (c == "{") {
              delta++
            } else if (c == "}") {
              delta--
            }
          }
          prev = c
        }
        return delta
      }

      function description_nonempty(line,    i, c, prev, value) {
        if (line !~ /^[[:space:]]*description[[:space:]]*=[[:space:]]*"/) {
          return 0
        }

        sub(/^[[:space:]]*description[[:space:]]*=[[:space:]]*"/, "", line)
        value = ""
        prev = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "\"" && prev != "\\") {
            return length(value) > 0
          }
          value = value c
          prev = c
        }
        return 0
      }

      /^[[:space:]]*variable[[:space:]]+"[^"]+"[[:space:]]*\{/ {
        current_name = $0
        sub(/^[[:space:]]*variable[[:space:]]*"/, "", current_name)
        sub(/".*$/, "", current_name)

        current_file = FILENAME
        in_variable = 1
        saw_type = 0
        saw_description = 0
        depth = brace_delta($0)
        next
      }

      in_variable {
        if ($0 ~ /^[[:space:]]*type[[:space:]]*=/) {
          saw_type = 1
        }
        if (description_nonempty($0)) {
          saw_description = 1
        }

        depth += brace_delta($0)
        if (depth <= 0) {
          if (!saw_type) {
            printf "%s: variable %s missing explicit type\n", current_file, current_name
            exit 1
          }
          if (!saw_description) {
            printf "%s: variable %s missing non-empty description\n", current_file, current_name
            exit 1
          }

          in_variable = 0
          depth = 0
        }
      }

      END {
        if (in_variable) {
          printf "%s: variable %s block did not close cleanly\n", current_file, current_name
          exit 1
        }
      }
    ' "$file" || return 1
  done
}

@test "terraform repository layout is present and rooted correctly" {
  run guard_terraform_layout "$TERRAFORM_DIR"
  [ "$status" -eq 0 ]
}

@test "terraform/platform layout guard skips until F6 lands" {
  local dir="${TERRAFORM_DIR}/platform"

  [ -d "$dir" ] || skip "terraform/platform not present yet (built by F6)"

  run guard_directory_has_tf_files "$dir"
  [ "$status" -eq 0 ]
}

@test "terraform/environments layout guard skips until F2 lands" {
  local dir="${TERRAFORM_DIR}/environments"

  [ -d "$dir" ] || skip "terraform/environments not present yet (built by F2)"

  run guard_directory_has_tf_files "$dir"
  [ "$status" -eq 0 ]
}

@test "terraform/modules layout guard skips until F3-F5 land" {
  local dir="${TERRAFORM_DIR}/modules"

  [ -d "$dir" ] || skip "terraform/modules not present yet (built by F3/F4/F5)"

  run guard_modules_layout "$dir"
  [ "$status" -eq 0 ]
}

@test "terraform source is formatted with terraform fmt -recursive -check" {
  run guard_terraform_fmt_check "$TERRAFORM_DIR"
  [ "$status" -eq 0 ]
}

@test "MUTATION: terraform fmt guard fails on an unformatted copy" {
  cp "${FIXTURE_DIR}/broken-unformatted/main.tf" "${BATS_TEST_TMPDIR}/main.tf"

  run guard_terraform_fmt_check "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"terraform fmt -recursive -check failed"* ]]
}

@test "bootstrap versions.tf pins terraform and provider versions" {
  run guard_version_pins "${BOOTSTRAP_DIR}/versions.tf"
  [ "$status" -eq 0 ]
}

@test "terraform/versions.tf is the canonical pinned reference" {
  run guard_version_pins "${TERRAFORM_DIR}/versions.tf"
  [ "$status" -eq 0 ]
}

@test "terraform/platform versions pins guard skips until F6 lands" {
  local dir="${TERRAFORM_DIR}/platform"
  local file="${dir}/versions.tf"

  [ -d "$dir" ] || skip "terraform/platform not present yet (built by F6)"

  run guard_version_pins "$file"
  [ "$status" -eq 0 ]
}

@test "terraform/environments versions pins guard skips until F2 lands" {
  local dir="${TERRAFORM_DIR}/environments"
  local file="${dir}/versions.tf"

  [ -d "$dir" ] || skip "terraform/environments not present yet (built by F2)"

  run guard_version_pins "$file"
  [ "$status" -eq 0 ]
}

@test "every Terraform variable declares an explicit type and non-empty description" {
  run guard_variable_metadata "$TERRAFORM_DIR"
  [ "$status" -eq 0 ]
}

@test "MUTATION: variable metadata guard fails on an untyped variable copy" {
  run guard_variable_metadata "${FIXTURE_DIR}/broken-untyped-variable/variables.tf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project_id"* ]]
}

@test "MUTATION: variable metadata guard fails on an undescribed variable copy" {
  run guard_variable_metadata "${FIXTURE_DIR}/broken-undescribed-variable/variables.tf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"location"* ]]
}

@test "fixture broken-untyped-variable stays close to the real bootstrap variables" {
  run assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-untyped-variable/variables.tf" \
    "${BOOTSTRAP_DIR}/variables.tf"
  [ "$status" -eq 0 ]
}

@test "fixture broken-undescribed-variable stays close to the real bootstrap variables" {
  run assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-undescribed-variable/variables.tf" \
    "${BOOTSTRAP_DIR}/variables.tf"
  [ "$status" -eq 0 ]
}

repo_relative_path() {
  local target="$1"

  case "$target" in
    "$REPO_ROOT")
      printf '.\n'
      ;;
    "$REPO_ROOT"/*)
      printf '%s\n' "${target#"$REPO_ROOT"/}"
      ;;
    *)
      printf '%s\n' "$target"
      ;;
  esac
}

guard_no_tracked_tfstate_files() {
  local target="$1"
  local tracked_state

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  tracked_state="$(cd "$REPO_ROOT" && git ls-files | awk '/(^|\/)[^\/]+\.tfstate(\..*)?$/ { print; exit }')"
  [ -z "$tracked_state" ] || {
    echo "tracked Terraform state file found: $tracked_state"
    return 1
  }
}

guard_no_tracked_dot_terraform_content() {
  local target="$1"
  local tracked_entry

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  tracked_entry="$(cd "$REPO_ROOT" && git ls-files | awk '/(^|\/)\.terraform\// { print; exit }')"
  [ -z "$tracked_entry" ] || {
    echo "tracked .terraform content found: $tracked_entry"
    return 1
  }
}

guard_lock_file_is_committed() {
  local target="$1"
  local target_rel
  local tracked_entry
  local ignore_status

  [ -f "$target" ] || { echo "guard target missing: $target"; return 1; }

  target_rel="$(repo_relative_path "$target")"

  # The lock file is committed on purpose because the point of a lock file is
  # that everyone resolves the same provider build.
  (
    cd "$REPO_ROOT" &&
      git check-ignore -q "$target_rel"
  )
  ignore_status="$?"
  [ "$ignore_status" -ne 0 ] || {
    echo "lock file is ignored: $target_rel"
    return 1
  }

  tracked_entry="$(cd "$REPO_ROOT" && git ls-files -- "$target_rel")"
  [ -n "$tracked_entry" ] || {
    echo "lock file is not committed: $target_rel"
    return 1
  }
}

guard_bootstrap_gitignore_behavior() {
  local target="$1"
  local expectation
  local path
  local ignore_status

  [ -d "$target" ] || { echo "guard target missing: $target"; return 1; }

  while IFS='|' read -r expectation path; do
    [ -n "$path" ] || continue

    (
      cd "$REPO_ROOT" &&
        git check-ignore -q "$path"
    )
    ignore_status="$?"

    if [ "$expectation" = "ignored" ]; then
      [ "$ignore_status" -eq 0 ] || {
        echo "expected path to be ignored: $path"
        return 1
      }
      continue
    fi

    [ "$ignore_status" -ne 0 ] || {
      echo "expected path to remain visible to git: $path"
      return 1
    }
  done <<'EOF'
ignored|terraform/bootstrap/x.tfstate
ignored|terraform/bootstrap/x.tfstate.backup
ignored|terraform/bootstrap/.terraform/plugins
ignored|terraform/bootstrap/dev.tfvars
ignored|terraform/bootstrap/crash.log
visible|terraform/bootstrap/terraform.tfvars.example
EOF
}

guard_no_absolute_home_paths() {
  local target="$1"
  local target_rel
  local excluded_contract="terraform/CONTRACT.md"
  local excluded_isa="terraform/ISA.md"
  local home_pattern
  local rel_file
  local abs_file
  local match
  local -a tracked_files

  [ -e "$target" ] || { echo "guard target missing: $target"; return 1; }

  # The two frozen inputs excluded below quote the prohibition itself. That they still exist is
  # asserted by guard_absolute_home_path_exclusions_are_live, deliberately NOT here: folding that
  # check into this guard would let the MUTATION test below fail for the wrong reason — it would
  # go red on a missing CONTRACT.md while proving nothing about absolute-path detection.

  # This regex is stricter than a single hardcoded username, and it does not
  # match its own literal text here because the character after /home/ is `[`,
  # which is not in [a-z].
  home_pattern='/home/[a-z][a-z0-9_-]*'

  if [ -d "$target" ]; then
    target_rel="$(repo_relative_path "$target")"
    mapfile -t tracked_files < <(cd "$REPO_ROOT" && git ls-files -- "$target_rel")
  else
    tracked_files=("$(repo_relative_path "$target")")
  fi

  [ "${#tracked_files[@]}" -gt 0 ] || { echo "no tracked files found under $target"; return 1; }

  for rel_file in "${tracked_files[@]}"; do
    [ -n "$rel_file" ] || continue

    case "$rel_file" in
      "$excluded_contract"|"$excluded_isa")
        continue
        ;;
    esac

    abs_file="${REPO_ROOT}/${rel_file}"
    [ -f "$abs_file" ] || { echo "tracked file missing from disk: $rel_file"; return 1; }

    match="$(grep -nE -- "$home_pattern" "$abs_file" || true)"
    [ -z "$match" ] || {
      echo "absolute home path found in $rel_file"
      echo "$match"
      return 1
    }
  done
}

# An exclusion list is a hole in a guard, so it needs its own tripwire. If one of the two frozen
# files is renamed or deleted, the exclusion silently starts covering nothing and nobody notices
# — the suite would stay green while the reason for the exclusion had evaporated.
guard_absolute_home_path_exclusions_are_live() {
  local excluded

  for excluded in "terraform/CONTRACT.md" "terraform/ISA.md"; do
    [ -f "${REPO_ROOT}/${excluded}" ] || {
      echo "excluded path missing: ${excluded}; the absolute-home-path exclusion list has gone stale"
      return 1
    }
  done
}

@test "absolute home path exclusion list still refers to files that exist" {
  run guard_absolute_home_path_exclusions_are_live
  [ "$status" -eq 0 ]
}

@test "no tracked Terraform state files are committed anywhere in the repo" {
  run guard_no_tracked_tfstate_files "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "no tracked .terraform directory content is committed anywhere in the repo" {
  run guard_no_tracked_dot_terraform_content "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test ".terraform.lock.hcl is committed and not ignored" {
  run guard_lock_file_is_committed "${BOOTSTRAP_DIR}/.terraform.lock.hcl"
  [ "$status" -eq 0 ]
}

@test ".gitignore behavior protects generated Terraform state and local-only inputs" {
  run guard_bootstrap_gitignore_behavior "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "no committed Terraform file or Terraform test contains an absolute home path" {
  run guard_no_absolute_home_paths "$TERRAFORM_DIR"
  [ "$status" -eq 0 ]

  run guard_no_absolute_home_paths "${REPO_ROOT}/test/terraform-conventions.bats"
  [ "$status" -eq 0 ]

  run guard_no_absolute_home_paths "${REPO_ROOT}/test/terraform-state-protection.bats"
  [ "$status" -eq 0 ]
}

@test "MUTATION: absolute home path guard fails on a hardcoded home path copy" {
  run guard_no_absolute_home_paths "${FIXTURE_DIR}/broken-absolute-path/main.tf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broken-absolute-path/main.tf"* ]]
}

@test "fixture broken-absolute-path stays close to the real bootstrap main.tf" {
  run assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-absolute-path/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf"
  [ "$status" -eq 0 ]
}

@test "fixture broken-unformatted stays close to the real bootstrap main.tf" {
  # This fixture is the deliberate exception: it strips indentation from nearly
  # every indented line, so only this check widens the bound instead of every
  # fixture fidelity test.
  run assert_fixture_is_faithful_copy \
    "${FIXTURE_DIR}/broken-unformatted/main.tf" \
    "${BOOTSTRAP_DIR}/main.tf" \
    "79"
  [ "$status" -eq 0 ]
}
