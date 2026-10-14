#!/usr/bin/env bats
#
# terraform-v2-acceptance.bats -- the offline surface for scripts/gcp-tf/acceptance-v2.sh.
#
# The script under test only means anything against a running cloud, which is
# exactly why it needs a test that runs without one. The v2 estate is LIVE and
# billable; a suite that exercised it by deploying would be a suite nobody runs,
# and the first time anyone found out the IAP classification was wrong would be
# the evening it told an engineer to go and fix an IAM configuration that was
# already correct.
#
# So `gcloud` and `curl` are stubs on PATH whose every answer comes from a
# fixture, and the script cannot tell the difference. What is asserted here is
# behaviour: which verdict each estate produces, what the failure line names,
# and what happens when the cloud will not answer at all.
#
# Three rules govern the shape of this file:
#
#   1. EVERY NEGATIVE IS PAIRED WITH A POSITIVE. A script that always returned
#      FAIL would satisfy every "this estate fails" test in here. The compliant
#      run is what makes the negatives mean anything, and the compliant fixture
#      deliberately carries decoys -- a neighbouring VPC that is wide open, a
#      DISABLED world-open rule, a DENY rule sourced from 0.0.0.0/0, and
#      storage.admin held by somebody who is not the deploy identity -- so that
#      four separate over-broad implementations turn it red. One of those decoys
#      has already earned its keep: it caught a jq `//` that fired on an empty
#      stream and reported every compliant instance as having an external IP.
#
#   2. EXISTENCE BEFORE CONTENT. A grep that finds nothing because the file was
#      never written is a green test measuring nothing.
#
#   3. THE THREE IAP OUTCOMES MUST NEVER COLLAPSE INTO TWO. "denied" and
#      "authorised, nothing listening" have different owners. There is a test
#      below that compares the two runs against each other rather than against a
#      string, so an implementation that merges them cannot pass both.
#
# And the mutation checks at the end prove the assertions can fail at all.
#
# No network. No cloud credentials. No terraform. Runs in a few seconds.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export ACCEPT="${REPO_ROOT}/scripts/gcp-tf/acceptance-v2.sh"
  export FIXTURES="${REPO_ROOT}/test/fixtures/gcp-tf-v2"
  export HANDOFFS="${FIXTURES}/handoff"
  export F_COMPLIANT="${FIXTURES}/compliant"
  export H_GOOD="${FIXTURES}/handoff/demo-1.handoff.json"
}

setup() {
  # Presence first, always. Every test below is meaningless if these are not
  # here, and a missing script would otherwise present as a quiet failure to
  # match some string.
  [ -f "$ACCEPT" ]
  [ -d "$FIXTURES" ]
  [ -d "$F_COMPLIANT" ]
  [ -f "$H_GOOD" ]

  STUBDIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUBDIR"
  cp "${FIXTURES}/stub-gcloud.sh" "${STUBDIR}/gcloud"
  cp "${FIXTURES}/stub-curl.sh" "${STUBDIR}/curl"
  chmod +x "${STUBDIR}/gcloud" "${STUBDIR}/curl"

  CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"$CALL_LOG"
  export STUB_GCLOUD_LOG="$CALL_LOG"
  export PATH="${STUBDIR}:${PATH}"

  # Short, so the inconclusive-probe path does not cost 25 seconds per run.
  export IAP_PROBE_TIMEOUT=3

  # Every test declares its own estate; nothing is inherited.
  unset STUB_FIXTURE_OVERLAY STUB_GCLOUD_FAIL STUB_IAP_MODE STUB_CURL_CODE || true
  export STUB_FIXTURE_BASE="$F_COMPLIANT"
}

# This scenario's difference from the compliant estate. Splitting base from
# overlay is what keeps each negative to a single file.
overlay() {
  [ -d "${FIXTURES}/$1" ] || {
    echo "no such scenario: ${FIXTURES}/$1"
    return 1
  }
  export STUB_FIXTURE_OVERLAY="${FIXTURES}/$1"
}

# Count verdict lines of one kind in $output. ANCHORED: an unanchored match
# would also count the indented note lines beneath a verdict, and "N/A" needs no
# escaping because '/' carries no special meaning in a POSIX basic regex.
verdicts() {
  printf '%s\n' "$output" | grep -c "^$1 " || true
}

# The whole verdict line for one named check.
verdict_line() {
  printf '%s\n' "$output" | grep -E "^(PASS|FAIL|UNKNOWN) +$1 " | head -1
}

# Stage a copy of the script and apply one sed mutation to it. REFUSES to
# continue unless the mutation actually changed the file: a sed whose pattern no
# longer matches silently no-ops, the mutation check then runs against unmutated
# code and passes, and the result is a mutation check that can never fail -- the
# precise failure this whole section exists to detect.
mutate() {
  local src="$1" sed_program="$2" dest="$3"
  cp "$src" "$dest"
  sed -i "$sed_program" "$dest"
  chmod +x "$dest"
  if cmp -s "$src" "$dest"; then
    echo "MUTATION DID NOT APPLY: '${sed_program}' matched nothing in ${src}"
    echo "the mutation check below would have passed against unmutated code"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Existence, hygiene, and the interface
# ---------------------------------------------------------------------------

@test "the script exists and is executable" {
  [ -f "$ACCEPT" ] || { echo "missing ${ACCEPT}"; return 1; }
  [ -x "$ACCEPT" ] || { echo "not executable: ${ACCEPT}"; return 1; }
}

@test "the script is shellcheck-clean" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  run shellcheck "$ACCEPT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the stubs are shellcheck-clean too" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck is not installed"
  fi
  run shellcheck "${FIXTURES}/stub-gcloud.sh" "${FIXTURES}/stub-curl.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--help exits 0 and names the v2/v1 split" {
  run "$ACCEPT" --help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Usage: acceptance-v2.sh"* ]] || { echo "$output"; return 1; }
  # The help has to say which estate this is, or someone will point it at v1.
  [[ "$output" == *"v1"* ]] || { echo "help does not mention v1 at all"; echo "$output"; return 1; }
  [[ "$output" == *"legacy-v1.sh"* ]] || { echo "help does not name the v1 path"; echo "$output"; return 1; }
}

@test "an unknown argument is a usage error" {
  run "$ACCEPT" --wat
  [ "$status" -eq 2 ] || { echo "expected 2, got ${status}: ${output}"; return 1; }
}

@test "every fixture exists and is valid JSON, and every handoff is present" {
  local scenario
  for scenario in compliant external-ip open-firewall ssh-world-open \
    bucket-legacy-role bucket-storage-admin bucket-unprotected; do
    [ -d "${FIXTURES}/${scenario}" ] || { echo "missing scenario ${scenario}"; return 1; }
    local n
    n="$(find "${FIXTURES}/${scenario}" -name '*.json' -type f | wc -l)"
    [ "$n" -gt 0 ] || { echo "scenario ${scenario} holds no fixture"; return 1; }
  done

  local h
  for h in demo-1 v1-controlplane v1-region-only partial alternate-spellings \
    stale-ip allowlist-mode iap-and-allowlist bogus-access-mode emitter-shape \
    future-schema ci-lane demo-no-instance unknown-kind-no-instance malformed; do
    [ -f "${HANDOFFS}/${h}.handoff.json" ] || { echo "missing handoff ${h}"; return 1; }
  done

  # Every fixture parses, except the deliberate sentinels.
  local f
  while IFS= read -r f; do
    case "$f" in
      *malformed.handoff.json) continue ;;
    esac
    if head -c 15 "$f" | grep -q '__STUB_ERROR__'; then continue; fi
    jq -e . "$f" >/dev/null 2>&1 || { echo "not valid JSON: ${f}"; return 1; }
  done < <(find "$FIXTURES" -name '*.json' -type f)

  # And the malformed one really is malformed, or its test proves nothing.
  ! jq -e . "${HANDOFFS}/malformed.handoff.json" >/dev/null 2>&1 || {
    echo "malformed.handoff.json parses as JSON; its test is vacuous"
    return 1
  }
}

@test "no real project id, account or address is hardcoded in the script" {
  # Everything identifying comes from the handoff. The one deliberate exception
  # is the v1 marker list, which must name v1 to be able to refuse it -- so this
  # asserts the absence of v2 identifiers, which have no business being here at
  # all.
  local forbidden
  for forbidden in "sl-port-over-sandbox" "sublimino@gmail.com" "sl-tf-deploy@"; do
    ! grep -q -- "$forbidden" "$ACCEPT" || {
      echo "the script hardcodes '${forbidden}'; it must come from the handoff"
      grep -n -- "$forbidden" "$ACCEPT"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# The positive. Everything below depends on this being green.
# ---------------------------------------------------------------------------

@test "a compliant estate is all PASS and exits 0" {
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "$output"; return 1; }
  # Every control the brief names has to actually be present in the report. A
  # run with three checks would otherwise be "all PASS" too.
  [ "$(verdicts PASS)" -ge 14 ] || { echo "only $(verdicts PASS) PASS lines"; echo "$output"; return 1; }
  local item
  for item in "instance RUNNING" "no external IP" "Shielded VM" "OS Login enforced" \
    "runtime service account" "handoff describes this estate" "no 0.0.0.0/0 ingress" \
    "SSH only from IAP range" "access mode authenticates" "IAP tunnel authorises" \
    "app port responds" "state bucket protection" "deploy SA: objectAdmin only" \
    "SSH path via IAP tunnel"; do
    [[ "$output" == *"$item"* ]] || { echo "no check reported for: ${item}"; return 1; }
  done
}

@test "the compliant decoys do not turn any check red" {
  # Named explicitly so that a future edit widening one of these checks fails
  # HERE, with a message about the decoy, rather than somewhere less obvious.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # A wide-open neighbouring VPC the instance is not attached to.
  [[ "$output" != *"sl-demo-9"* ]] || { echo "a rule from another VPC was graded"; echo "$output"; return 1; }
  # A DISABLED world-open rule, and a DENY rule sourced from 0.0.0.0/0.
  [[ "$output" != *"sl-demo-1-disabled-debug-open"* ]] || { echo "a disabled rule was graded"; echo "$output"; return 1; }
  [[ "$output" != *"sl-demo-1-deny-all-ingress"* ]] || { echo "a deny rule was graded as an allow"; echo "$output"; return 1; }
  # storage.admin held by a group that is not the deploy identity.
  [[ "$output" == *"PASS    deploy SA: objectAdmin only"* ]] || { echo "$output"; return 1; }
}

@test "the emitter's exact shape is consumed with no verdicts lost" {
  # The literal shape make gcp-tf-handoff writes: project_id, environment_key
  # AND env, instance_name, app_port as a JSON number, plus state_prefix,
  # schema_version and generated_at which this script does not read. Extra
  # fields must be ignored, not fatal.
  run "$ACCEPT" --handoff "${HANDOFFS}/emitter-shape.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts PASS)" -ge 14 ] || { echo "only $(verdicts PASS) PASS lines"; echo "$output"; return 1; }
  # The hostname it carries is reported rather than dropped.
  [[ "$output" == *"demo-1.example.invalid"* ]] || { echo "hostname was not surfaced"; echo "$output"; return 1; }
}

@test "an unknown schema is announced but still graded field by field" {
  # The emitter bumps schema and schema_version together on a breaking change.
  # A newer schema must produce an honest report, not a refusal and not a
  # silent wrong one -- the field reader already degrades to UNKNOWN on
  # anything it cannot resolve.
  run "$ACCEPT" --handoff "${HANDOFFS}/future-schema.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"does not know"* ]] || { echo "an unknown schema was not announced"; echo "$output"; return 1; }
  [ "$(verdicts PASS)" -ge 14 ] || { echo "$output"; return 1; }

  # And a known schema says nothing about it.
  run "$ACCEPT" --handoff "${HANDOFFS}/emitter-shape.handoff.json"
  [[ "$output" != *"does not know"* ]] || { echo "a known schema was announced anyway"; echo "$output"; return 1; }
}

@test "the alternate handoff spellings produce the same verdicts as the canonical one" {
  # The emitter is a sibling component. A rename there must degrade gracefully,
  # and this pins that the fallback chain actually works rather than silently
  # yielding empty strings and a page of UNKNOWNs.
  run "$ACCEPT" --handoff "${HANDOFFS}/alternate-spellings.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts PASS)" -ge 13 ] || { echo "only $(verdicts PASS) PASS lines"; echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The negatives, each paired with the positive above
# ---------------------------------------------------------------------------

@test "an instance with an external IP FAILs and names the instance" {
  overlay external-ip
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    no external IP"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-vm"* ]] || { echo "the failure does not name the instance"; echo "$output"; return 1; }
  [[ "$output" == *"203.0.113.47"* ]] || { echo "the failure does not name the address"; echo "$output"; return 1; }
  # Only that check moved.
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "a 0.0.0.0/0 firewall allow FAILs and names the rule" {
  overlay open-firewall
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    no 0.0.0.0/0 ingress"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-temporary-debug-open"* ]] || { echo "the failure does not name the rule"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "an EGRESS rule to 0.0.0.0/0 is expected and does NOT fail" {
  # Direction is load-bearing and the estate now depends on it. Platform egress
  # is deliberately open: an egress-only allow, TCP 443, 0.0.0.0/0, scoped by
  # target_service_accounts to the runtime SA. Ingress is unchanged --
  # deny-all-ingress from 0.0.0.0/0 still stands, IAP SSH only, no external IP.
  #
  # A check that ignored direction would report a false FAIL on a healthy
  # estate, which is worse than having no check: the next real finding gets
  # read as another false alarm.
  overlay egress-open-443
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "an open EGRESS rule was graded as a violation"; echo "$output"; return 1; }
  [[ "$output" == *"PASS    no 0.0.0.0/0 ingress"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"sl-demo-1-allow-egress-https"* ]] || {
    echo "the egress rule was named in a finding"
    echo "$output"
    return 1
  }

  # The paired negative, on the same fixture shape: flip it to INGRESS and it
  # must fail. Same rule, same ranges, opposite direction, opposite verdict.
  overlay open-firewall
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "an open INGRESS rule was not graded as a violation"; echo "$output"; return 1; }
}

@test "a tcp rule with NO ports named is treated as covering 22" {
  # The case a naive 'does any rule list port 22' check walks straight past: no
  # ports means every port, so it means 22, and its source is not the IAP range.
  overlay ssh-world-open
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    SSH only from IAP range"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-allow-all-tcp-no-ports"* ]] || { echo "$output"; return 1; }
}

@test "a legacy bucket role on the deploy SA FAILs" {
  overlay bucket-legacy-role
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    deploy SA: objectAdmin only"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"legacyBucketOwner"* ]] || { echo "the failure does not name the role"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "storage.admin on the deploy SA FAILs" {
  overlay bucket-storage-admin
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    deploy SA: objectAdmin only"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"roles/storage.admin"* ]] || { echo "the failure does not name the role"; echo "$output"; return 1; }
  [[ "$output" == *"DELETE the bucket"* ]] || { echo "the failure does not say why it matters"; echo "$output"; return 1; }
}

@test "an unprotected state bucket FAILs and names each missing control" {
  overlay bucket-unprotected
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    state bucket protection"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"versioning=false"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"public_access_prevention=inherited"* ]] || { echo "$output"; return 1; }
}

@test "a stale handoff FAILs rather than confidently grading the wrong machine" {
  run "$ACCEPT" --handoff "${HANDOFFS}/stale-ip.handoff.json"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    handoff describes this estate"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"make gcp-tf-handoff"* ]] || { echo "the failure does not say how to fix it"; echo "$output"; return 1; }
}

@test "access_mode allowlist-only FAILs, citing the allowlist threat" {
  run "$ACCEPT" --handoff "${HANDOFFS}/allowlist-mode.handoff.json"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    access mode authenticates"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"SECURITY.md #5"* ]] || { echo "$output"; return 1; }

  # Paired positive: the canonical handoff passes the same check, so a script
  # that always failed it would not satisfy both.
  run "$ACCEPT" --handoff "$H_GOOD"
  [[ "$output" == *"PASS    access mode authenticates"* ]] || { echo "$output"; return 1; }
}

@test "access_mode is a THREE-valued enum: iap_and_allowlist is the strongest, not a failure" {
  # terraform/environments/variables.tf validates exactly iap | allowlist |
  # iap_and_allowlist, and its own description calls the combined mode the
  # strongest posture. An earlier revision here treated access_mode as an
  # either/or switch and FAILED iap_and_allowlist -- so the best-configured
  # estate would have been the one that failed. Caught in review by the agent
  # that owns the emitter.
  run "$ACCEPT" --handoff "${HANDOFFS}/iap-and-allowlist.handoff.json"
  [ "$status" -eq 0 ] || { echo "expected 0, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"PASS    access mode authenticates"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"strongest posture"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
}

@test "an unrecognised access_mode is UNKNOWN, never a guess in either direction" {
  # Drift between this script and the terraform enum must not silently resolve
  # to PASS (which would hide a bad posture) or to FAIL (which would block a
  # good one). --strict still stops the run.
  run "$ACCEPT" --handoff "${HANDOFFS}/bogus-access-mode.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"UNKNOWN access mode authenticates"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"iap, allowlist, iap_and_allowlist"* ]] || { echo "$output"; return 1; }

  run "$ACCEPT" --handoff "${HANDOFFS}/bogus-access-mode.handoff.json" --strict
  [ "$status" -eq 3 ] || { echo "expected 3 under --strict, got ${status}"; echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The IAP three-way. The distinction this script exists to draw.
# ---------------------------------------------------------------------------

@test "IAP permission denied FAILs and says it is an IAM problem" {
  export STUB_IAP_MODE=denied
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    IAP tunnel authorises"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"PERMISSION DENIED"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IAM problem"* ]] || { echo "$output"; return 1; }
  # The app port was not graded, because it could not be: the tunnel never
  # opened. Blaming the app here would be the second wrong answer in a row.
  [[ "$output" == *"UNKNOWN app port responds"* ]] || { echo "$output"; return 1; }
}

@test "IAP authorised with nothing listening PASSes the authorisation check" {
  # The state the live demo-1 environment is in today. Authorisation is correct;
  # the application is not running. Reporting this as denied sends an engineer
  # to argue with an IAM configuration that is already right.
  export STUB_IAP_MODE=no-listener
  run "$ACCEPT" --handoff "$H_GOOD"
  [[ "$output" == *"PASS    IAP tunnel authorises"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"AUTHORISED"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"DEPLOY problem, not an access problem"* ]] || { echo "$output"; return 1; }
  # And it must NOT claim permission was denied.
  [[ "$output" != *"PERMISSION DENIED"* ]] || { echo "authorised-but-closed was reported as denied"; echo "$output"; return 1; }
}

@test "denied and authorised-but-closed are DIFFERENT verdicts on the same check" {
  # Asserted by comparing the two runs against EACH OTHER rather than against a
  # string. An implementation that collapsed the two into one verdict would
  # satisfy both tests above if they were written only as substring matches, and
  # it cannot satisfy this one.
  export STUB_IAP_MODE=denied
  run "$ACCEPT" --handoff "$H_GOOD"
  local denied_line
  denied_line="$(verdict_line 'IAP tunnel authorises')"
  [ -n "$denied_line" ] || { echo "no verdict line for the tunnel check"; echo "$output"; return 1; }

  export STUB_IAP_MODE=no-listener
  run "$ACCEPT" --handoff "$H_GOOD"
  local closed_line
  closed_line="$(verdict_line 'IAP tunnel authorises')"
  [ -n "$closed_line" ] || { echo "no verdict line for the tunnel check"; echo "$output"; return 1; }

  [ "$denied_line" != "$closed_line" ] || {
    echo "the two IAP outcomes produced an IDENTICAL verdict line:"
    echo "  ${denied_line}"
    echo "they have different owners and must never be conflated"
    return 1
  }
  # And specifically: one is a FAIL and the other is not.
  [[ "$denied_line" == FAIL* ]] || { echo "denied was not a FAIL: ${denied_line}"; return 1; }
  [[ "$closed_line" != FAIL* ]] || { echo "authorised-but-closed was a FAIL: ${closed_line}"; return 1; }
}

@test "a tunnel probe that says nothing at all is UNKNOWN, not a verdict" {
  export STUB_IAP_MODE=silent
  run "$ACCEPT" --handoff "$H_GOOD"
  [[ "$output" == *"UNKNOWN IAP tunnel authorises"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"neither authorised nor denied"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"PERMISSION DENIED"* ]] || { echo "silence was read as a denial"; echo "$output"; return 1; }
}

@test "an app that answers 5xx through an open tunnel FAILs as an app problem" {
  export STUB_CURL_CODE=503
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    app port responds"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"HTTP 503"* ]] || { echo "$output"; return 1; }
  # The tunnel itself is fine and must still say so.
  [[ "$output" == *"PASS    IAP tunnel authorises"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# Ignorance is reported as ignorance
# ---------------------------------------------------------------------------

@test "a gcloud that errors reports UNKNOWN, never FAIL, and exits 0" {
  export STUB_GCLOUD_FAIL=1
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "expected exit 0 on could-not-look, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "could-not-look was reported as a failure"; echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -ge 8 ] || { echo "$output"; return 1; }
  # access mode is read from the handoff, not the cloud, so it still passes --
  # which is correct and worth pinning: a blackout must not erase what is known.
  [[ "$output" == *"PASS    access mode authenticates"* ]] || { echo "$output"; return 1; }
}

@test "the SSH path names the OS Login gap as its own condition" {
  # Two things are called "SSH access" and they fail independently: the IAP TCP
  # tunnel to port 22, and OS Login authorisation, which `gcloud compute ssh`
  # additionally needs. The live estate is in the state where the tunnel works
  # and `compute ssh` does not, because the calling identity is external to the
  # org and roles/compute.osLoginExternalUser is an ORG-scoped grant.
  #
  # Reported generically, that reads as a broken VM or a broken tunnel and is
  # neither. The named condition is what sends the reader to the right layer.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PASS    SSH path via IAP tunnel"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"osLoginExternalUser"* ]] || {
    echo "the OS Login grant is not named anywhere"
    echo "$output"
    return 1
  }
  [[ "$output" == *"ORG-scoped"* ]] || { echo "the report does not say the grant is org-scoped"; echo "$output"; return 1; }
}

@test "the SSH path never invokes gcloud compute ssh" {
  # It is a mutating verb, both gates refuse it, and it would fail here for a
  # reason that has nothing to do with the estate's posture.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$CALL_LOG" ] || { echo "no calls recorded"; return 1; }
  ! grep -qE '(^| )compute ssh( |$)' "$CALL_LOG" || {
    echo "gcloud compute ssh was invoked:"
    grep -E 'compute ssh' "$CALL_LOG"
    return 1
  }
  # It probed port 22 through the tunnel instead.
  grep -qE 'start-iap-tunnel .* 22( |$)' "$CALL_LOG" || {
    echo "port 22 was never probed through the tunnel:"
    cat "$CALL_LOG"
    return 1
  }
}

@test "SSH denied and SSH with no sshd are different from each other" {
  # The same three-way discrimination as the app port, on the port that matters
  # for operator access.
  export STUB_IAP_MODE=denied
  run "$ACCEPT" --handoff "$H_GOOD"
  local denied_line
  denied_line="$(verdict_line 'SSH path via IAP tunnel')"
  [[ "$denied_line" == FAIL* ]] || { echo "denied was not a FAIL: ${denied_line}"; return 1; }
  [[ "$output" == *"never reached sshd"* ]] || { echo "$output"; return 1; }

  export STUB_IAP_MODE=no-listener
  run "$ACCEPT" --handoff "$H_GOOD"
  local closed_line
  closed_line="$(verdict_line 'SSH path via IAP tunnel')"
  [ "$denied_line" != "$closed_line" ] || {
    echo "the two SSH outcomes produced an IDENTICAL verdict line: ${denied_line}"
    return 1
  }
  [[ "$output" == *"sshd is not running"* ]] || { echo "$output"; return 1; }
}

@test "the tunnel is torn down; no probe process survives the run" {
  # Regression guard. The first implementation killed only the backgrounded
  # wrapper, and the stub's child -- standing in for the real tunnel, which is
  # also a child of the gcloud wrapper -- outlived every run. It cost the suite
  # two minutes of wall clock, and in production it would have leaked a live IAP
  # tunnel per invocation.
  local pidfile="${BATS_TEST_TMPDIR}/tunnel.pid"
  export STUB_IAP_PIDFILE="$pidfile"

  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # Existence before content: if the stub never recorded a PID, the assertion
  # below would be vacuously true. A run opens TWO tunnels -- the application
  # port and port 22 -- and both must be gone, so the count is asserted too.
  [ -s "$pidfile" ] || { echo "the tunnel stub never recorded its PID; this test proves nothing"; return 1; }
  local n
  n="$(grep -c . "$pidfile")"
  [ "$n" -ge 2 ] || { echo "expected at least 2 tunnels to have been opened, saw ${n}"; return 1; }

  local pid waited survivors=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    waited=0
    while [ "$waited" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      survivors+=("$pid")
      kill -9 "$pid" 2>/dev/null || true
    fi
  done <"$pidfile"

  if [ "${#survivors[@]}" -ne 0 ]; then
    echo "tunnel process(es) survived the run: ${survivors[*]}"
    return 1
  fi
}

@test "a tunnel denial under a total blackout is UNKNOWN, not an IAP verdict" {
  # The discrimination is the point, and it is the same shape teardown-verify.sh
  # draws around a missing state bucket: the identical failed call means
  # opposite things depending on whether anything else in the run answered.
  #
  # gcloud says PERMISSION_DENIED to everything when a token has expired. A
  # classifier that keys on that text alone reports "IAP refuses you", and the
  # reader goes and audits an IAM configuration that was never broken. This
  # suite caught exactly that on the first run.
  export STUB_GCLOUD_FAIL=1
  run "$ACCEPT" --handoff "$H_GOOD"
  local blackout_line
  blackout_line="$(verdict_line 'IAP tunnel authorises')"
  [[ "$blackout_line" == UNKNOWN* ]] || {
    echo "a blackout produced a verdict on IAP: ${blackout_line}"
    return 1
  }
  [[ "$output" == *"so was every other read in this run"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"PERMISSION DENIED tunnelling"* ]] || {
    echo "a credential failure was reported as an IAP denial"
    echo "$output"
    return 1
  }

  # The pair. Same tunnel denial, but the rest of the cloud answers normally, so
  # now it IS evidence about IAP and must be a FAIL.
  unset STUB_GCLOUD_FAIL
  export STUB_IAP_MODE=denied
  run "$ACCEPT" --handoff "$H_GOOD"
  local real_line
  real_line="$(verdict_line 'IAP tunnel authorises')"
  [[ "$real_line" == FAIL* ]] || {
    echo "a genuine IAP denial was not a FAIL: ${real_line}"
    return 1
  }
}

@test "a CI lane reports N/A, not UNKNOWN, and PASSES --strict" {
  # kind=ci has no compute module, so it has no instance and no app port. That
  # is the environment working as designed, not a gap in the report.
  #
  # This is the bug the field prevents, and it is a real one: folding "nothing
  # to check" into UNKNOWN means --strict exits 3 on a perfectly correct CI
  # hand-off, so a CI lane could NEVER pass a strict run. Caught by the agent
  # that owns the emitter, who added `kind` specifically so this is decidable.
  run "$ACCEPT" --handoff "${HANDOFFS}/ci-lane.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "a CI lane produced UNKNOWNs"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts 'N/A')" -ge 8 ] || { echo "only $(verdicts 'N/A') N/A lines"; echo "$output"; return 1; }
  [[ "$output" == *"by design"* ]] || { echo "$output"; return 1; }

  # The checks that ARE meaningful for a CI lane still ran and still passed.
  # Without this the test would be satisfied by a script that N/A'd everything.
  [[ "$output" == *"PASS    state bucket protection"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"PASS    deploy SA: objectAdmin only"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"PASS    access mode authenticates"* ]] || { echo "$output"; return 1; }

  # The whole point: strict must not trip on N/A.
  run "$ACCEPT" --handoff "${HANDOFFS}/ci-lane.handoff.json" --strict
  [ "$status" -eq 0 ] || {
    echo "--strict rejected a correct CI hand-off (status ${status})"
    echo "$output"
    return 1
  }
}

@test "N/A is fail-closed: a demo lane with blank instance fields is UNKNOWN" {
  # The dangerous shape. If the lenient branch keyed on 'instance is empty'
  # rather than on kind, a demo environment handed over with two blanks would be
  # waved through as 'nothing to see here' -- silently not grading the instance
  # that is supposed to exist.
  run "$ACCEPT" --handoff "${HANDOFFS}/demo-no-instance.handoff.json"
  [ "$(verdicts 'N/A')" -eq 0 ] || {
    echo "a DEMO lane with no instance was treated as not-applicable"
    echo "$output"
    return 1
  }
  [ "$(verdicts UNKNOWN)" -ge 8 ] || { echo "$output"; return 1; }
  [[ "$output" == *"kind=demo, which is expected to have an instance"* ]] || { echo "$output"; return 1; }

  # And --strict does trip on it, unlike the CI lane above.
  run "$ACCEPT" --handoff "${HANDOFFS}/demo-no-instance.handoff.json" --strict
  [ "$status" -eq 3 ] || { echo "expected 3, got ${status}"; echo "$output"; return 1; }
}

@test "N/A is fail-closed: an unrecognised kind takes the STRICT path" {
  # Only the exact string "ci" is lenient. A kind this script has never heard of
  # must land on the strict side -- the unexpected case must never be the
  # permissive one.
  run "$ACCEPT" --handoff "${HANDOFFS}/unknown-kind-no-instance.handoff.json"
  [ "$(verdicts 'N/A')" -eq 0 ] || {
    echo "an unrecognised kind was treated as not-applicable"
    echo "$output"
    return 1
  }
  [ "$(verdicts UNKNOWN)" -ge 8 ] || { echo "$output"; return 1; }
  [[ "$output" == *"kind=staging, which is expected to have an instance"* ]] || { echo "$output"; return 1; }
}

@test "a demo lane WITH an instance is unaffected by the kind field" {
  # The paired positive for all three tests above: kind=demo grades normally.
  run "$ACCEPT" --handoff "${HANDOFFS}/emitter-shape.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts 'N/A')" -eq 0 ] || { echo "a full demo lane produced N/A lines"; echo "$output"; return 1; }
  [ "$(verdicts PASS)" -ge 14 ] || { echo "$output"; return 1; }
}

@test "a handoff missing most keys reports UNKNOWN rather than guessing a name" {
  # The failure this prevents: reconstructing 'sl-<env>-vm' from a convention,
  # describing a resource that does not exist, and reporting the absence as a
  # clean estate.
  run "$ACCEPT" --handoff "${HANDOFFS}/partial.handoff.json"
  [ "$status" -eq 0 ] || { echo "expected exit 0, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -ge 4 ] || { echo "$output"; return 1; }
  [[ "$output" == *"UNKNOWN state bucket protection"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"UNKNOWN deploy SA: objectAdmin only"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"handoff carries no"* ]] || { echo "$output"; return 1; }
}

@test "--strict exits 3 when nothing failed but something was unchecked" {
  run "$ACCEPT" --handoff "${HANDOFFS}/partial.handoff.json" --strict
  [ "$status" -eq 3 ] || { echo "expected 3, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }

  # And without --strict the same estate exits 0.
  run "$ACCEPT" --handoff "${HANDOFFS}/partial.handoff.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # And --strict does NOT change a clean run.
  run "$ACCEPT" --handoff "$H_GOOD" --strict
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The handoff contract
# ---------------------------------------------------------------------------

@test "a missing handoff names 'make gcp-tf-handoff' and exits 5" {
  run "$ACCEPT" --handoff "${BATS_TEST_TMPDIR}/does-not-exist.json"
  [ "$status" -eq 5 ] || { echo "expected 5, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"make gcp-tf-handoff"* ]] || { echo "the message does not name the generator"; echo "$output"; return 1; }
  [[ "$output" == *"no handoff file at"* ]] || { echo "$output"; return 1; }
}

@test "the default handoff path is derived from --env" {
  run "$ACCEPT" --env some-unbuilt-env
  [ "$status" -eq 5 ] || { echo "expected 5, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"deploy/gcp/some-unbuilt-env.handoff.json"* ]] || {
    echo "the default path was not derived from --env"
    echo "$output"
    return 1
  }
}

@test "a handoff that is not JSON exits 5 rather than grading an empty estate" {
  run "$ACCEPT" --handoff "${HANDOFFS}/malformed.handoff.json"
  [ "$status" -eq 5 ] || { echo "expected 5, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"not valid JSON"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The v1 refusal
# ---------------------------------------------------------------------------

@test "a v1-shaped handoff is REFUSED, not graded" {
  run "$ACCEPT" --handoff "${HANDOFFS}/v1-controlplane.handoff.json"
  [ "$status" -eq 4 ] || { echo "expected exit 4, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"REFUSING TO RUN"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"legacy-v1-project"* ]] || { echo "the refusal does not name what it saw"; echo "$output"; return 1; }
  [[ "$output" == *"v2 acceptance suite"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"scripts/gcp-tf/legacy-v1.sh"* ]] || { echo "the refusal does not point at the v1 path"; echo "$output"; return 1; }
  # Nothing was checked. A refusal that had already made cloud calls would be a
  # refusal in name only.
  [ ! -s "$CALL_LOG" ] || { echo "cloud calls were made before refusing:"; cat "$CALL_LOG"; return 1; }
}

@test "a single v1 marker anywhere in the handoff is enough to refuse" {
  # Everything else in this file is a valid v2 environment; only the region is
  # v1. Grading it would produce a page of UNKNOWNs that reads as 'the estate is
  # down' rather than 'you pointed at the wrong estate'.
  run "$ACCEPT" --handoff "${HANDOFFS}/v1-region-only.handoff.json"
  [ "$status" -eq 4 ] || { echo "expected exit 4, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"europe-west2"* ]] || { echo "$output"; return 1; }
}

@test "a v1 marker on the command line is refused before anything is read" {
  local marker
  for marker in "legacy-v1-project" "legacy-v1-vm" "legacy-v1-vm-2" "andy@control-plane.io" "europe-west2"; do
    run "$ACCEPT" --env "$marker"
    [ "$status" -eq 4 ] || {
      echo "marker '${marker}' on the command line was not refused (status ${status})"
      echo "$output"
      return 1
    }
    [[ "$output" == *"REFUSING TO RUN"* ]] || { echo "$output"; return 1; }
  done
  [ ! -s "$CALL_LOG" ] || { echo "cloud calls were made before refusing"; return 1; }
}

@test "a legitimate v2 handoff is NOT refused" {
  # The paired positive. A guard that refused everything would satisfy every
  # test above.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"REFUSING TO RUN"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The read-only guard
# ---------------------------------------------------------------------------

@test "the script refuses a mutating gcloud call" {
  run bash -c "source '${ACCEPT}'; gcloud_ro compute instances delete sl-demo-1-vm"
  [ "$status" -eq 2 ] || { echo "a delete was not refused (status ${status})"; echo "$output"; return 1; }
  [[ "$output" == *"refusing to run a non-read-only gcloud call"* ]] || { echo "$output"; return 1; }

  run bash -c "source '${ACCEPT}'; gcloud_ro storage buckets set-iam-policy gs://b p.json"
  [ "$status" -eq 2 ] || { echo "set-iam-policy was not refused"; echo "$output"; return 1; }

  run bash -c "source '${ACCEPT}'; gcloud_ro compute instances create x"
  [ "$status" -eq 2 ] || { echo "create was not refused"; echo "$output"; return 1; }

  # Paired positive: the reads it legitimately needs are permitted.
  run bash -c "source '${ACCEPT}'; GCLOUD_BIN=true gcloud_ro compute instances describe x"
  [ "$status" -eq 0 ] || { echo "describe was refused: ${output}"; return 1; }
  run bash -c "source '${ACCEPT}'; GCLOUD_BIN=true gcloud_ro storage buckets get-iam-policy gs://b"
  [ "$status" -eq 0 ] || { echo "get-iam-policy was refused: ${output}"; return 1; }
}

@test "the tunnel gate accepts start-iap-tunnel and nothing else" {
  # The one deliberate widening is quarantined in its own function. If it ever
  # grows a second verb, that is a decision someone should have to make here.
  run bash -c "source '${ACCEPT}'; gcloud_tunnel_probe compute ssh sl-demo-1-vm"
  [ "$status" -eq 2 ] || { echo "compute ssh went through the tunnel gate"; echo "$output"; return 1; }
  run bash -c "source '${ACCEPT}'; gcloud_tunnel_probe compute instances delete x"
  [ "$status" -eq 2 ] || { echo "a delete went through the tunnel gate"; echo "$output"; return 1; }

  run bash -c "source '${ACCEPT}'; GCLOUD_BIN=true gcloud_tunnel_probe compute start-iap-tunnel vm 8080"
  [ "$status" -eq 0 ] || { echo "the probe itself was refused: ${output}"; return 1; }
}

@test "every gcloud call an actual run makes is read-only" {
  # An assertion about what RAN, not about what the source appears to do. The
  # allowlist could be correct and a call could still be built somewhere that
  # never passes through it.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$CALL_LOG" ] || { echo "no gcloud calls were recorded at all"; return 1; }

  local line
  while IFS= read -r line; do
    case " ${line} " in
      *' describe '* | *' list '* | *' version '* | *' get-iam-policy '* | *' start-iap-tunnel '*) ;;
      *)
        echo "a non-read-only gcloud call was made: ${line}"
        return 1
        ;;
    esac
    # Belt and braces: no mutating verb may appear anywhere in any call.
    case " ${line} " in
      *' create '* | *' delete '* | *' update '* | *' set-iam-policy '* | *' add-iam-policy-binding '* | *' ssh '*)
        echo "a mutating verb appeared in a call: ${line}"
        return 1
        ;;
    esac
  done <"$CALL_LOG"
}

@test "no absence check delegates its filtering to a server-side --filter" {
  # A mistyped --filter returns an empty list; an empty list is exactly what
  # 'clean' looks like; the report then goes green on a question it never asked.
  # Filtering happens in the script, where it is visible and where these tests
  # can reach it.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$CALL_LOG" ] || { echo "no calls recorded"; return 1; }
  ! grep -q -- '--filter' "$CALL_LOG" || {
    echo "a server-side --filter was used:"
    grep -- '--filter' "$CALL_LOG"
    return 1
  }
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS -- proof that the assertions above can fail
# ---------------------------------------------------------------------------
#
# Each one stages a copy of the script, breaks exactly one control, and asserts
# that the estate which SHOULD fail now passes. A green suite proves nothing
# about a test that could not have gone red.

@test "MUTATION: collapsing the IAP three-way makes denied and closed identical" {
  # The single most valuable guard in this file. If the classifier is ever
  # rewritten so that any tunnel error is 'denied', this is what notices.
  local broken="${BATS_TEST_TMPDIR}/acceptance-iap.sh"
  mutate "$ACCEPT" \
    "s/IAP_VERDICT=\"authorised-no-listener\"/IAP_VERDICT=\"denied\"/" \
    "$broken"

  export STUB_IAP_MODE=no-listener
  run "$broken" --handoff "$H_GOOD"
  [[ "$output" == *"PERMISSION DENIED"* ]] || {
    echo "the mutation did not reach the classifier; this check is measuring nothing"
    echo "$output"
    return 1
  }

  # And the real script still tells them apart.
  run "$ACCEPT" --handoff "$H_GOOD"
  [[ "$output" == *"AUTHORISED"* ]] || { echo "the real script must still distinguish them"; echo "$output"; return 1; }
  [[ "$output" != *"PERMISSION DENIED"* ]] || { echo "$output"; return 1; }
}

@test "MUTATION: widening the read-only allowlist lets a delete through" {
  local broken="${BATS_TEST_TMPDIR}/acceptance-guard.sh"
  mutate "$ACCEPT" \
    "s/    \*' describe '\* | \*' list '\* | \*' version '\*) ;;/    *) ;;/" \
    "$broken"

  run bash -c "source '${broken}'; GCLOUD_BIN=true gcloud_ro compute instances delete x 2>/dev/null || true"
  [[ "$output" != *"refusing to run a non-read-only gcloud call"* ]] || {
    echo "the guard still refused; the mutation did not reach it"
    echo "$output"
    return 1
  }

  run bash -c "source '${ACCEPT}'; gcloud_ro compute instances delete x"
  [ "$status" -eq 2 ] || { echo "the real guard must still refuse"; echo "$output"; return 1; }
}

@test "MUTATION: accepting storage.admin on the deploy SA hides a bucket-deleter" {
  local broken="${BATS_TEST_TMPDIR}/acceptance-roles.sh"
  mutate "$ACCEPT" \
    's|^      roles/storage.admin)$|      roles/storage.admin) has_object_admin="yes" ;;\n      __never_matches__)|' \
    "$broken"

  overlay bucket-storage-admin
  run "$broken" --handoff "$H_GOOD"
  [ "$status" -eq 0 ] || { echo "mutation did not defeat the check; it may be asserted elsewhere"; echo "$output"; return 1; }

  # And the real script still catches it.
  run "$ACCEPT" --handoff "$H_GOOD"
  [ "$status" -eq 1 ] || { echo "the real script must still catch it"; echo "$output"; return 1; }
}

@test "MUTATION: dropping the blackout discrimination blames IAP for an expired token" {
  local broken="${BATS_TEST_TMPDIR}/acceptance-blackout.sh"
  mutate "$ACCEPT" 's/if \[ "\$CLOUD_READS_OK" -eq 0 \]; then/if false; then/' "$broken"

  export STUB_GCLOUD_FAIL=1
  run "$broken" --handoff "$H_GOOD"
  [[ "$output" == *"PERMISSION DENIED tunnelling"* ]] || {
    echo "the mutation did not reach the discrimination; this check measures nothing"
    echo "$output"
    return 1
  }

  # And the real script still reports ignorance as ignorance.
  run "$ACCEPT" --handoff "$H_GOOD"
  [[ "$output" != *"PERMISSION DENIED tunnelling"* ]] || { echo "$output"; return 1; }
  [ "$status" -eq 0 ] || { echo "a blackout must not be a failure"; echo "$output"; return 1; }
}

@test "MUTATION: dropping the v1 refusal lets the wrong estate be graded" {
  local broken="${BATS_TEST_TMPDIR}/acceptance-v1.sh"
  mutate "$ACCEPT" 's/^  for marker in "\${V1_MARKERS\[@\]}"; do$/  for marker in; do/' "$broken"

  run "$broken" --handoff "${HANDOFFS}/v1-controlplane.handoff.json"
  [ "$status" -ne 4 ] || { echo "the mutation did not reach the guard"; echo "$output"; return 1; }
  [[ "$output" != *"REFUSING TO RUN"* ]] || { echo "$output"; return 1; }

  run "$ACCEPT" --handoff "${HANDOFFS}/v1-controlplane.handoff.json"
  [ "$status" -eq 4 ] || { echo "the real script must still refuse"; echo "$output"; return 1; }
}
