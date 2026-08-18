#!/usr/bin/env bats
#
# terraform-conformance-harness.bats -- the offline surface for the live
# conformance and teardown scripts.
#
# The scripts under test only mean anything against a running cloud, which is
# exactly why they need a test that runs without one. A harness you can only
# exercise by deploying an environment is a harness nobody exercises, and the
# first time anyone finds out that the IAP check was wrong is the evening it
# reports PASS on a demo that is open to the internet.
#
# So `gcloud` is a stub on PATH whose every answer comes from a fixture, and the
# scripts cannot tell the difference. What is asserted here is behaviour: which
# verdict each estate produces, what the failure line names, and what happens
# when the cloud will not answer at all.
#
# Two rules govern the shape of this file:
#
#   1. EVERY NEGATIVE IS PAIRED WITH A POSITIVE. A script that always returns
#      FAIL would satisfy every "this estate fails" test in here. The compliant
#      run is what makes the negatives mean anything, and the compliant fixture
#      deliberately carries decoys -- a neighbouring environment with an
#      external IP, a deny rule sourced from 0.0.0.0/0, a disabled open rule --
#      so that three separate over-broad implementations turn it red.
#
#   2. EXISTENCE BEFORE CONTENT. A grep that finds nothing because the file was
#      never written is a green test measuring nothing.
#
# And the mutation checks at the end prove the assertions can fail at all.
#
# No network. No cloud credentials. No terraform. Runs in a few seconds.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export SCRIPT_DIR="${REPO_ROOT}/scripts/gcp-tf"
  export CONFORMANCE="${SCRIPT_DIR}/conformance.sh"
  export TEARDOWN="${SCRIPT_DIR}/teardown-verify.sh"
  export FIXTURES="${REPO_ROOT}/test/fixtures/gcp-tf-conformance"
  export STUB_SRC="${FIXTURES}/stub-gcloud.sh"
  export F_COMPLIANT="${FIXTURES}/compliant"
  export F_TEARDOWN="${FIXTURES}/teardown-clean"
}

setup() {
  # Presence first, always. Every test below is meaningless if these are not
  # here, and a missing script would otherwise present as a quiet failure to
  # match some string.
  [ -f "$CONFORMANCE" ]
  [ -f "$TEARDOWN" ]
  [ -f "$STUB_SRC" ]
  [ -d "$F_COMPLIANT" ]
  [ -d "$F_TEARDOWN" ]

  STUBDIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUBDIR"
  cp "$STUB_SRC" "${STUBDIR}/gcloud"
  chmod +x "${STUBDIR}/gcloud"

  CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"$CALL_LOG"
  export STUB_GCLOUD_LOG="$CALL_LOG"
  export PATH="${STUBDIR}:${PATH}"

  # Every test declares its own estate; nothing is inherited.
  unset STUB_FIXTURE_BASE STUB_FIXTURE_OVERLAY STUB_GCLOUD_FAIL || true
}

# The estate a run sees: base is the whole world, overlay is this scenario's
# difference. Splitting them is what keeps each negative to a single file.
estate() {
  export STUB_FIXTURE_BASE="$1"
  if [ "$#" -ge 2 ] && [ -n "$2" ]; then
    [ -d "${FIXTURES}/$2" ] || {
      echo "no such scenario: ${FIXTURES}/$2"
      return 1
    }
    export STUB_FIXTURE_OVERLAY="${FIXTURES}/$2"
  else
    unset STUB_FIXTURE_OVERLAY || true
  fi
}

# Count verdict lines of one kind in $output.
verdicts() {
  printf '%s\n' "$output" | grep -c "^$1 " || true
}

# Stage a copy of a script and apply one sed mutation to it. REFUSES to continue
# unless the mutation actually changed the file: a sed whose pattern no longer
# matches silently no-ops, the mutation check then runs against unmutated code
# and passes, and the result is a mutation check that can never fail -- the
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

@test "both scripts exist and are executable" {
  for s in "$CONFORMANCE" "$TEARDOWN"; do
    [ -f "$s" ] || { echo "missing ${s}"; return 1; }
    [ -x "$s" ] || { echo "not executable: ${s}"; return 1; }
  done
}

@test "both scripts are shellcheck-clean" {
  run shellcheck "$CONFORMANCE" "$TEARDOWN"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "both scripts support --help and exit 0" {
  run "$CONFORMANCE" --help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Usage: conformance.sh"* ]] || { echo "$output"; return 1; }

  run "$TEARDOWN" --help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Usage: teardown-verify.sh"* ]] || { echo "$output"; return 1; }
}

@test "both scripts exit 2 without their required flags" {
  run "$CONFORMANCE"
  [ "$status" -eq 2 ] || { echo "expected 2, got ${status}: ${output}"; return 1; }
  run "$CONFORMANCE" --project p
  [ "$status" -eq 2 ] || { echo "--env is required too, got ${status}"; return 1; }
  run "$TEARDOWN" --env demo-1
  [ "$status" -eq 2 ] || { echo "--project is required too, got ${status}"; return 1; }
}

@test "the stub and every fixture estate exist, and the fixtures are valid JSON" {
  [ -x "${STUBDIR}/gcloud" ]
  local scenario
  for scenario in compliant external-ip open-firewall iap-allauth iap-disabled \
    armor-default-allow armor-default-preview sa-user-key \
    teardown-clean teardown-orphan-ip teardown-no-bucket \
    teardown-leftover-instance teardown-collateral teardown-ci-sa-gone; do
    [ -d "${FIXTURES}/${scenario}" ] || { echo "missing scenario ${scenario}"; return 1; }
    local n
    n="$(find "${FIXTURES}/${scenario}" -name '*.json' -type f | wc -l)"
    [ "$n" -gt 0 ] || { echo "scenario ${scenario} holds no fixture"; return 1; }
  done

  # Every fixture parses, except the deliberate error sentinels.
  local f
  while IFS= read -r f; do
    if head -c 15 "$f" | grep -q '__STUB_ERROR__'; then continue; fi
    jq -e . "$f" >/dev/null 2>&1 || { echo "not valid JSON: ${f}"; return 1; }
  done < <(find "$FIXTURES" -name '*.json' -type f)
}

# ---------------------------------------------------------------------------
# conformance.sh -- the positive
# ---------------------------------------------------------------------------

@test "conformance: a compliant estate is all PASS and exits 0" {
  estate "$F_COMPLIANT"
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "$output"; return 1; }
  # Every control the brief names has to actually be present in the report. A
  # run with three checks would otherwise be "all PASS" too.
  [ "$(verdicts PASS)" -ge 11 ] || { echo "only $(verdicts PASS) PASS lines"; echo "$output"; return 1; }
  local item
  for item in "no external IP" "OS Login enforced" "Shielded VM" \
    "per-environment runtime SA" "no 0.0.0.0/0 ingress" "SSH only from IAP range" \
    "IAP enabled on backend" "IAP principals" "Cloud Armor default denies" \
    "state bucket protection" "no service account keys"; do
    [[ "$output" == *"$item"* ]] || { echo "no check reported for: ${item}"; return 1; }
  done
}

@test "conformance: every reported check names its SECURITY.md threat row" {
  estate "$F_COMPLIANT"
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local line
  while IFS= read -r line; do
    [[ "$line" == *"[SECURITY.md #"* ]] || { echo "verdict with no threat row: ${line}"; return 1; }
  done < <(printf '%s\n' "$output" | grep -E '^(PASS|FAIL|UNKNOWN) ')
}

# ---------------------------------------------------------------------------
# conformance.sh -- the negatives, each paired with the positive above
# ---------------------------------------------------------------------------

@test "conformance: an instance with an external IP FAILs and names the instance" {
  estate "$F_COMPLIANT" external-ip
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    no external IP"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-vm"* ]] || { echo "the failure does not name the instance"; echo "$output"; return 1; }
  # Only that check moved.
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "conformance: a 0.0.0.0/0 firewall allow FAILs and names the rule" {
  estate "$F_COMPLIANT" open-firewall
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    no 0.0.0.0/0 ingress"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-temporary-debug-open"* ]] || { echo "the failure does not name the rule"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "conformance: IAP granted to allAuthenticatedUsers FAILs" {
  # The single most important assertion in this file. allAuthenticatedUsers
  # reads as a restriction and is not one: in IAP it means any Google account on
  # earth. A conformance run that reports PASS on this is worse than no run.
  estate "$F_COMPLIANT" iap-allauth
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    IAP principals"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"allAuthenticatedUsers"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "conformance: a Cloud Armor default rule that allows FAILs" {
  estate "$F_COMPLIANT" armor-default-allow
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    Cloud Armor default denies"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"allow-by-default"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "conformance: a denying Cloud Armor default rule in preview FAILs" {
  # preview=true logs the decision and serves the request. The policy reads
  # 'deny' and behaves 'allow', which is the whole class of control that passes
  # a config review and protects nothing.
  estate "$F_COMPLIANT" armor-default-preview
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    Cloud Armor default denies"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"preview=true"* ]] || { echo "$output"; return 1; }
}

@test "conformance: IAP disabled on the backend service FAILs" {
  estate "$F_COMPLIANT" iap-disabled
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    IAP enabled on backend"* ]] || { echo "$output"; return 1; }
}

@test "conformance: a user-managed service account key FAILs" {
  estate "$F_COMPLIANT" sa-user-key
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    no service account keys"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# conformance.sh -- ignorance is reported as ignorance
# ---------------------------------------------------------------------------

@test "conformance: a gcloud that errors reports UNKNOWN, never FAIL, and exits 0" {
  estate "$F_COMPLIANT"
  export STUB_GCLOUD_FAIL=1
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "expected exit 0 on could-not-look, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "could-not-look was reported as a failure"; echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -ge 11 ] || { echo "$output"; return 1; }
  [ "$(verdicts PASS)" -eq 0 ] || { echo "something passed while nothing could be read"; echo "$output"; return 1; }
}

@test "conformance: an environment that is not deployed is UNKNOWN, not PASS" {
  # An empty estate must never read as a clean one. This is the failure mode
  # where a conformance run against the wrong --env reports a perfect score.
  estate "$F_COMPLIANT"
  run "$CONFORMANCE" --project example-project --env demo-7 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"no instance named sl-demo-7-* exists"* ]] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -ge 4 ] || { echo "$output"; return 1; }
}

@test "conformance: --strict exits 3 when nothing failed but something was unchecked" {
  estate "$F_COMPLIANT"
  # No --bucket, so the state bucket checks are UNKNOWN and nothing else is.
  run "$CONFORMANCE" --project example-project --env demo-1 --strict
  [ "$status" -eq 3 ] || { echo "expected 3, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }

  # And without --strict the same estate is a pass.
  run "$CONFORMANCE" --project example-project --env demo-1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# conformance.sh -- scoping
# ---------------------------------------------------------------------------

@test "conformance: sl-demo-10 is not graded as sl-demo-1" {
  # The compliant estate carries sl-demo-10-vm with an external IP, no OS Login
  # and the default compute service account. demo-1 passes (asserted above);
  # grading demo-10 must find every one of those faults. If prefix matching
  # loses its trailing hyphen, the first run turns red and this one stays green,
  # so the pair pins the boundary from both sides.
  estate "$F_COMPLIANT"
  run "$CONFORMANCE" --project example-project --env demo-10
  [ "$status" -eq 1 ] || { echo "expected demo-10 to fail; got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-10-vm"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"DEFAULT-COMPUTE-SA"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-10-allow-all"* ]] || { echo "the open rule in demo-10's VPC was missed"; echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# The read-only guard, on both scripts
# ---------------------------------------------------------------------------

@test "both scripts refuse a mutating gcloud call" {
  local s
  for s in "$CONFORMANCE" "$TEARDOWN"; do
    run bash -c "source '${s}'; gcloud_ro compute instances delete sl-demo-1-vm"
    [ "$status" -eq 2 ] || { echo "${s} did not refuse a delete (status ${status})"; echo "$output"; return 1; }
    [[ "$output" == *"refusing to run a non-read-only gcloud call"* ]] || { echo "$output"; return 1; }

    run bash -c "source '${s}'; gcloud_ro projects set-iam-policy p policy.json"
    [ "$status" -eq 2 ] || { echo "${s} did not refuse set-iam-policy"; echo "$output"; return 1; }
  done
}

@test "every gcloud call an actual run makes is read-only" {
  # An assertion about what RAN, not about what the source appears to do. The
  # allowlist could be correct and a call could still be built somewhere that
  # never passes through it.
  estate "$F_COMPLIANT"
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  estate "$F_TEARDOWN"
  run "$TEARDOWN" --project example-project --env demo-1 --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [ -s "$CALL_LOG" ] || { echo "no gcloud calls were recorded at all"; return 1; }
  local line
  while IFS= read -r line; do
    case " ${line} " in
      *' describe '* | *' list '* | *' version '* | *' get-iam-policy '*) ;;
      *)
        echo "a non-read-only gcloud call was made: ${line}"
        return 1
        ;;
    esac
  done <"$CALL_LOG"
}

@test "no absence check delegates its filtering to a server-side --filter" {
  # A mistyped --filter returns an empty list; an empty list is exactly what
  # 'destroyed' and 'clean' look like; the report then goes green on a question
  # it never asked. Filtering happens in the scripts, where it is visible and
  # where these tests can reach it.
  estate "$F_TEARDOWN"
  run "$TEARDOWN" --project example-project --env demo-1 --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$CALL_LOG" ] || { echo "no calls recorded"; return 1; }
  ! grep -q -- '--filter' "$CALL_LOG" || {
    echo "a server-side --filter was used:"
    grep -- '--filter' "$CALL_LOG"
    return 1
  }
}

# ---------------------------------------------------------------------------
# teardown-verify.sh
# ---------------------------------------------------------------------------

@test "teardown: a fully clean teardown is all PASS and exits 0" {
  estate "$F_TEARDOWN"
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts UNKNOWN)" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdicts PASS)" -ge 14 ] || { echo "only $(verdicts PASS) PASS lines"; echo "$output"; return 1; }
  local item
  for item in "instance" "instance group" "VPC network" "subnet" "forwarding rule" \
    "backend service" "Cloud Armor policy" "reserved static IPs" "persistent disks" \
    "snapshots" "runtime service account" "state bucket survives"; do
    [[ "$output" == *"$item"* ]] || { echo "no check reported for: ${item}"; return 1; }
  done
}

@test "teardown: a leftover static IP FAILs and names it" {
  estate "$F_TEARDOWN" teardown-orphan-ip
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    reserved static IPs"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-1-lb-ip"* ]] || { echo "the failure does not name the address"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "teardown: a missing state bucket FAILs, loudly" {
  # An absence-only teardown check would award a destroy that deleted the state
  # bucket a perfect score, because absence is precisely what it looks for.
  estate "$F_TEARDOWN" teardown-no-bucket
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    state bucket survives"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"STOP."* ]] || { echo "the failure does not tell anyone to stop"; echo "$output"; return 1; }
}

@test "teardown: a surviving instance FAILs, names it, and counts it correctly" {
  estate "$F_TEARDOWN" teardown-leftover-instance
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    instance"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"1 survived: sl-demo-1-vm"* ]] || { echo "wrong name or wrong count"; echo "$output"; return 1; }
}

@test "teardown: another environment disappearing FAILs as collateral damage" {
  estate "$F_TEARDOWN" teardown-collateral
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"FAIL    environment demo-2 untouched"* ]] || { echo "$output"; return 1; }
}

@test "teardown: an environment destroy that took the CI identities FAILs" {
  # sl-ci-plan and sl-ci-apply are platform, not environment. A destroy that
  # reached them has taken the estate's ability to deploy anything at all, and
  # an absence-only teardown check would have scored that as a clean run.
  estate "$F_TEARDOWN" teardown-ci-sa-gone
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 1 ] || { echo "expected exit 1, got ${status}"; echo "$output"; return 1; }
  [[ "$output" == *"FAIL    CI service accounts"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"sl-ci-plan"* ]] || { echo "the failure does not name what is missing"; echo "$output"; return 1; }

  # Paired positive: the same check passes on the clean estate, so a script that
  # always reported MISSING would not satisfy both.
  estate "$F_TEARDOWN"
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PASS    CI service accounts"* ]] || { echo "$output"; return 1; }
}

@test "teardown: no --other-env is UNKNOWN, not a pass" {
  # "Nothing else was harmed" with nothing named is an assumption, not a check.
  estate "$F_TEARDOWN"
  run "$TEARDOWN" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"UNKNOWN other environments untouched"* ]] || { echo "$output"; return 1; }
}

@test "teardown: a total cloud blackout is UNKNOWN everywhere and exits 0" {
  # Including the state bucket. Screaming 'the state bucket is gone' at someone
  # whose token expired is a false alarm, and the second one costs the report
  # its credibility.
  estate "$F_TEARDOWN"
  export STUB_GCLOUD_FAIL=1
  run "$TEARDOWN" --project example-project --env demo-1 \
    --bucket example-tfstate-bucket --other-env demo-2
  [ "$status" -eq 0 ] || { echo "expected exit 0, got ${status}"; echo "$output"; return 1; }
  [ "$(verdicts FAIL)" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"this is an access problem, not a verdict on the bucket"* ]] || { echo "$output"; return 1; }
}

@test "teardown: an unreadable bucket IS a FAIL when other reads succeeded" {
  # The pair to the test above. The discrimination is the point: same failed
  # describe, opposite verdict, decided by whether anything else answered.
  estate "$F_TEARDOWN" teardown-no-bucket
  run "$TEARDOWN" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"while other reads in this run succeeded"* ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# Mutation checks -- proof that the assertions above can fail
# ---------------------------------------------------------------------------
#
# Each one stages a copy of a script, breaks exactly one control, and asserts
# that the estate which SHOULD fail now passes. A green suite proves nothing
# about a test that could not have gone red.

@test "mutation: removing the allUsers/allAuthenticatedUsers rejection turns the IAP test green" {
  local broken="${BATS_TEST_TMPDIR}/conformance-mutated.sh"
  mutate "$CONFORMANCE" \
    's/select(\. == "allUsers" or \. == "allAuthenticatedUsers")/select(false)/' \
    "$broken"

  estate "$F_COMPLIANT" iap-allauth
  run "$broken" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "mutation did not defeat the check; it may be asserted elsewhere"; echo "$output"; return 1; }
  [[ "$output" != *"FAIL    IAP principals"* ]] || { echo "$output"; return 1; }

  # And the unmutated script still catches it -- otherwise the mutation proved
  # nothing about the real script.
  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "mutation: dropping the trailing hyphen from prefix matching turns the compliant estate red" {
  # Proves the decoys in compliant/ are load-bearing rather than decoration.
  local broken="${BATS_TEST_TMPDIR}/conformance-prefix.sh"
  mutate "$CONFORMANCE" 's/--arg p "\${prefix}-"/--arg p "${prefix}"/' "$broken"

  estate "$F_COMPLIANT"
  run "$broken" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "sl-demo-10 was not picked up by the widened prefix"; echo "$output"; return 1; }
  [[ "$output" == *"sl-demo-10-vm"* ]] || { echo "$output"; return 1; }

  run "$CONFORMANCE" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "the real script must still pass"; echo "$output"; return 1; }
}

@test "mutation: widening the read-only allowlist lets a delete through" {
  local broken="${BATS_TEST_TMPDIR}/conformance-guard.sh"
  mutate "$CONFORMANCE" \
    "s/    \*' describe '\* | \*' list '\* | \*' version '\*) ;;/    *) ;;/" \
    "$broken"

  run bash -c "source '${broken}'; gcloud_ro compute instances delete x 2>/dev/null || true"
  [[ "$output" != *"refusing to run a non-read-only gcloud call"* ]] || {
    echo "the guard still refused; the mutation did not reach it"
    echo "$output"
    return 1
  }

  run bash -c "source '${CONFORMANCE}'; gcloud_ro compute instances delete x"
  [ "$status" -eq 2 ] || { echo "the real guard must still refuse"; echo "$output"; return 1; }
}

@test "mutation: turning the state-bucket FAIL into a PASS hides a deleted bucket" {
  local broken="${BATS_TEST_TMPDIR}/teardown-mutated.sh"
  mutate "$TEARDOWN" \
    's/report FAIL "state bucket survives"/report PASS "state bucket survives"/' \
    "$broken"

  estate "$F_TEARDOWN" teardown-no-bucket
  run "$broken" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 0 ] || { echo "mutation did not defeat the check"; echo "$output"; return 1; }

  run "$TEARDOWN" --project example-project --env demo-1 --bucket example-tfstate-bucket
  [ "$status" -eq 1 ] || { echo "the real script must still catch it"; echo "$output"; return 1; }
}
