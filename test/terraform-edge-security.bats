#!/usr/bin/env bats
#
# terraform-edge-security.bats -- the SECONDARY surface for the F4 edge chunk.
#
# terraform test (terraform/modules/edge/tests/*.tftest.hcl) is the primary
# correctness surface: it asserts on evaluated plan attributes. This file is
# deliberately retargeted at what a plan cannot see:
#
#   * shell script behaviour and exit-code polarity
#   * whole-tree absence properties (a plan sees one configuration, not "no
#     configuration anywhere contains X")
#   * that the tftest suite itself can FAIL -- the mutation checks
#
# Every test asserts the thing under test EXISTS before asserting anything about
# it. A grep that finds nothing because the file was never created is a green
# test measuring nothing, and that is the specific failure this chunk was told
# to design against.
#
# No network. No cloud credentials. No terraform apply. Runs in ~15s.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export EDGE_MODULE="${REPO_ROOT}/terraform/modules/edge"
  export EDGE_TESTS="${EDGE_MODULE}/tests"
  export PROBE_DIR="${REPO_ROOT}/scripts/gcp-tf"
  export FIXTURE_DIR="${REPO_ROOT}/test/fixtures/terraform/edge"

  # terraform test needs the provider schema, which init -backend=false puts in
  # .terraform/. Do it once here rather than per-test. If it cannot be done
  # (genuinely offline with no cached provider) the mutation tests FAIL loudly
  # rather than skipping -- "the guard could not be run" is not "the guard works".
  if [ ! -d "${EDGE_MODULE}/.terraform" ]; then
    ( cd "${EDGE_MODULE}" && terraform init -backend=false -input=false >/dev/null 2>&1 ) || true
  fi

  # Fingerprint the real module before any mutation runs. Comparing this at the
  # end is exact and independent of commit state; asking git whether the tree is
  # clean would conflate a leaking harness with ordinary work in progress.
  module_fingerprint > "${BATS_FILE_TMPDIR}/module.sha"
}

module_fingerprint() {
  # Every file in the module except the provider cache, not just *.tf. An
  # earlier version of this fingerprint covered only *.tf and *.tftest.hcl and
  # would have sat green while .terraform.lock.hcl was deleted underneath it.
  # A tree-integrity check with a file-type filter is a tree-integrity check
  # with a blind spot.
  find "${EDGE_MODULE}" -type f -not -path '*/.terraform/*' | sort | xargs sha256sum
}

setup() {
  PROBE_NEGATIVE="${PROBE_DIR}/edge-probe-negative.sh"
  PROBE_POSITIVE="${PROBE_DIR}/edge-probe-positive.sh"
  PROBE_BYPASS="${PROBE_DIR}/edge-probe-bypass.sh"
  PROBES=("$PROBE_NEGATIVE" "$PROBE_POSITIVE" "$PROBE_BYPASS")
}

# Build a throwaway copy of the module: real sources, real tests, .terraform
# symlinked so no provider is downloaded. The real tree is never mutated.
stage_module() {
  local dest="$1"
  mkdir -p "${dest}/tests"
  cp "${EDGE_MODULE}"/*.tf "${dest}/"
  cp "${EDGE_MODULE}"/.terraform.lock.hcl "${dest}/" 2>/dev/null || true
  cp "${EDGE_TESTS}"/*.tftest.hcl "${dest}/tests/"
  ln -sfn "${EDGE_MODULE}/.terraform" "${dest}/.terraform"
}

# Write a fake curl onto PATH. $1 = dir, $2 = body printed to stdout,
# $3 = exit code. Every probe calls curl unqualified, so this intercepts it.
stub_curl() {
  local dir="$1" body="$2" code="$3"
  mkdir -p "$dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'printf %s "%s"\n' "'%s'" "$body"
    printf 'exit %s\n' "$code"
  } > "${dir}/curl"
  chmod +x "${dir}/curl"
}

# ---------------------------------------------------------------------------
# Existence. Nothing below means anything if these fail.
# ---------------------------------------------------------------------------

@test "edge module and its native test suite exist" {
  [ -d "$EDGE_MODULE" ]
  for f in main.tf armor.tf variables.tf outputs.tf versions.tf README.md; do
    [ -f "${EDGE_MODULE}/${f}" ] || { echo "missing ${EDGE_MODULE}/${f}"; return 1; }
  done
  [ -d "$EDGE_TESTS" ]
  local n
  n="$(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f | wc -l)"
  [ "$n" -ge 3 ] || { echo "expected >=3 tftest files, found ${n}"; return 1; }
}

@test "all three probe scripts exist and are executable" {
  for p in "${PROBES[@]}"; do
    [ -f "$p" ] || { echo "missing ${p}"; return 1; }
    [ -x "$p" ] || { echo "not executable: ${p}"; return 1; }
  done
}

@test "all four mutation fixtures exist" {
  [ -d "$FIXTURE_DIR" ]
  for f in armor-default-allow armor-preview-true armor-no-default-rule armor-truncated-allowlist; do
    [ -f "${FIXTURE_DIR}/${f}.tf.fixture" ] || { echo "missing fixture ${f}"; return 1; }
  done
  # Fixtures must never be picked up as real configuration.
  [ -z "$(find "$FIXTURE_DIR" -name '*.tf' -type f)" ]
}

# ---------------------------------------------------------------------------
# Probe scripts -- behaviour a plan cannot see
# ---------------------------------------------------------------------------

@test "probe scripts are shellcheck-clean" {
  run shellcheck "${PROBES[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "every probe --dry-run exits 0 and makes no network request" {
  # A curl stub that fails loudly proves the dry-run path is genuinely offline,
  # rather than merely happening to work on a machine with connectivity.
  local bindir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bindir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'echo "NETWORK ACCESS ATTEMPTED: curl $*" >&2'
    printf '%s\n' 'exit 99'
  } > "${bindir}/curl"
  chmod +x "${bindir}/curl"

  PATH="${bindir}:${PATH}" run "$PROBE_NEGATIVE" --dry-run demo-1.example.invalid
  [ "$status" -eq 0 ] || { echo "negative dry-run: status=${status} ${output}"; return 1; }
  [[ "$output" != *"NETWORK ACCESS ATTEMPTED"* ]]

  PATH="${bindir}:${PATH}" run "$PROBE_POSITIVE" --dry-run demo-1.example.invalid
  [ "$status" -eq 0 ] || { echo "positive dry-run: status=${status} ${output}"; return 1; }
  [[ "$output" != *"NETWORK ACCESS ATTEMPTED"* ]]

  PATH="${bindir}:${PATH}" run "$PROBE_BYPASS" --dry-run 10.128.0.2 8080
  [ "$status" -eq 0 ] || { echo "bypass dry-run: status=${status} ${output}"; return 1; }
  [[ "$output" != *"NETWORK ACCESS ATTEMPTED"* ]]
}

@test "positive probe treats an anonymous 200 as FAILURE" {
  # The single most important behavioural assertion in this file. An anonymous
  # 200 from an allowlisted source means network position alone granted access:
  # the IP allowlist silently became the authentication control. A probe that
  # reported that as success would certify the exact hole it exists to find.
  local bindir="${BATS_TEST_TMPDIR}/bin200"
  stub_curl "$bindir" "200" 0

  PATH="${bindir}:${PATH}" run "$PROBE_POSITIVE" demo-1.example.invalid
  [ "$status" -ne 0 ] || { echo "anonymous 200 was reported as PASS"; return 1; }
  [ "$status" -eq 3 ] || { echo "expected exit 3 (anonymous 200), got ${status}: ${output}"; return 1; }
  [[ "$output" == *"200"* ]]
}

@test "positive probe treats the auth boundary as PASS" {
  # Paired positive for the test above. Without it, a stub curl that was simply
  # broken would make the probe exit non-zero for an unrelated reason and the
  # 200-is-failure assertion would prove nothing.
  local bindir="${BATS_TEST_TMPDIR}/bin302"
  stub_curl "$bindir" "302" 0

  PATH="${bindir}:${PATH}" run "$PROBE_POSITIVE" demo-1.example.invalid
  [ "$status" -eq 0 ] || { echo "302 should be a pass, got ${status}: ${output}"; return 1; }

  local bindir401="${BATS_TEST_TMPDIR}/bin401"
  stub_curl "$bindir401" "401" 0
  PATH="${bindir401}:${PATH}" run "$PROBE_POSITIVE" demo-1.example.invalid
  [ "$status" -eq 0 ] || { echo "401 should be a pass, got ${status}: ${output}"; return 1; }
}

@test "positive probe does not treat a failed request as a pass" {
  # A connection timeout and a 403 are both "not 200". Only one of them is
  # evidence of anything. Nothing measured is not a pass.
  local bindir="${BATS_TEST_TMPDIR}/bintimeout"
  stub_curl "$bindir" "000" 28

  PATH="${bindir}:${PATH}" run "$PROBE_POSITIVE" demo-1.example.invalid
  [ "$status" -eq 4 ] || { echo "expected exit 4 (inconclusive), got ${status}: ${output}"; return 1; }
}

@test "negative probe passes only on 403, not on any non-200" {
  local pass_dir="${BATS_TEST_TMPDIR}/neg403"
  stub_curl "$pass_dir" "403" 0
  PATH="${pass_dir}:${PATH}" run "$PROBE_NEGATIVE" demo-1.example.invalid
  [ "$status" -eq 0 ] || { echo "403 should be a pass, got ${status}: ${output}"; return 1; }

  # 503 is "not 200" but is not evidence that Cloud Armor denied anything.
  local fail_dir="${BATS_TEST_TMPDIR}/neg503"
  stub_curl "$fail_dir" "503" 0
  PATH="${fail_dir}:${PATH}" run "$PROBE_NEGATIVE" demo-1.example.invalid
  [ "$status" -ne 0 ] || { echo "503 was accepted as a Cloud Armor denial"; return 1; }

  # A timeout is the seductive one: no response looks like a block.
  local to_dir="${BATS_TEST_TMPDIR}/negtimeout"
  stub_curl "$to_dir" "000" 28
  PATH="${to_dir}:${PATH}" run "$PROBE_NEGATIVE" demo-1.example.invalid
  [ "$status" -ne 0 ] || { echo "a connection timeout was accepted as a denial"; return 1; }
}

@test "bypass probe inverts polarity: a reachable backend is the failure" {
  # curl exit 28 (timeout) = no route = the control held.
  local ok_dir="${BATS_TEST_TMPDIR}/bypassok"
  stub_curl "$ok_dir" "000" 28
  PATH="${ok_dir}:${PATH}" run "$PROBE_BYPASS" 10.128.0.2 8080
  [ "$status" -eq 0 ] || { echo "no-route should be a pass, got ${status}: ${output}"; return 1; }

  # A completed exchange means the LB can be walked around entirely.
  local bad_dir="${BATS_TEST_TMPDIR}/bypassbad"
  stub_curl "$bad_dir" "200" 0
  PATH="${bad_dir}:${PATH}" run "$PROBE_BYPASS" 10.128.0.2 8080
  [ "$status" -eq 3 ] || { echo "a reachable backend must exit 3, got ${status}: ${output}"; return 1; }
}

@test "probes take the target as an argument and hardcode no host or IP" {
  for p in "${PROBES[@]}"; do
    run "$p"
    [ "$status" -eq 2 ] || { echo "$(basename "$p") with no arguments should exit 2, got ${status}"; return 1; }
  done
  # No routable literal address baked into the scripts. RFC5737 and RFC1918
  # documentation addresses in help text and comments are fine and expected.
  run grep -nE '(https?://)?[0-9]{1,3}(\.[0-9]{1,3}){3}' "${PROBES[@]}"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" =~ 192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168\.|0\.0\.0\.0 ]] \
      || { echo "non-documentation IP literal: ${line}"; return 1; }
  done <<< "$output"
}

# ---------------------------------------------------------------------------
# Whole-tree absence properties -- the cases terraform test genuinely cannot do
# ---------------------------------------------------------------------------

@test "no tftest uses command = apply" {
  local n
  n="$(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f | wc -l)"
  [ "$n" -ge 3 ]
  # Existence of the guarded construct first: every file must actually declare
  # command = plan, so "no apply" cannot pass by the files being empty.
  local f
  while IFS= read -r f; do
    grep -q 'command *= *plan' "$f" || { echo "no 'command = plan' in ${f}"; return 1; }
    grep -q 'mock_provider "google" *{' "$f" || { echo "no mock_provider google in ${f}"; return 1; }
    grep -q 'mock_provider "google-beta" *{' "$f" || { echo "no mock_provider google-beta in ${f}"; return 1; }
  done < <(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f)

  run grep -rn 'command *= *apply' "$EDGE_TESTS"
  [ "$status" -ne 0 ] || { echo "command = apply found: ${output}"; return 1; }
}

@test "every tftest with expect_failures also contains a passing run" {
  local f found=0
  while IFS= read -r f; do
    grep -q 'expect_failures' "$f" || continue
    found=1
    grep -q '^\s*assert *{' "$f" || { echo "${f} has expect_failures but no assert block"; return 1; }
  done < <(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f)
  [ "$found" -eq 1 ] || { echo "no tftest uses expect_failures at all"; return 1; }
}

@test "no allowlist default or documented example permits the whole internet" {
  # The literals appear legitimately and often: in validation conditions that
  # REJECT them, in the error messages that explain the rejection, and in prose
  # documenting the prohibition. Excluding contexts one at a time is how this
  # guard degrades into an allowlist of excuses that matches nothing.
  #
  # So invert it. The thing that is actually dangerous is the literal appearing
  # as a VALUE -- an element of a list literal assigned to an allowlist, a
  # source-range field, or a default. Match that shape and nothing else.
  local f line hits=0 permissive_re
  permissive_re='(default|allowed_ipv4|allowed_ipv6|src_ip_ranges|source_ranges)[[:space:]]*=[[:space:]]*\[[^]]*(0\.0\.0\.0/0|::/0)'

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      hits=$((hits + 1))
      if [[ "$line" =~ $permissive_re ]]; then
        echo "permissive allowlist value in ${f}: ${line}"
        return 1
      fi
    done < <(grep -nE '0\.0\.0\.0/0|::/0' "$f" || true)
  done < <(find "$EDGE_MODULE" -name '*.tf' -type f; echo "${EDGE_MODULE}/README.md")

  # The scan must have seen something. If the literals vanished from the module
  # entirely, the loop above would pass without inspecting a single line -- and
  # so would it if the grep pattern were broken.
  [ "$hits" -gt 0 ] || { echo "scanned zero candidate lines; this guard is measuring nothing"; return 1; }

  # And prove the shape-matcher itself fires, against a known-bad line. Without
  # this, a typo in permissive_re would make every check above pass silently.
  local canary='  allowed_ipv4 = ["0.0.0.0/0"]'
  [[ "$canary" =~ $permissive_re ]] || { echo "permissive_re failed to match a known-bad line"; return 1; }
  local benign='  description = "never 0.0.0.0/0"'
  [[ "$benign" =~ $permissive_re ]] && { echo "permissive_re matches benign prose"; return 1; }

  # Inside tests/ the literals appear as deliberate negative inputs. Require the
  # file to prove that intent by also using expect_failures.
  while IFS= read -r f; do
    grep -qE '0\.0\.0\.0/0|::/0' "$f" || continue
    grep -q 'expect_failures' "$f" \
      || { echo "${f} contains a default-route literal but no expect_failures"; return 1; }
  done < <(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f)

  # And the shipped defaults are empty, which is the fail-closed state.
  grep -A6 'variable "allowed_ipv4"' "${EDGE_MODULE}/variables.tf" | grep -q 'default *= *\[\]'
  grep -A6 'variable "allowed_ipv6"' "${EDGE_MODULE}/variables.tf" | grep -q 'default *= *\[\]'
}

@test "no absolute /home path and no real project, domain or billing id" {
  local targets=("$EDGE_MODULE" "$FIXTURE_DIR" "${PROBE_DIR}/edge-probe-negative.sh" "${PROBE_DIR}/edge-probe-positive.sh" "${PROBE_DIR}/edge-probe-bypass.sh")
  run grep -rn --exclude-dir=.terraform '/home/[a-z]' "${targets[@]}"
  [ "$status" -ne 0 ] || { echo "absolute home path: ${output}"; return 1; }

  # Placeholders must actually be present, or "no real project id" is satisfied
  # by there being no project id at all.
  grep -q 'CHANGEME-project' "${EDGE_TESTS}/armor_posture.tftest.hcl"
  grep -q 'example.invalid' "${EDGE_TESTS}/tls_frontend.tftest.hcl"

  run grep -rn --exclude-dir=.terraform -E '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' "$EDGE_MODULE"
  [ "$status" -ne 0 ] || { echo "possible billing account id: ${output}"; return 1; }
}

@test "module documents that the allowlist is not authentication" {
  local readme="${EDGE_MODULE}/README.md"
  [ -f "$readme" ]
  grep -qi 'not authentication' "$readme"
  grep -qi 'OIDC' "$readme"
  grep -qi 'identity header' "$readme"
}

# ---------------------------------------------------------------------------
# Access mode -- whole-tree properties a plan cannot see
#
# terraform test proves the DEFAULT is iap and that each mode evaluates
# correctly. It cannot prove anything about files no plan reads: the committed
# tfvars examples, the documentation, or a future example set someone adds.
# ---------------------------------------------------------------------------

# True (exit 0) when a file selects an allowlist-authorising mode without
# supplying any allowlist to authorise with. Extracted into a function so the
# same matcher can be run against a known-bad canary below; a guard that has
# never been shown to fire is not a guard.
access_mode_violation() {
  local f="$1"
  grep -Eq '^[[:space:]]*access_mode[[:space:]]*=[[:space:]]*"(allowlist|iap_and_allowlist)"' "$f" || return 1
  # An allowlist mode needs a non-empty allowed_ipv4 or allowed_ipv6, or the
  # Cloud Armor default deny is the only rule and nothing can reach the app.
  grep -Eq '^[[:space:]]*allowed_ipv(4|6)[[:space:]]*=[[:space:]]*\[[[:space:]]*"' "$f" && return 1
  return 0
}

@test "no committed tfvars or example selects an allowlist mode with no allowlist" {
  # Existence before content. If the example set were deleted or renamed, the
  # loop below would inspect nothing and report success.
  local -a candidates
  mapfile -t candidates < <(find "${REPO_ROOT}/terraform" -type f -name '*.tfvars*' -not -path '*/.terraform/*' | sort)
  [ "${#candidates[@]}" -gt 0 ] || { echo "no tfvars files found under terraform/; this guard is measuring nothing"; return 1; }

  local f
  for f in "${candidates[@]}"; do
    if access_mode_violation "$f"; then
      echo "selects an allowlist mode with no non-empty allowlist: ${f}"
      return 1
    fi
  done

  # Prove the matcher fires. Without this, a typo in either grep would make
  # every file above pass silently -- and today no example sets access_mode at
  # all, so the loop is entirely satisfied by absence.
  local bad="${BATS_TEST_TMPDIR}/bad.tfvars"
  printf '%s\n' 'access_mode = "allowlist"' 'allowed_ipv4 = []' > "$bad"
  access_mode_violation "$bad" || { echo "matcher failed to flag a known-bad tfvars"; return 1; }

  local good="${BATS_TEST_TMPDIR}/good.tfvars"
  printf '%s\n' 'access_mode = "allowlist"' 'allowed_ipv4 = ["192.0.2.0/24"]' > "$good"
  access_mode_violation "$good" && { echo "matcher flagged a correctly-configured tfvars"; return 1; }

  local iap="${BATS_TEST_TMPDIR}/iap.tfvars"
  printf '%s\n' 'access_mode = "iap"' 'allowed_ipv4 = []' > "$iap"
  access_mode_violation "$iap" && { echo "matcher flagged iap mode, which needs no allowlist"; return 1; }
  return 0
}

@test "nothing in the tree grants IAP to allUsers or allAuthenticatedUsers" {
  # The single most dangerous value in this chunk. allAuthenticatedUsers reads
  # as a restriction and means any Google account on earth. The module variable
  # rejects it at plan time; this asserts no committed example, tfvars or doc
  # ever suggests it as a value in the first place.
  # Inside tests/ these literals appear as deliberate negative inputs, exactly
  # as 0.0.0.0/0 does above. Excluded here and required to prove their intent
  # with expect_failures at the bottom of this test.
  local member_re='(iap_members|member)[[:space:]]*=[[:space:]]*.*"?(allUsers|allAuthenticatedUsers)"?'
  local f line

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ $member_re ]]; then
      echo "grants IAP to a public principal: ${line}"
      return 1
    fi
  done < <(grep -rnE --exclude-dir=.terraform --exclude='*.tftest.hcl' \
    'allUsers|allAuthenticatedUsers' "${REPO_ROOT}/terraform" || true)

  # A tftest may name these values only to prove they are rejected.
  while IFS= read -r f; do
    grep -qE 'allUsers|allAuthenticatedUsers' "$f" || continue
    grep -q 'expect_failures' "$f" \
      || { echo "${f} names a public principal but has no expect_failures"; return 1; }
  done < <(find "$EDGE_TESTS" -name '*.tftest.hcl' -type f)

  # The literals must genuinely be present somewhere -- in the validation that
  # rejects them and in the documentation that explains why. If they vanished
  # entirely, this guard and the reader both lose the warning.
  grep -q 'allauthenticatedusers' "${EDGE_MODULE}/variables.tf" \
    || { echo "variables.tf no longer rejects allAuthenticatedUsers"; return 1; }

  # And prove the shape-matcher fires against a known-bad line.
  local canary='  iap_members = ["allAuthenticatedUsers"]'
  [[ "$canary" =~ $member_re ]] || { echo "member_re failed to match a known-bad line"; return 1; }
  local benign='  # allAuthenticatedUsers is not a restriction'
  [[ "$benign" =~ $member_re ]] && { echo "member_re matches explanatory prose"; return 1; }
  return 0
}

@test "the access-mode decision is documented in the module and in SECURITY.md" {
  local readme="${EDGE_MODULE}/README.md"
  local security="${REPO_ROOT}/terraform/SECURITY.md"
  [ -f "$readme" ]
  [ -f "$security" ]

  local m
  for m in iap allowlist iap_and_allowlist; do
    grep -q "$m" "$readme" || { echo "README does not document access mode ${m}"; return 1; }
  done

  # The claim that matters is not "IAP exists" but "allAuthenticatedUsers is not
  # a restriction". A reader who takes only that away is safe.
  grep -qi 'allAuthenticatedUsers' "$security" \
    || { echo "SECURITY.md does not mention allAuthenticatedUsers"; return 1; }
  grep -qi 'not a restriction' "$security" \
    || { echo "SECURITY.md does not state that allAuthenticatedUsers is not a restriction"; return 1; }
  grep -qi 'identity-aware proxy\|IAP' "$security" \
    || { echo "SECURITY.md has no IAP row"; return 1; }
}

@test "MUTATION: defaulting access_mode to allowlist turns the suite red" {
  # The central claim of this chunk is that the SAFE posture is what you get by
  # not thinking about it. That claim is only worth anything if flipping the
  # default is caught, so prove it can be.
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-default"
  stage_module "$dest"

  # Assert the edit actually applied. A sed whose pattern stops matching becomes
  # a silent no-op that re-runs the unmutated module and reports a green suite
  # as a passing mutation check.
  cp "${dest}/variables.tf" "${dest}/variables.tf.orig"
  sed -i 's/^  default     = "iap"$/  default     = "allowlist"/' "${dest}/variables.tf"
  ! diff -q "${dest}/variables.tf.orig" "${dest}/variables.tf" >/dev/null \
    || { echo "the default-flip mutation was a no-op; this check is measuring nothing"; return 1; }
  rm -f "${dest}/variables.tf.orig"

  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "a module defaulting to the weaker posture PASSED the suite"; return 1; }
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "default_access_mode_is_iap"\.\.\. fail' \
    || { echo "suite failed, but not on the default-posture assertion:"; echo "$output"; return 1; }
}

@test "MUTATION: dropping the allUsers guard turns the suite red" {
  # This check exists because the guard it protects was, briefly, untested. The
  # prefix rule in iap_members also rejects allUsers and allAuthenticatedUsers
  # (neither carries a "type:" prefix), so deleting the dedicated dangerous-value
  # validation left the suite entirely green -- the most dangerous guard in the
  # module had no test that could see it disappear.
  #
  # It is now independently falsifiable via a wildcard principalSet, which is
  # prefix-valid and therefore only that rule can reject. This proves it.
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-allusers"
  stage_module "$dest"

  # Delete the strcontains wildcard clause: the minimal edit that reopens the
  # hole while leaving the file syntactically valid.
  cp "${dest}/variables.tf" "${dest}/variables.tf.orig"
  sed -i '/&& !strcontains(m, "\*")/d' "${dest}/variables.tf"
  ! diff -q "${dest}/variables.tf.orig" "${dest}/variables.tf" >/dev/null \
    || { echo "the allUsers-guard mutation was a no-op; this check is measuring nothing"; return 1; }
  rm -f "${dest}/variables.tf.orig"

  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "a weakened dangerous-principal guard PASSED the suite"; return 1; }
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "rejects_a_wildcard_principalset"\.\.\. fail' \
    || { echo "suite failed, but not on the wildcard-principal assertion:"; echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# Mutation checks -- proof the tftest suite can go red
#
# Baseline-green first, every time. A mutation run that fails for an unrelated
# reason (a syntax error, a missing variable) is indistinguishable from the
# guard firing correctly, and that is the single most common way a suite like
# this ends up measuring nothing.
# ---------------------------------------------------------------------------

@test "BASELINE: the unmutated module passes terraform test in the staged copy" {
  [ -d "${EDGE_MODULE}/.terraform" ] \
    || { echo "provider schema absent: run 'terraform init -backend=false' in ${EDGE_MODULE}"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/baseline"
  stage_module "$dest"
  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -eq 0 ] || { echo "baseline is NOT green; every mutation check below is meaningless:"; echo "$output"; return 1; }
}

@test "MUTATION: default rule flipped to allow turns the suite red" {
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-allow"
  stage_module "$dest"
  cp "${FIXTURE_DIR}/armor-default-allow.tf.fixture" "${dest}/armor.tf"
  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "an open default rule PASSED the suite"; return 1; }
  [[ "$output" == *'run "default_rule_is_deny_403"'* ]]
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "default_rule_is_deny_403"\.\.\. fail' \
    || { echo "suite failed, but not on the default-deny assertion:"; echo "$output"; return 1; }
}

@test "MUTATION: deleting the default rule turns the suite red" {
  # The vacuous-pass case. A guard phrased as "no allow rule at 2147483647" is
  # satisfied by there being no rule at 2147483647 at all.
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-nodefault"
  stage_module "$dest"
  cp "${FIXTURE_DIR}/armor-no-default-rule.tf.fixture" "${dest}/armor.tf"
  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "a MISSING default rule PASSED the suite"; return 1; }
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "default_rule_is_deny_403"\.\.\. fail' \
    || { echo "suite failed, but not on the default-deny assertion:"; echo "$output"; return 1; }
}

@test "MUTATION: a rule left in preview = true turns the suite red" {
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-preview"
  stage_module "$dest"
  cp "${FIXTURE_DIR}/armor-preview-true.tf.fixture" "${dest}/armor.tf"
  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "a previewed (unenforced) rule PASSED the suite"; return 1; }
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "no_rule_is_left_in_preview"\.\.\. fail' \
    || { echo "suite failed, but not on the preview assertion:"; echo "$output"; return 1; }
}

@test "MUTATION: silently truncating the allowlist turns the suite red" {
  # The mutation that plans cleanly and looks entirely correct. Only the count
  # assertion catches it.
  [ -d "${EDGE_MODULE}/.terraform" ] || { echo "provider schema absent"; return 1; }
  local dest="${BATS_TEST_TMPDIR}/mut-truncate"
  stage_module "$dest"
  cp "${FIXTURE_DIR}/armor-truncated-allowlist.tf.fixture" "${dest}/armor.tf"
  run bash -c "cd '${dest}' && terraform test 2>&1"
  [ "$status" -ne 0 ] || { echo "a truncated allowlist PASSED the suite"; return 1; }
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'run "twenty_five_cidrs_survive_chunking_intact"\.\.\. fail' \
    || { echo "suite failed, but not on the chunking assertion:"; echo "$output"; return 1; }
}

@test "the real tree is byte-identical after the mutation checks" {
  # A mutation harness that leaked into the working tree would be worse than no
  # harness at all: it would rewrite the module under test and the next run
  # would validate the mutation.
  [ -f "${BATS_FILE_TMPDIR}/module.sha" ]
  run diff <(module_fingerprint) "${BATS_FILE_TMPDIR}/module.sha"
  [ "$status" -eq 0 ] || { echo "mutation checks modified the real module:"; echo "$output"; return 1; }
}
