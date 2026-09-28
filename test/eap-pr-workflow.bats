#!/usr/bin/env bats
#
# eap-pr-workflow.bats — the EAP suites are gated on pull_request, and only
# through `make test-eap-offline`.
#
# ─── The defect ─────────────────────────────────────────────────────────────
# SLES B11: the EAP pytest suites ran only on the nightly GCP VM lane
# (signalloom-ci.yaml, workflow_dispatch + cron). Nothing ran them on a PR.
# The fix is a second, runner-hosted workflow. Two ways that fix quietly
# regresses, both caught here:
#
#   1. Someone adds `pull_request` to signalloom-ci.yaml instead. That starts
#      a GCP VM on every PR and times out. So this suite asserts the NEW file
#      has the trigger AND the OLD file still does not.
#   2. The PR workflow drifts from the Makefile target to a bare pytest
#      invocation ("pip install pytest && pytest tests"). That runs different
#      code in CI than a developer runs locally. So this suite asserts a step
#      runs the literal command `make test-eap-offline`, not a pytest of its
#      own.
#
# ─── Parametrised on purpose ────────────────────────────────────────────────
# EAP_PR_WORKFLOW overrides the file under test. The positive control for the
# drift guard is: copy the workflow to a scratch file, replace the make line
# with `python -m pytest tests -q`, point EAP_PR_WORKFLOW at the copy, and
# watch the drift test go red. A guard that cannot be shown failing has not
# been shown to guard anything.
#
# Offline: yq, grep, coreutils. No network, no cluster, no uv.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export WORKFLOW="${EAP_PR_WORKFLOW:-${REPO_ROOT}/.github/workflows/signalloom-eap-pr.yaml}"
  export NIGHTLY="${REPO_ROOT}/.github/workflows/signalloom-ci.yaml"
  export CONTROL="${REPO_ROOT}/.github/workflows/security-scan.yaml"
}

setup() {
  command -v yq >/dev/null || skip "yq is required"
  [ -f "${WORKFLOW}" ] || fail "workflow under test is missing: ${WORKFLOW}"
}

fail() {
  echo "$*" >&2
  return 1
}

# `! grep ...` is dead under bats' errexit on any line but the last: bash does
# not trip errexit on a negated pipeline. Every negative assertion goes through
# this instead so a match fails the test wherever the line sits.
refute_grep() {
  if grep "$@"; then
    fail "expected no match for: grep $*"
  fi
}

# yq turns the bare key `on` into `true` under YAML 1.1 in some versions and
# leaves it as "on" in others. Select whichever is present so the assertion is
# about the trigger list, not about the yq build on the box.
triggers() {
  yq '(.on // .true) | keys | .[]' "$1"
}

@test "new workflow triggers on pull_request" {
  run triggers "${WORKFLOW}"
  [ "$status" -eq 0 ]
  grep -qx 'pull_request' <<<"$output"
}

@test "nightly signalloom-ci.yaml still does NOT trigger on pull_request" {
  [ -f "${NIGHTLY}" ]
  run triggers "${NIGHTLY}"
  [ "$status" -eq 0 ]
  refute_grep -qx 'pull_request' <<<"$output"
  # It must still be the dispatch + schedule lane; if both vanish the file was
  # gutted, which is a different regression from the one above.
  grep -qx 'workflow_dispatch' <<<"$output"
  grep -qx 'schedule' <<<"$output"
}

@test "positive control: the trigger probe sees pull_request on security-scan.yaml" {
  # Proves triggers() reads the trigger list correctly on a file known to have
  # pull_request, so the negative assertion above is not vacuous.
  [ -f "${CONTROL}" ]
  run triggers "${CONTROL}"
  [ "$status" -eq 0 ]
  grep -qx 'pull_request' <<<"$output"
}

@test "job runs on ubuntu-latest with a timeout of at most 10 minutes" {
  run yq -e '.jobs.eap-offline."runs-on" == "ubuntu-latest"' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  run yq -e '.jobs.eap-offline."timeout-minutes" <= 10' "${WORKFLOW}"
  [ "$status" -eq 0 ]
}

@test "a step runs the literal command make test-eap-offline (drift guard)" {
  # Only `run:` bodies count. A comment mentioning the target, or a `name:`
  # that says it, does not satisfy this. The line must be the command itself.
  run yq '.jobs.eap-offline.steps[].run // ""' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  grep -Eq '^[[:space:]]*make test-eap-offline([[:space:]]|$)' <<<"$output"
}

@test "no step invokes pytest directly (the Makefile target is the only runner)" {
  run yq '.jobs.eap-offline.steps[].run // ""' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  refute_grep -Eq '(^|[[:space:];&|])(python[0-9.]* -m pytest|pytest)([[:space:]]|$)' <<<"$output"
}

@test "the make step cannot mask its exit status" {
  # The step that runs make declares bash with `set -euo pipefail` and exits
  # with make's own rc. A trailing `| tee` or `| tail` on the make line would
  # replace that rc with the filter's.
  # The selector matches a COMMAND line, not any mention: the assert step's
  # error message also says "make test-eap-offline", and must not be picked.
  run yq '.jobs.eap-offline.steps[] | select(.run // "" | test("(?m)^\\s*make test-eap-offline(\\s|$)")) | .shell' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  [ "$output" = "bash" ]
  run yq '.jobs.eap-offline.steps[] | select(.run // "" | test("(?m)^\\s*make test-eap-offline(\\s|$)")) | .run' "${WORKFLOW}"
  grep -q 'set -euo pipefail' <<<"$output"
  # `||` is control flow (make ... || rc=$?), not a pipe; strip it, then any
  # remaining `|` on the make line is a filter that would own the exit status.
  make_line="$(grep -E '^[[:space:]]*make test-eap-offline' <<<"$output" | sed 's/||//g')"
  [ -n "$make_line" ]
  refute_grep -q '|' <<<"$make_line"
}

@test "the target is asserted with make -n before it is run" {
  # Step order matters: the existence probe must come before the run.
  run yq '[.jobs.eap-offline.steps[].run // ""] | to_entries | map(select(.value | test("make -n test-eap-offline"))) | .[0].key' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  assert_idx="$output"
  run yq '[.jobs.eap-offline.steps[].run // ""] | to_entries | map(select(.value | test("(?m)^\\s*make test-eap-offline(\\s|$)"))) | .[0].key' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  [ "$assert_idx" -lt "$output" ]
}

@test "permissions are contents: read and nothing else" {
  run yq -e '(.permissions | keys | length) == 1 and .permissions.contents == "read"' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  # And no job widens it back out.
  run yq '.jobs[].permissions // "none"' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "no secrets and no cloud auth action are referenced" {
  # Comments are stripped first: the header prose says "no secrets", and a
  # guard satisfied or tripped by a comment guards nothing. What remains is
  # the executable YAML, and in it these three shapes are forbidden.
  code="$(grep -v '^[[:space:]]*#' "${WORKFLOW}")"
  refute_grep -Eq '\$\{\{[^}]*secrets\.' <<<"$code"
  refute_grep -Eq 'uses:[[:space:]]*google-github-actions/auth' <<<"$code"
  refute_grep -Eq '^[[:space:]]*id-token:' <<<"$code"
}

@test "every uses: is pinned to a full 40-hex commit SHA" {
  run yq '.jobs.eap-offline.steps[].uses // ""' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  uses_lines="$(grep -v '^$' <<<"$output")"
  [ -n "$uses_lines" ]
  while IFS= read -r u; do
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$' <<<"$u" \
      || fail "unpinned action: $u"
  done <<<"$uses_lines"
}

@test "uv cache is keyed on the fe-signalloom requirements.txt" {
  run yq '.jobs.eap-offline.steps[] | select(.uses // "" | test("astral-sh/setup-uv")) | .with."cache-dependency-glob"' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  [ "$output" = "d2-signalloom/apps/fe-signalloom/src/requirements.txt" ]
  [ -f "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/requirements.txt" ]
}

@test "paths filter names the app, both bats suites, the Makefile and itself" {
  run yq '(.on // .true).pull_request.paths[]' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  for p in 'd2-signalloom/apps/fe-signalloom/**' \
           'd2-signalloom/test/authz-suite-liveness.bats' \
           'd2-signalloom/test/api-route-liveness.bats' \
           'Makefile' \
           '.github/workflows/signalloom-eap-pr.yaml'; do
    grep -qxF "$p" <<<"$output" || fail "paths filter is missing: $p"
  done
}

@test "concurrency is per-ref with cancel-in-progress" {
  run yq -e '.concurrency.group | test("github.ref")' "${WORKFLOW}"
  [ "$status" -eq 0 ]
  run yq -e '.concurrency."cancel-in-progress" == true' "${WORKFLOW}"
  [ "$status" -eq 0 ]
}
