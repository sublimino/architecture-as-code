#!/usr/bin/env bats
#
# terraform-preserve-guards.bats -- the offline surface for destroy preservation.
#
# Two guards are driven from here, and they answer different halves of the same
# question.
#
#   1. THE STRUCTURAL GUARD. Can a destroy of the environments root -- the root
#      `make gcp-tf-destroy` actually targets -- reach a storage bucket or a
#      Secret Manager secret at all? This is the strongest form of the
#      protection, because it does not depend on anyone running anything: if the
#      configuration cannot declare them, destroying it cannot remove them.
#
#   2. THE RUNTIME GUARD. `scripts/gcp-tf/preserve-check.sh`, run either side of
#      a real destroy, comparing the live estate against a recorded baseline.
#      Structure is a claim about the code; this is a claim about the world, and
#      only the second one survives a console change at 19:00 on demo night.
#
# WHY THE STRUCTURAL HALF IS BATS AND NOT `terraform test`. CONTRACT §7a routes
# it here explicitly: "absence-across-the-whole-tree is the case `terraform
# test` genuinely cannot do: it can only see what a given plan evaluated, not
# what no configuration anywhere contains." A plan can tell you that
# `google_storage_bucket.state` came out hardened. Nothing in a plan can tell
# you that no bucket resource exists in any file the root can reach. The
# assertion needed here is the second kind.
#
# THREE RULES GOVERN THIS FILE.
#
#   EXISTENCE BEFORE CONTENT. Every scan asserts that it scanned something. A
#   grep that finds no buckets because it was pointed at an empty directory list
#   is a green test measuring nothing, and this suite's central assertion is an
#   absence -- the exact shape that passes hardest when it is broken.
#
#   EVERY NEGATIVE IS PAIRED WITH A POSITIVE. The scanner is proven to FIND a
#   bucket (in the platform closure, and in the fixture tree) before it is
#   trusted to report none in the environments closure. Otherwise a scanner that
#   returned nothing unconditionally would satisfy every assertion here.
#
#   THE CORRECT PATTERN MUST STAY LEGAL. `modules/compute` binds
#   `google_secret_manager_secret_iam_member` on a secret it does not own, and
#   reads it through a `data` source. A guard that flagged either would forbid
#   the very pattern that makes the estate safe, so both are decoys in the
#   fixtures and both are asserted to pass.
#
# No network. No cloud credentials. No terraform. Runs in a few seconds.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export CHECKER="${REPO_ROOT}/scripts/gcp-tf/preserve-check.sh"
  export CLOSURE="${REPO_ROOT}/test/helpers/tf-module-closure.sh"
  export TF_ENV_ROOT="${REPO_ROOT}/terraform/environments"
  export TF_PLATFORM_ROOT="${REPO_ROOT}/terraform/platform"
  export TF_FIXTURES="${REPO_ROOT}/test/fixtures/terraform/preserve"
  export GCP_FIXTURES="${REPO_ROOT}/test/fixtures/gcp-tf-preserve"
  export STUB_SRC="${GCP_FIXTURES}/stub-gcloud.sh"
  export F_INTACT="${GCP_FIXTURES}/intact"
}

setup() {
  # Presence first, always. Every assertion below is meaningless if these are
  # absent, and a missing file would otherwise present as a quiet failure to
  # match some string.
  [ -f "$CHECKER" ]
  [ -x "$CLOSURE" ]
  [ -d "$TF_ENV_ROOT" ]
  [ -d "$TF_PLATFORM_ROOT" ]
  [ -d "$TF_FIXTURES" ]
  [ -f "$STUB_SRC" ]
  [ -d "$F_INTACT" ]

  STUBDIR="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUBDIR"
  cp "$STUB_SRC" "${STUBDIR}/gcloud"
  chmod +x "${STUBDIR}/gcloud"

  CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"$CALL_LOG"
  export STUB_GCLOUD_LOG="$CALL_LOG"
  export PATH="${STUBDIR}:${PATH}"

  BASELINE="${BATS_TEST_TMPDIR}/baseline.json"

  # Every test declares its own estate; nothing is inherited between them.
  unset STUB_FIXTURE_BASE STUB_FIXTURE_OVERLAY STUB_GCLOUD_FAIL || true
  export STUB_FIXTURE_BASE="$F_INTACT"
}

# ---------------------------------------------------------------------------
# Shared drivers
# ---------------------------------------------------------------------------

# The scanner itself. Both the real assertions and the mutation checks call
# THIS function, so a mutation check cannot end up exercising a second
# implementation that happens to behave differently from the one that ships.
#
# Comments are stripped before matching: commented-out configuration is not
# configuration, and reporting it would make the guard fire on documentation.
#
# The trailing quote in each alternative is load-bearing. Without it
# `google_secret_manager_secret` also matches `google_secret_manager_secret_iam_member`,
# which is the resource type modules/compute legitimately uses -- the guard
# would then forbid the correct pattern and get deleted rather than fixed.
forbidden_declarations() {
  local root="$1"
  local -a dirs=()
  local d f

  while IFS= read -r d; do
    [ -n "$d" ] && dirs+=("$d")
  done < <("$CLOSURE" "$root")

  # A closure of zero directories means the walk failed, not that the tree is
  # clean. Reported as an error rather than as an empty (passing) result.
  if [ "${#dirs[@]}" -eq 0 ]; then
    echo "EMPTY CLOSURE for ${root}: the scan covered nothing"
    return 2
  fi

  for d in "${dirs[@]}"; do
    local -a tf_files=()
    for f in "$d"/*.tf; do
      [ -f "$f" ] && tf_files+=("$f")
    done
    [ "${#tf_files[@]}" -gt 0 ] || continue

    sed 's/[[:space:]]*#.*$//' "${tf_files[@]}" |
      grep -oE 'resource[[:space:]]+"(google_storage_bucket|google_secret_manager_secret|google_secret_manager_secret_version)"' |
      sed "s|^|${d}: |" || true
  done
}

# Count the directories a closure covers, so tests can assert the walk was real.
closure_size() {
  "$CLOSURE" "$1" | grep -c . || true
}

# Count lines of $output matching an extended regex.
#
# Deliberately NOT `run bash -c "printf '%s\n' '$output' | grep ..."`. The
# verifier's fix lines contain apostrophes -- "this root's state is gone" --
# and interpolating $output into a single-quoted `bash -c` terminates the quote
# mid-report, after which the shell parses the remainder of the report as code.
# That failed here as an assertion error that read like a genuine defect, and on
# a report without an apostrophe the same construct silently succeeds, so it is
# a trap that only fires on some inputs.
count_matching() {
  printf '%s\n' "$output" | grep -cE "$1" || true
}

capture_baseline() {
  run "$CHECKER" --capture \
    --project changeme-project \
    --state-bucket changeme-project-osramp-tfstate \
    --audit-bucket changeme-project-signalloom-audit \
    --secret sl-demo-tailscale-authkey \
    --sa-prefix sl-rt- --sa-prefix sl-deploy \
    --baseline "$BASELINE"
  [ "$status" -eq 0 ] || {
    echo "capture failed: $output"
    return 1
  }
  [ -s "$BASELINE" ] || {
    echo "capture wrote no baseline"
    return 1
  }
}

# Verify against a named scenario overlay. '' means the intact estate.
verify_against() {
  local scenario="${1:-}"
  if [ -n "$scenario" ]; then
    [ -d "${GCP_FIXTURES}/${scenario}" ] || {
      echo "no such scenario: ${GCP_FIXTURES}/${scenario}"
      return 1
    }
    export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/${scenario}"
  else
    unset STUB_FIXTURE_OVERLAY || true
  fi
  run "$CHECKER" --baseline "$BASELINE"
}

# Stage a copy of a file and apply one sed mutation. REFUSES to continue unless
# the mutation actually changed something: a sed whose pattern no longer matches
# silently no-ops, the mutation check then runs against unmutated code and
# passes, and the result is a mutation check that can never fail -- the precise
# failure this section exists to detect.
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
# Hygiene and the interface
# ---------------------------------------------------------------------------

@test "PRESERVE the checker and the closure helper exist and are executable" {
  for s in "$CHECKER" "$CLOSURE"; do
    [ -f "$s" ] || {
      echo "missing ${s}"
      return 1
    }
    [ -x "$s" ] || {
      echo "not executable: ${s}"
      return 1
    }
  done
}

@test "PRESERVE both scripts are shellcheck-clean" {
  run shellcheck "$CHECKER" "$CLOSURE" "${GCP_FIXTURES}/stub-gcloud.sh"
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
}

@test "PRESERVE the checker refuses every gcloud verb that is not read-only" {
  # Sourced rather than invoked, so the gate is driven directly. A read-only
  # gate nobody can call in isolation is a gate nobody tests, and this one is
  # the reason the script is safe to run beside a live destroy.
  run bash -c "
    set -uo pipefail
    source '${CHECKER}'
    # preserve-check.sh sets errexit at the top, and sourcing it turns errexit
    # on in THIS shell too. Without this line the first refusal (return 99)
    # kills the loop after one iteration and the remaining verbs are never
    # tried -- a five-sixths vacuous test that still looks like it ran.
    set +e
    for call in 'storage buckets delete gs://x' 'secrets versions destroy 1' \
                'secrets versions access latest' 'iam service-accounts delete a@b' \
                'projects add-iam-policy-binding p' 'compute instances create x'; do
      # shellcheck disable=SC2086
      gcloud_ro \$call >/dev/null 2>&1
      printf '%s=%s\n' \"\$call\" \"\$?\"
    done
  "
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  # 99 is the refusal code. Anything else means the call reached the binary.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" == *"=99" ]] || {
      echo "a mutating call was NOT refused: ${line}"
      echo "$output"
      return 1
    }
  done <<<"$output"
}

@test "PRESERVE the checker permits the four read-only verbs it needs" {
  # The paired positive. A gate that refused everything would satisfy the test
  # above and make the whole script useless, and the failure would look like a
  # cloud outage rather than a broken allowlist.
  run bash -c "
    set -uo pipefail
    source '${CHECKER}'
    set +e
    GCLOUD_BIN=true
    for call in 'storage buckets describe gs://x' 'storage objects list gs://x' \
                'secrets versions list s' 'iam service-accounts describe a@b' \
                'projects get-iam-policy p'; do
      # shellcheck disable=SC2086
      gcloud_ro \$call >/dev/null 2>&1
      printf '%s=%s\n' \"\$call\" \"\$?\"
    done
  "
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [ "$(count_matching '=99')" = "0" ] || {
    echo "a read-only verb was refused; the allowlist is too narrow"
    return 1
  }
}

@test "PRESERVE the checker never calls 'secrets versions access' on any path" {
  # The one call that would put an auth key on stdout. Asserted against the
  # source as well as the gate, because a future edit could add it inside a
  # helper that bypasses gcloud_ro entirely.
  #
  # COMMENTS ARE STRIPPED FIRST, and that is not cosmetic. The header of
  # preserve-check.sh documents that `gcloud secrets versions access` is never
  # called, so a naive grep matches the sentence promising the call is absent
  # and reports it as the call being present. The guard fired on its own
  # documentation on the first run of this suite.
  local code
  code="$(sed 's/[[:space:]]*#.*$//' "$CHECKER")"

  # Existence before content: prove the stripped source still contains the code
  # this test is about, so the absence below is an absence in real code rather
  # than in an empty string.
  printf '%s\n' "$code" | grep -q 'secrets versions list' || {
    echo "the version-listing call is missing from the stripped source;"
    echo "this test would be scanning nothing"
    return 1
  }

  printf '%s\n' "$code" | grep -n 'versions access' && {
    echo "preserve-check.sh CALLS 'secrets versions access', which returns key material"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# The structural guard
# ---------------------------------------------------------------------------

@test "PRESERVE the environments module closure is walked and is non-trivial" {
  # Existence before content. The absence assertion in the next test is only
  # worth something if the walk actually reached the modules: the environments
  # root declares NO resource blocks of its own, so a closure of one directory
  # would find nothing and look clean.
  local n
  n="$(closure_size "$TF_ENV_ROOT")"
  [ "$n" -ge 3 ] || {
    echo "environments closure covers only ${n} directories; the walk did not reach the modules"
    "$CLOSURE" "$TF_ENV_ROOT"
    return 1
  }

  run "$CLOSURE" "$TF_ENV_ROOT"
  [ "$status" -eq 0 ]
  for expected in modules/env-contract modules/network modules/compute; do
    [[ "$output" == *"$expected"* ]] || {
      echo "closure is missing ${expected}:"
      echo "$output"
      return 1
    }
  done
}

@test "PRESERVE the environments root declares no bucket and no secret anywhere in its closure" {
  # THE ASSERTION THIS WHOLE FILE EXISTS FOR. `make gcp-tf-destroy` targets this
  # root. If nothing it can reach declares a bucket or a secret, destroying it
  # cannot take the state bucket, the audit bucket or the Tailscale auth key.
  run forbidden_declarations "$TF_ENV_ROOT"
  [ "$status" -eq 0 ] || {
    echo "scan failed: $output"
    return 1
  }
  [ -z "$output" ] || {
    echo "the environments root can create or destroy protected resource types:"
    echo "$output"
    echo
    echo "CONTRACT.md §5b: buckets and secrets belong to platform/bootstrap or"
    echo "are created out of band. A destroy of environments must not reach them."
    return 1
  }
}

@test "PRESERVE the scanner finds the audit bucket in the platform closure" {
  # THE POSITIVE CONTROL for the test above, and the reason it means anything.
  # `modules/observability` really does declare the audit bucket, and it is in
  # the PLATFORM closure, not the environments one. If the scanner cannot find a
  # bucket it is standing on, its silence about the environments root is
  # silence, not evidence.
  run forbidden_declarations "$TF_PLATFORM_ROOT"
  [ "$status" -eq 0 ] || {
    echo "scan failed: $output"
    return 1
  }
  [[ "$output" == *"modules/observability"* ]] || {
    echo "the scanner did not find the audit bucket in the platform closure."
    echo "either observability moved, or the scanner is broken and every other"
    echo "absence result in this file is worthless:"
    echo "$output"
    return 1
  }
  [[ "$output" == *"google_storage_bucket"* ]]
}

@test "PRESERVE the two roots' closures are disjoint where it matters" {
  # The separation is the mechanism. Stated as its own assertion so that wiring
  # observability into environments turns this red with a message that names the
  # consequence, rather than only tripping the absence test.
  run "$CLOSURE" "$TF_ENV_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"modules/observability"* ]] || {
    echo "modules/observability is in the ENVIRONMENTS closure."
    echo "It declares the audit log bucket. A destroy of an environment would"
    echo "now delete the audit trail along with the environment it records."
    return 1
  }
}

@test "PRESERVE the Tailscale secret is read as a data source, never declared" {
  # The positive form. Asserting only "no secret resource exists" would pass
  # perfectly if the whole Tailscale integration were deleted, so the thing that
  # must be present is asserted to be present.
  local compute="${REPO_ROOT}/terraform/modules/compute/main.tf"
  [ -f "$compute" ]

  run grep -c 'data "google_secret_manager_secret" "tailscale_authkey"' "$compute"
  [ "$status" -eq 0 ] && [ "$output" -eq 1 ] || {
    echo "modules/compute no longer reads the auth key through a data source"
    return 1
  }

  run grep -c 'google_secret_manager_secret_iam_member' "$compute"
  [ "$status" -eq 0 ] && [ "$output" -gt 0 ] || {
    echo "modules/compute no longer binds the accessor role on the secret"
    return 1
  }
}

@test "PRESERVE MUTATION leaky-bucket: a module declaring a bucket is caught and named" {
  # Proves the absence test can go red. Without this, a scanner that returned
  # nothing unconditionally would pass every structural test in this file.
  run forbidden_declarations "${TF_FIXTURES}/root"
  [ "$status" -eq 0 ] || {
    echo "scan failed: $output"
    return 1
  }
  [[ "$output" == *"leaky-bucket"* ]] || {
    echo "the scanner missed a declared bucket:"
    echo "$output"
    return 1
  }
  [[ "$output" == *"google_storage_bucket"* ]]
}

@test "PRESERVE MUTATION leaky-secret: a declared secret and a declared version are both caught" {
  run forbidden_declarations "${TF_FIXTURES}/root"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"google_secret_manager_secret"'* ]] || {
    echo "the scanner missed a declared secret:"
    echo "$output"
    return 1
  }
  # A destroyed version leaves the secret existing and unusable -- the same
  # outage as deleting it, which is why the version type is forbidden too.
  [[ "$output" == *'"google_secret_manager_secret_version"'* ]] || {
    echo "the scanner missed a declared secret VERSION:"
    echo "$output"
    return 1
  }
}

@test "PRESERVE the scanner does not flag IAM members, data sources or comments" {
  # The guard must not forbid the correct pattern. Three decoys live in the
  # fixture tree: a bucket IAM member, a secret IAM member, and a commented-out
  # bucket. Flagging any of them would make the guard fire on safe code, and a
  # guard that cries wolf gets deleted rather than fixed.
  run forbidden_declarations "${TF_FIXTURES}/root"
  [ "$status" -eq 0 ]
  [[ "$output" != *"google_storage_bucket_iam_member"* ]] || {
    echo "a bucket IAM member was flagged; it neither creates nor destroys a bucket"
    echo "$output"
    return 1
  }
  [[ "$output" != *"google_secret_manager_secret_iam_member"* ]] || {
    echo "a secret IAM member was flagged; modules/compute uses exactly this pattern"
    echo "$output"
    return 1
  }
  [[ "$output" != *"commented_out"* ]]
  [[ "$output" != *"clean-module"* ]] || {
    echo "the module that only READS a secret was flagged:"
    echo "$output"
    return 1
  }
}

@test "PRESERVE MUTATION empty-closure: a scan that covers nothing errors rather than passing" {
  # The vacuous pass, made explicit. A closure walk that returns no directories
  # finds no buckets, and "found no buckets" is indistinguishable from a clean
  # tree unless the scanner refuses to report it as one.
  local fake="${BATS_TEST_TMPDIR}/fake-closure"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake"
  chmod +x "$fake"

  CLOSURE="$fake" run forbidden_declarations "$TF_ENV_ROOT"
  [ "$status" -eq 2 ] || {
    echo "an empty closure returned status ${status}; expected 2"
    echo "$output"
    return 1
  }
  [[ "$output" == *"EMPTY CLOSURE"* ]]
}

# ---------------------------------------------------------------------------
# The runtime guard -- capture
# ---------------------------------------------------------------------------

@test "PRESERVE capture records buckets, the secret and the discovered accounts" {
  capture_baseline

  run jq -r '.schema' "$BASELINE"
  [ "$output" = "1" ]
  run jq -r '.buckets | length' "$BASELINE"
  [ "$output" = "2" ]
  run jq -r '.secrets | length' "$BASELINE"
  [ "$output" = "1" ]
  run jq -r '[.buckets[] | select(.role == "state") | .total_objects] | add' "$BASELINE"
  [ "$output" = "6" ]
}

@test "PRESERVE capture counts distinct objects, not the generations of them" {
  # REGRESSION TEST FOR A DEFECT A LIVE RUN FOUND. The state bucket has object
  # versioning enabled, and `gcloud storage objects list` returns EVERY
  # generation: the real bucket answered with 42 records for 4 live objects.
  # Counting records makes the number rise on every apply and fall whenever
  # lifecycle expiry collects old generations, so the comparison would report
  # deletions that never happened.
  #
  # The intact fixture carries 14 records for 7 distinct names, mirroring that
  # shape. If the dedup is dropped the counts below roughly double.
  capture_baseline

  run jq -r '[.buckets[] | select(.role == "state") | .prefixes[] | select(.prefix == "osramp/platform/") | .objects] | add' "$BASELINE"
  [ "$output" = "2" ] || {
    echo "osramp/platform/ recorded ${output} objects; expected 2 distinct"
    jq -c '.buckets[0].prefixes' "$BASELINE"
    return 1
  }
  run jq -r '[.buckets[] | select(.role == "state") | .prefixes[] | select(.prefix == "osramp/environments/demo-1/") | .objects] | add' "$BASELINE"
  [ "$output" = "1" ] || {
    echo "demo-1 recorded ${output} objects; three generations of one file should count once"
    return 1
  }
}

@test "PRESERVE a normal apply adding generations is not reported as a change" {
  # The false-positive half, and the one that decides whether this tool survives
  # contact with the team. Every apply writes a new generation of a state file
  # and takes a lock. If that reads as a regression the guard cries wolf on
  # every deploy and gets switched off, at which point it protects nothing.
  capture_baseline
  verify_against "generations-churned"
  [ "$status" -eq 0 ] || {
    echo "a routine apply was reported as a regression:"
    echo "$output"
    return 1
  }
  [ "$(count_matching '^REGRESSION')" = "0" ]
}

@test "PRESERVE lifecycle expiry collecting old generations is not a deletion" {
  # THE TEST THAT ACTUALLY DEPENDS ON THE DEDUP, and the reason the churn test
  # above is not enough: the verifier only flags counts that FALL, so adding
  # generations is green whether or not they are deduplicated. Removing them is
  # the direction that bites.
  #
  # Lifecycle expiry on a versioned bucket collects noncurrent generations on a
  # schedule nobody is watching. Counting records, the intact estate's 14 drop
  # to 6 overnight and the guard reports a mass deletion of state on a morning
  # when nothing happened at all. Counting distinct live objects, nothing moved.
  capture_baseline
  verify_against "generations-collected"
  [ "$status" -eq 0 ] || {
    echo "collected generations were reported as deleted state:"
    echo "$output"
    return 1
  }
  [ "$(count_matching '^REGRESSION')" = "0" ]
}

@test "PRESERVE ephemeral lock files are excluded from the inventory" {
  # A .tflock exists only while an apply is in flight. A baseline captured
  # during one records a file that is legitimately gone afterwards, and the
  # verifier would call that a deletion. The intact fixture carries two
  # generations of a lock under demo-1; neither may be counted.
  capture_baseline

  run jq -r '[.buckets[] | select(.role == "state") | .prefixes[].objects] | add' "$BASELINE"
  [ "$output" = "6" ] || {
    echo "total is ${output}; expected 6 with the lock excluded"
    jq -c '.buckets[0].prefixes' "$BASELINE"
    return 1
  }

  # Existence before content: prove the fixture really does contain a lock, so
  # the exclusion above is excluding something rather than matching nothing.
  run grep -c 'default.tflock' "${F_INTACT}/storage-objects-list-changeme-project-osramp-tfstate.json"
  [ "$status" -eq 0 ] && [ "$output" -ge 2 ] || {
    echo "the fixture has no lock files; this test proved nothing"
    return 1
  }
}

@test "PRESERVE prefixes are grouped per root, not collapsed into one shared segment" {
  # REGRESSION TEST FOR A DEFECT A LIVE RUN FOUND. Every object in the real
  # bucket lives under one shared top-level prefix ("osramp/"). Grouping on the
  # first path segment collapsed the entire estate into a single count and threw
  # away the resolution this check exists for: noticing that ONE root's state
  # disappeared while the bucket as a whole still looked busy.
  capture_baseline

  run jq -r '[.buckets[] | select(.role == "state") | .prefixes[].prefix] | sort | join(",")' "$BASELINE"
  local expected="(root),osramp/bootstrap/,osramp/environments/ci-1/,osramp/environments/demo-1/,osramp/platform/"
  [ "$output" = "$expected" ] || {
    echo "prefixes are grouped wrongly."
    echo "  expected: ${expected}"
    echo "  got:      ${output}"
    return 1
  }
}

@test "PRESERVE capture discovers accounts by prefix and excludes the ones that do not match" {
  # Client-side matching on a whole list. A server-side --filter that matched
  # nothing would record an empty protected set, and every later verify would
  # pass by checking no accounts at all. The decoy in the fixture proves the
  # filter is real in the other direction too.
  capture_baseline

  run jq -r '.service_accounts | length' "$BASELINE"
  [ "$output" = "2" ]
  run jq -r '[.service_accounts[].email] | join(",")' "$BASELINE"
  [[ "$output" == *"sl-rt-demo-1@"* ]]
  [[ "$output" == *"sl-deploy@"* ]]
  [[ "$output" != *"unrelated-sa@"* ]] || {
    echo "prefix discovery swept up an unrelated account: $output"
    return 1
  }
}

@test "PRESERVE capture records no secret material of any kind" {
  capture_baseline

  # Only names, counts and states may appear. Asserted as a whitelist of top
  # level keys per secret rather than as a search for suspicious strings: a
  # denylist of secret-shaped patterns cannot anticipate the payload.
  run jq -r '[.secrets[] | keys_unsorted[]] | unique | join(",")' "$BASELINE"
  [ "$output" = "enabled_versions,name,total_versions" ] || {
    echo "unexpected keys recorded for a secret: $output"
    return 1
  }
  run grep -ci 'secret_data\|payload\|authkey_value\|tskey-' "$BASELINE"
  [ "$output" = "0" ] || {
    echo "the baseline contains something that looks like key material"
    return 1
  }
}

@test "PRESERVE capture refuses to record an empty state bucket as the baseline" {
  # A baseline of zero objects would make every later comparison pass by
  # comparing nothing to nothing.
  export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/state-bucket-empty"
  run "$CHECKER" --capture \
    --project changeme-project \
    --state-bucket changeme-project-osramp-tfstate \
    --secret sl-demo-tailscale-authkey \
    --sa-prefix sl-deploy \
    --baseline "$BASELINE"
  [ "$status" -eq 2 ] || {
    echo "expected a usage error, got ${status}: $output"
    return 1
  }
  [[ "$output" == *"empty state bucket"* ]]
  [ ! -f "$BASELINE" ] || {
    echo "a refused capture still wrote a baseline"
    return 1
  }
}

@test "PRESERVE capture requires a secret and an account, so a hollow baseline is impossible" {
  run "$CHECKER" --capture --project changeme-project \
    --state-bucket changeme-project-osramp-tfstate --baseline "$BASELINE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"at least one --secret"* ]]

  run "$CHECKER" --capture --project changeme-project \
    --state-bucket changeme-project-osramp-tfstate \
    --secret sl-demo-tailscale-authkey --baseline "$BASELINE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--service-account or --sa-prefix"* ]]
}

# ---------------------------------------------------------------------------
# The runtime guard -- verify
# ---------------------------------------------------------------------------

@test "PRESERVE the all-clear estate verifies green" {
  # The paired positive for every negative below. A checker that always reported
  # a regression would satisfy all of them.
  capture_baseline
  verify_against ""
  [ "$status" -eq 0 ] || {
    echo "$output"
    return 1
  }
  [[ "$output" == *"0 regression(s)"* ]]
  [[ "$output" == *"0 unchecked"* ]]
  [ "$(count_matching '^REGRESSION')" = "0" ]
}

@test "PRESERVE a deleted state bucket is a regression, not an unknown" {
  capture_baseline
  verify_against "state-bucket-gone"
  [ "$status" -eq 1 ] || {
    echo "expected exit 1, got ${status}: $output"
    return 1
  }
  [[ "$output" == *"THE BUCKET IS GONE"* ]]
  [[ "$output" == *"changeme-project-osramp-tfstate"* ]]
}

@test "PRESERVE an unreadable state bucket is an unknown, not a regression" {
  # The distinction that keeps the report trustworthy. An expired credential and
  # a deleted bucket are the same non-zero gcloud exit; reporting the first as
  # data loss trains the operator to ignore the second.
  capture_baseline
  verify_against "state-bucket-unreadable"
  [ "$status" -eq 3 ] || {
    echo "expected exit 3, got ${status}: $output"
    return 1
  }
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" == *"NOT a clean result"* ]]
  [ "$(count_matching '^REGRESSION')" = "0" ] || {
    echo "a permission error was reported as a regression"
    return 1
  }
}

@test "PRESERVE --allow-unknown downgrades an unknown but never a regression" {
  capture_baseline

  export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/state-bucket-unreadable"
  run "$CHECKER" --baseline "$BASELINE" --allow-unknown
  [ "$status" -eq 0 ] || {
    echo "expected 0 with --allow-unknown, got ${status}"
    return 1
  }

  # The paired half: the flag must not launder a real regression.
  export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/state-bucket-gone"
  run "$CHECKER" --baseline "$BASELINE" --allow-unknown
  [ "$status" -eq 1 ] || {
    echo "--allow-unknown suppressed a REGRESSION; got ${status}"
    echo "$output"
    return 1
  }
}

@test "PRESERVE an emptied state bucket is caught, though the bucket still exists" {
  # The hollow-resource case. `describe` returns 0 for this bucket; a naive
  # existence check calls it healthy while every root's state is gone.
  capture_baseline
  verify_against "state-bucket-empty"
  [ "$status" -eq 1 ]
  [[ "$output" == *"THE STATE BUCKET IS EMPTY"* ]]
  [[ "$output" == *"baseline had 6 objects"* ]]
}

@test "PRESERVE one emptied prefix is caught even while the bucket looks healthy" {
  capture_baseline
  verify_against "state-prefix-emptied"
  [ "$status" -eq 1 ]
  [[ "$output" == *"environments/"* ]]
  [[ "$output" == *"prefix emptied"* ]]
  # The other prefixes must still report OK, or the message names the wrong
  # blast radius and the operator looks in the wrong place.
  [[ "$output" == *"bootstrap/"* ]]
  [ "$(count_matching '^OK .*bootstrap/')" = "1" ] || {
    echo "the surviving prefixes did not report OK; the blast radius is misreported"
    echo "$output"
    return 1
  }
}

@test "PRESERVE a partial object deletion under a prefix is caught" {
  capture_baseline
  verify_against "state-prefix-shrank"
  [ "$status" -eq 1 ]
  [[ "$output" == *"objects deleted: baseline 2, live 1"* ]]
}

@test "PRESERVE versioning turned off on the state bucket is a regression" {
  capture_baseline
  verify_against "versioning-off"
  [ "$status" -eq 1 ]
  [[ "$output" == *"versioning"* ]]
  [[ "$output" == *"baseline 'true', live 'false'"* ]]
}

@test "PRESERVE a changed retention policy is a regression" {
  capture_baseline
  verify_against "retention-changed"
  [ "$status" -eq 1 ]
  [[ "$output" == *"retention_seconds"* ]]
  [[ "$output" == *"live '86400'"* ]]
}

@test "PRESERVE a deleted secret is a regression" {
  capture_baseline
  verify_against "secret-gone"
  [ "$status" -eq 1 ]
  [[ "$output" == *"THE SECRET IS GONE"* ]]
}

@test "PRESERVE a secret whose versions are all DESTROYED is a regression" {
  # The shape the brief called out: the secret still exists, still describes
  # cleanly, and cannot start a VM.
  capture_baseline
  verify_against "secret-all-destroyed"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO ENABLED VERSION"* ]]
  [[ "$output" == *"unusable"* ]]
  # And the existence check itself passed, which is the whole point.
  [[ "$output" == *"OK          secret sl-demo-tailscale-authkey "* ]] || {
    echo "expected the secret to still report OK for existence:"
    echo "$output"
    return 1
  }
}

@test "PRESERVE a secret whose versions are all DISABLED is a regression" {
  # DISABLED and DESTROYED are different states and both mean no usable key.
  # Checking only for DESTROYED would miss the rotation that was half-finished.
  capture_baseline
  verify_against "secret-all-disabled"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO ENABLED VERSION"* ]]
}

@test "PRESERVE a deleted service account is a regression" {
  capture_baseline
  verify_against "sa-gone"
  [ "$status" -eq 1 ]
  [[ "$output" == *"THE SERVICE ACCOUNT IS GONE"* ]]
  [[ "$output" == *"sl-deploy@"* ]]
}

@test "PRESERVE a disabled service account is a regression, though it still exists" {
  capture_baseline
  verify_against "sa-disabled"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists but is DISABLED"* ]]
}

@test "PRESERVE the whole cloud being unreachable is unknown, never green" {
  capture_baseline
  export STUB_GCLOUD_FAIL=1
  run "$CHECKER" --baseline "$BASELINE"
  [ "$status" -eq 3 ] || {
    echo "expected exit 3 when nothing can be read, got ${status}"
    echo "$output"
    return 1
  }
  [ "$(count_matching '^REGRESSION')" = "0" ]
}

# ---------------------------------------------------------------------------
# Vacuous-pass guards on the verifier itself
# ---------------------------------------------------------------------------

@test "PRESERVE verify refuses a baseline that protects nothing" {
  # A manifest with empty lists reports nothing and would exit 0 -- the purest
  # vacuous pass, and the one a preservation guard can least afford.
  local hollow="${BATS_TEST_TMPDIR}/hollow.json"
  jq -n '{schema: 1, captured_at: "x", project: "changeme-project",
          buckets: [], secrets: [], service_accounts: []}' >"$hollow"

  run "$CHECKER" --baseline "$hollow"
  [ "$status" -eq 2 ] || {
    echo "a hollow baseline was accepted: status ${status}"
    echo "$output"
    return 1
  }
  [[ "$output" == *"protects no buckets"* ]]
}

@test "PRESERVE verify refuses a baseline whose state bucket recorded zero objects" {
  local hollow="${BATS_TEST_TMPDIR}/hollow-objects.json"
  capture_baseline
  jq '(.buckets[] | select(.role == "state") | .total_objects) = 0
      | (.buckets[] | select(.role == "state") | .prefixes) = []' \
    "$BASELINE" >"$hollow"

  run "$CHECKER" --baseline "$hollow"
  [ "$status" -eq 2 ]
  [[ "$output" == *"zero objects"* ]]
}

@test "PRESERVE verify refuses a missing baseline rather than reporting nothing wrong" {
  run "$CHECKER" --baseline "${BATS_TEST_TMPDIR}/does-not-exist.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no baseline"* ]]
  [[ "$output" == *"--capture"* ]]
}

@test "PRESERVE verify refuses a baseline written by a different schema" {
  capture_baseline
  local wrong="${BATS_TEST_TMPDIR}/wrong-schema.json"
  jq '.schema = 99' "$BASELINE" >"$wrong"

  run "$CHECKER" --baseline "$wrong"
  [ "$status" -eq 2 ]
  [[ "$output" == *"re-capture"* ]]
}

@test "PRESERVE every gcloud call the verifier made was read-only" {
  # An assertion about what actually ran, not about what the source appears to
  # do. This is the check that would catch a mutating call added inside a helper
  # that bypasses gcloud_ro entirely.
  capture_baseline
  verify_against ""
  [ "$status" -eq 0 ]

  [ -s "$CALL_LOG" ] || {
    echo "the call log is empty; this test scanned nothing"
    return 1
  }
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case " $line " in
      *' describe '* | *' list '* | *' version '* | *' get-iam-policy '*) ;;
      *)
        echo "a non-read-only call was made: gcloud ${line}"
        return 1
        ;;
    esac
  done <"$CALL_LOG"
}

@test "PRESERVE MUTATION existence-only: a naive checker calls all three hollow estates clean" {
  # THE MUTATION THAT MATTERS MOST. Every hollow-resource check guards CONTENT
  # rather than a name, and this proves the content checks are the thing doing
  # the work: strip each one back to "the resource exists" -- exactly the
  # careless check the design set out to beat -- and all three defects go green.
  #
  # One sed per scenario, each independently asserted by mutate(), rather than
  # three chained in one program. A chained sed passes mutate()'s changed-file
  # test as long as ANY of its parts matched, so a stale pattern among them
  # would silently leave that scenario running against unmutated code.
  #
  # Each mutation returns early rather than neutering a single `if`, because the
  # emptied-bucket case is caught TWICE over -- once by the bucket total and
  # again by the per-prefix comparison. Neutering only the total leaves the
  # second check to catch it, which is defence in depth working correctly and
  # which is why the first version of this test failed.
  capture_baseline

  local naive scenario rc
  local -a cases=(
    # scenario                 sed program producing an existence-only check
    "state-bucket-empty|s|^  \[ \"\$role\" = \"state\" \] \|\| return 0\$|  return 0|"
    "secret-all-destroyed|s|^  report OK \"secret \${secret}\" \"exists\"\$|  report OK \"secret \${secret}\" \"exists\"; return 0|"
    "sa-disabled|s|^  if \[ \"\$disabled\" = \"true\" \]; then\$|  if false; then|"
  )

  local entry
  for entry in "${cases[@]}"; do
    scenario="${entry%%|*}"
    local program="${entry#*|}"

    naive="${BATS_TEST_TMPDIR}/naive-${scenario}.sh"
    mutate "$CHECKER" "$program" "$naive"

    export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/${scenario}"

    rc=0
    "$naive" --baseline "$BASELINE" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || {
      echo "${scenario}: the existence-only checker returned ${rc}, expected 0."
      echo "the mutation did not remove what this test claims it removes."
      "$naive" --baseline "$BASELINE" 2>&1 | grep -E 'REGRESSION|UNKNOWN' || true
      return 1
    }

    # The paired half. Without it this test would pass against a checker that
    # was broken in some third way, since both runs would then be non-green.
    rc=0
    "$CHECKER" --baseline "$BASELINE" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || {
      echo "${scenario}: the real checker returned ${rc}, expected 1"
      return 1
    }
  done
}

@test "PRESERVE MUTATION not-found-as-unknown: collapsing the two hides a deleted bucket" {
  # Proves the NOT_FOUND / PERMISSION_DENIED classification is load-bearing.
  # Collapse it and a deleted state bucket downgrades from "unrecoverable data
  # loss, exit 1" to "could not check, exit 3" -- which reads like a flaky run.
  capture_baseline

  local blind="${BATS_TEST_TMPDIR}/blind-check.sh"
  mutate "$CHECKER" \
    "s|if grep -qiE 'NOT_FOUND\|not found\|404\|does not exist\|no such' \"\$err\"; then|if false; then|" \
    "$blind"

  export STUB_FIXTURE_OVERLAY="${GCP_FIXTURES}/state-bucket-gone"
  local rc=0
  "$blind" --baseline "$BASELINE" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || {
    echo "expected the blinded checker to report 3 (unknown), got ${rc}"
    return 1
  }

  rc=0
  "$CHECKER" --baseline "$BASELINE" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "the real checker did not report the deleted bucket as a regression: ${rc}"
    return 1
  }
}
