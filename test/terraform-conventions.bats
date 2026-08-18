#!/usr/bin/env bats
#
# Repository-wide Terraform conventions for the GCP demo platform.
#
# Offline. No network, no cloud credentials, no `terraform init`. Under 30s.
#
# ─── What belongs here ──────────────────────────────────────────────────────
#
# CONTRACT §7a makes native `terraform test` the primary correctness surface, so anything about
# the VALUE an attribute evaluates to lives in a `.tftest.hcl`. What stays here is the class a
# plan genuinely cannot express: properties of the whole repository. A plan sees only what it
# evaluated — it cannot tell you that no root anywhere is missing a version pin, that no
# committed file anywhere contains a developer's home directory, or that no `.tfstate` is tracked
# by git. Those are merge-time properties spanning modules no root has wired up yet.
#
# ─── The failure mode this file is built against ────────────────────────────
#
# A guard that greps for a forbidden pattern passes when the file it greps was never written.
# `grep -q BAD terraform/ || pass` is green on an empty repository. Every check below therefore
# proves its subject EXISTS before asserting anything about its content, and the mutation tests
# at the bottom prove each guard can actually go red.
#
# ─── The errexit trap ───────────────────────────────────────────────────────
#
# A bare `! some_command` that is not a test's final line does NOT fail the test under bats'
# errexit handling — it evaluates, the negation succeeds or fails, and execution continues either
# way. Guards written that way are decoration. Every negative assertion here uses
# `run ...` followed by an explicit `[ "$status" -ne 0 ]`, which is checked.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  cd "${REPO_ROOT}"
  FIXTURES="${REPO_ROOT}/test/fixtures/terraform/bootstrap"
}

# ── Layout ──────────────────────────────────────────────────────────────────

@test "the terraform tree exists and is tracked by git" {
  [ -d terraform ]
  run git ls-files --error-unmatch terraform/README.md
  [ "$status" -eq 0 ]
}

@test "the bootstrap root exists and carries its own terraform files" {
  [ -d terraform/bootstrap ]
  run bash -c 'ls terraform/bootstrap/*.tf 2>/dev/null | wc -l'
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "terraform/README.md documents the root layout and the destroy exclusions" {
  [ -f terraform/README.md ]
  run grep -qiE 'bootstrap' terraform/README.md
  [ "$status" -eq 0 ]
  run grep -qiE 'osramp/platform' terraform/README.md
  [ "$status" -eq 0 ]
}

# ── Formatting ──────────────────────────────────────────────────────────────

@test "the whole terraform tree is canonically formatted" {
  [ -d terraform ]
  run terraform fmt -recursive -check terraform/
  [ "$status" -eq 0 ]
}

@test "MUTATION: an unformatted file makes the fmt guard fail" {
  [ -d "${FIXTURES}/broken-unformatted" ]
  run terraform fmt -check "${FIXTURES}/broken-unformatted"
  [ "$status" -ne 0 ]
}

# ── Version pinning ─────────────────────────────────────────────────────────

@test "every terraform root and module pins a minimum terraform version" {
  local missing=()
  while IFS= read -r d; do
    grep -rqE 'required_version[[:space:]]*=' "$d" || missing+=("$d")
  done < <(_tf_config_dirs)
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'no required_version in: %s\n' "${missing[@]}" >&2
    return 1
  }
}

@test "every terraform root and module pins the google provider with a ~> constraint" {
  local missing=()
  while IFS= read -r d; do
    grep -rqE 'version[[:space:]]*=[[:space:]]*"~>' "$d" || missing+=("$d")
  done < <(_tf_config_dirs)
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'no ~> provider pin in: %s\n' "${missing[@]}" >&2
    return 1
  }
}

@test "the version pin guard is not vacuous — it found at least two config directories" {
  local n
  n="$(_tf_config_dirs | wc -l)"
  [ "$n" -ge 2 ]
}

# ── Variable hygiene ────────────────────────────────────────────────────────

# The audit helper is invoked by absolute path below, never through a `bash -c` string. An
# unexpanded variable inside single quotes makes the helper unreachable, bash exits 127, and a
# `[ "$status" -ne 0 ]` mutation check reads that "command not found" as the guard correctly
# firing. Both mutation checks then pass while measuring nothing. This test exists so that
# failure is impossible to reach silently.
@test "the variable audit helper exists and is executable" {
  [ -x "${REPO_ROOT}/test/lib/tf-variable-audit.sh" ]
  run "${REPO_ROOT}/test/lib/tf-variable-audit.sh"
  [ "$status" -eq 2 ]
}

@test "every declared variable has an explicit type" {
  run "${REPO_ROOT}/test/lib/tf-variable-audit.sh" type terraform
  [ "$status" -eq 0 ]
}

@test "every declared variable has a non-empty description" {
  run "${REPO_ROOT}/test/lib/tf-variable-audit.sh" description terraform
  [ "$status" -eq 0 ]
}

@test "MUTATION: a variable with no type makes the type guard fail" {
  [ -d "${FIXTURES}/broken-untyped-variable" ]
  run "${REPO_ROOT}/test/lib/tf-variable-audit.sh" type "${FIXTURES}/broken-untyped-variable"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no type"* ]]
}

@test "MUTATION: a variable with no description makes the description guard fail" {
  [ -d "${FIXTURES}/broken-undescribed-variable" ]
  run "${REPO_ROOT}/test/lib/tf-variable-audit.sh" description "${FIXTURES}/broken-undescribed-variable"
  [ "$status" -eq 1 ]
  [[ "$output" == *"description"* ]]
}

# ── Git hygiene ─────────────────────────────────────────────────────────────

@test "no terraform state file is tracked by git anywhere in the repository" {
  run bash -c "git ls-files | grep -E '\\.tfstate' | head -5"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no .terraform working directory is tracked by git" {
  run bash -c "git ls-files | grep -E '(^|/)\\.terraform/' | head -5"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the gitignore refuses state files and terraform working directories" {
  [ -f .gitignore ]
  run grep -qE '^\*\.tfstate' .gitignore
  [ "$status" -eq 0 ]
  run grep -qE '^\.terraform/' .gitignore
  [ "$status" -eq 0 ]
}

@test "the provider lock file is committed rather than ignored" {
  run bash -c "git ls-files | grep -c '\\.terraform\\.lock\\.hcl'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ── Portability ─────────────────────────────────────────────────────────────

# Scope is source and configuration, not prose. CONTRACT.md and ISA.md legitimately contain the
# string "/home/andy" because they STATE this rule — a guard that cannot tell a violation from
# the sentence forbidding it is a guard nobody will keep. Fixture trees are excluded for the same
# reason in reverse: broken-absolute-path is broken on purpose so the mutation test has something
# to catch.
@test "no committed terraform source or script embeds a developer home directory" {
  run bash -c "_tf_portable_files() { git ls-files -- 'terraform/*.tf' 'terraform/**/*.tf' 'terraform/**/*.tftest.hcl' 'terraform/**/*.example' 'scripts/gcp-tf/*.sh' 'scripts/ci/gcp-tf-*.sh'; }; _tf_portable_files | xargs -r grep -l '/home/[a-z]' 2>/dev/null | head -5"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the portability guard is not vacuous — it scanned real terraform source" {
  local n
  n="$(git ls-files -- 'terraform/*.tf' 'terraform/**/*.tf' | wc -l)"
  [ "$n" -ge 4 ]
}

@test "MUTATION: an absolute home path makes the portability guard fail" {
  [ -d "${FIXTURES}/broken-absolute-path" ]
  run bash -c "grep -rl '/home/[a-z]' '${FIXTURES}/broken-absolute-path' | head -1"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── Native test discipline (CONTRACT §7a) ───────────────────────────────────

@test "no native terraform test applies — plan only, everywhere" {
  run bash -c "_tf_test_files() { find terraform -type f -name '*.tftest.hcl' -not -path '*/.terraform/*'; }; _tf_test_files | xargs -r grep -l 'command[[:space:]]*=[[:space:]]*apply' | head -5"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every native terraform test mocks its provider" {
  local unmocked=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE '^[[:space:]]*mock_provider' "$f" || unmocked+=("$f")
  done < <(_tf_test_files)
  [ "${#unmocked[@]}" -eq 0 ] || {
    printf 'no mock_provider in: %s\n' "${unmocked[@]}" >&2
    return 1
  }
}

# Discovery uses find, not a git pathspec. `git ls-files -- 'terraform/**/*.tftest.hcl'` matched
# nothing here — it misses files that are staged-but-new, and the ** glob does not behave the way
# a shell would lead you to expect. A discovery predicate that silently returns zero turns every
# "for each discovered file, assert X" check above into a vacuous pass.
@test "the tftest guards are not vacuous — suites were actually discovered" {
  local n
  n="$(_tf_test_files | wc -l)"
  [ "$n" -ge 1 ]
}

@test "every tftest suite using expect_failures also contains a passing assertion" {
  local unpaired=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q 'expect_failures' "$f" || continue
    grep -q 'assert[[:space:]]*{' "$f" || unpaired+=("$f")
  done < <(_tf_test_files)
  [ "${#unpaired[@]}" -eq 0 ] || {
    printf 'expect_failures with no paired passing assertion: %s\n' "${unpaired[@]}" >&2
    return 1
  }
}

# ── Helper ──────────────────────────────────────────────────────────────────
#
# Every directory under terraform/ that holds .tf files, excluding fixture trees (which are
# deliberately broken) and terraform working directories.
_tf_config_dirs() {
  find terraform -type f -name '*.tf' \
    -not -path '*/.terraform/*' \
    -printf '%h\n' 2>/dev/null | sort -u
}

# Every native test suite in the tree. See the vacuity note above the discovery test.
_tf_test_files() {
  find terraform -type f -name '*.tftest.hcl' -not -path '*/.terraform/*' 2>/dev/null | sort
}
