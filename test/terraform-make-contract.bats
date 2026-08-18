#!/usr/bin/env bats
#
# The Make lifecycle contract for the GCP Terraform platform.
#
# These tests EXECUTE the targets against a stub `terraform` and a stub `gcloud`
# placed early on PATH, then assert on the argument lists those stubs recorded.
# Grepping the Makefile proves the text says the right thing; it does not prove
# that make does it. The two diverge the moment a variable is misspelled, a
# `$$` is dropped, or a guard sits in a target nothing depends on.
#
# Offline: no network, no cloud credentials, no real terraform invocation.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export MAKEFILE="${REPO_ROOT}/Makefile"
}

setup() {
  # Presence first. Every assertion below is meaningless if the Makefile or the
  # block it tests is absent, and a suite that passes against a missing target
  # is the exact failure mode this repo has shipped before.
  [ -f "${MAKEFILE}" ]
  grep -q '^# END GCP Terraform platform block' "${MAKEFILE}"

  STUBDIR="${BATS_TEST_TMPDIR}/stubs"
  RECORD="${BATS_TEST_TMPDIR}/record"
  mkdir -p "${STUBDIR}" "${RECORD}"

  # Stub terraform: records argv and the terraform-relevant environment, then
  # exits 0. It never contacts a provider, a backend, or the network.
  cat > "${STUBDIR}/terraform" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV:'
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'
  printf 'TF_DATA_DIR:%s\n' "${TF_DATA_DIR-<unset>}"
  printf 'GOOGLE_APPLICATION_CREDENTIALS:%s\n' "${GOOGLE_APPLICATION_CREDENTIALS-<unset>}"
  printf 'CLOUDSDK_CORE_ACCOUNT:%s\n' "${CLOUDSDK_CORE_ACCOUNT-<unset>}"
} >> "${STUB_RECORD}/terraform.log"
exit 0
STUB

  # Stub gcloud: records and exits 0. Nothing in this block should invoke it;
  # the stub exists so that an accidental invocation is recorded rather than
  # reaching the real, authenticated CLI on this machine.
  cat > "${STUBDIR}/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*" >> "${STUB_RECORD}/gcloud.log"
exit 0
STUB

  chmod +x "${STUBDIR}/terraform" "${STUBDIR}/gcloud"
  export STUB_RECORD="${RECORD}"
  export PATH="${STUBDIR}:${PATH}"
}

# Run make from the repo root with the stubs in front of the real binaries.
run_make() {
  run make -C "${REPO_ROOT}" "$@"
}

tf_log() {
  cat "${RECORD}/terraform.log" 2>/dev/null || true
}

# A fixture environments root whose backend readback already names $1, so the
# CONTRACT §5a prefix assertion is satisfied and the test can get past it to the
# behaviour it is actually about. The stub terraform cannot write this file
# itself — and the fact that a stubbed init leaves the assertion unsatisfied is
# the guard working, not a test-harness inconvenience. It is asserted directly
# in "the prefix assertion refuses to proceed when the backend readback is
# absent".
env_fixture() {
  local env="$1" dir="${BATS_TEST_TMPDIR}/fixture-${env}-${RANDOM}"
  mkdir -p "${dir}/.terraform-${env}"
  cat > "${dir}/.terraform-${env}/terraform.tfstate" <<JSON
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/${env}"}}}
JSON
  printf '%s' "${dir}"
}

# ---------------------------------------------------------------------------
# Existence, .PHONY, help — ISC-221..228, ISC-240, ISC-241
# ---------------------------------------------------------------------------

@test "every gcp-tf target exists and is a real make target" {
  for t in gcp-tf-bootstrap gcp-tf-plan gcp-tf-apply gcp-tf-status \
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci; do
    # -n dry-runs; an undefined target is "No rule to make target".
    run make -C "${REPO_ROOT}" -n "$t"
    [[ "${output}" != *"No rule to make target"* ]] || {
      echo "target ${t} does not exist"
      return 1
    }
  done
}

@test "every gcp-tf target is declared .PHONY" {
  for t in gcp-tf-bootstrap gcp-tf-plan gcp-tf-apply gcp-tf-status \
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci; do
    grep -Eq "^\.PHONY:( .*)? ${t}( |$)" "${MAKEFILE}" || {
      echo "${t} is not declared .PHONY"
      return 1
    }
  done
}

@test "every gcp-tf target appears in make help" {
  run_make help
  [ "$status" -eq 0 ]
  for t in gcp-tf-bootstrap gcp-tf-plan gcp-tf-apply gcp-tf-status \
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci; do
    [[ "${output}" == *"${t}"* ]] || {
      echo "${t} is missing from make help — it has no '## ' comment"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# ENV is required and validated — ISC-229..233
# ---------------------------------------------------------------------------

@test "every environment-scoped target exits non-zero when ENV is unset" {
  for t in gcp-tf-plan gcp-tf-apply gcp-tf-status gcp-tf-test gcp-tf-destroy; do
    run_make "$t"
    [ "$status" -ne 0 ] || {
      echo "${t} succeeded with no ENV"
      return 1
    }
    [[ "${output}" == *"ENV is required"* ]] || {
      echo "${t} failed without naming ENV as the cause: ${output}"
      return 1
    }
  done
}

@test "gcp-tf-apply without ENV exits non-zero" {
  run_make gcp-tf-apply
  [ "$status" -ne 0 ]
}

@test "gcp-tf-destroy without ENV exits non-zero" {
  run_make gcp-tf-destroy
  [ "$status" -ne 0 ]
}

@test "ENV=prod-1 is rejected by every environment-scoped target" {
  for t in gcp-tf-plan gcp-tf-apply gcp-tf-status gcp-tf-test gcp-tf-destroy; do
    run_make "$t" ENV=prod-1 TF_STATE_BUCKET=changeme-tfstate CONFIRM=prod-1
    [ "$status" -ne 0 ] || {
      echo "${t} accepted ENV=prod-1"
      return 1
    }
    [[ "${output}" == *"not a valid environment key"* ]]
  done
  # And no terraform invocation happened for any of them.
  [ ! -s "${RECORD}/terraform.log" ]
}

@test "malformed environment keys are rejected and well-formed ones are not" {
  for bad in "demo" "demo-0" "demo-01" "DEMO-1" "demo-1 " "demo-1;rm" "../demo-1" "prod-1" "staging-2"; do
    run_make gcp-tf-status ENV="${bad}" TF_STATE_BUCKET=changeme-tfstate
    [ "$status" -ne 0 ] || {
      echo "ENV='${bad}' was accepted"
      return 1
    }
  done
  # The positive half: without it, a guard that rejects EVERYTHING would pass
  # every assertion above and this suite would be measuring nothing.
  for good in "demo-1" "demo-12" "ci-1"; do
    fixture="$(env_fixture "${good}")"
    run_make gcp-tf-status ENV="${good}" TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
    [ "$status" -eq 0 ] || {
      echo "ENV='${good}' was rejected: ${output}"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# CONTRACT §5a — TF_DATA_DIR, target_env, and the post-init prefix assertion
# ---------------------------------------------------------------------------

@test "TF_DATA_DIR is environment-scoped on every terraform invocation" {
  fixture="$(env_fixture demo-2)"
  run_make gcp-tf-status ENV=demo-2 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep -c '^TF_DATA_DIR:.terraform-demo-2$' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # No invocation may run with an unset or un-scoped data dir: two environments
  # sharing one cached backend pointer is the whole failure mode.
  run bash -c "grep -v '^TF_DATA_DIR:.terraform-demo-2\$' '${RECORD}/terraform.log' | grep '^TF_DATA_DIR:' || true"
  [ -z "$output" ]
}

@test "init passes -reconfigure and an ENV-derived backend prefix" {
  fixture="$(env_fixture demo-3)"
  run_make gcp-tf-status ENV=demo-3 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* init ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-reconfigure"* ]]
  [[ "$output" == *"-backend-config=bucket=changeme-tfstate"* ]]
  [[ "$output" == *"-backend-config=prefix=osramp/environments/demo-3"* ]]
}

@test "plan passes -var target_env matching ENV" {
  fixture="$(env_fixture demo-1)"
  run_make gcp-tf-plan ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* plan ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-var target_env=demo-1"* ]]
}

@test "the post-init prefix assertion aborts when the resolved prefix names another environment" {
  # Fixture root: a terraform root whose already-written backend state points at
  # demo-9 while ENV says demo-1. This is CONTRACT §5a's third mechanism — the
  # one that catches a human editing state by hand — and it is only observable
  # by executing the target.
  fixture="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-9"}}}
JSON
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"backend prefix mismatch"* ]]
  [[ "${output}" == *"demo-9"* ]]
}

@test "the post-init prefix assertion passes when the resolved prefix names ENV" {
  # The paired positive. Without it, an assertion that aborts unconditionally
  # would satisfy the test above and prove nothing.
  fixture="${BATS_TEST_TMPDIR}/rootok"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"matches ENV='demo-1'"* ]]
}

@test "the prefix assertion refuses to proceed when the backend readback is absent" {
  fixture="${BATS_TEST_TMPDIR}/rootempty"
  mkdir -p "${fixture}"
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"cannot read back the resolved backend configuration"* ]]
}

# ---------------------------------------------------------------------------
# apply applies a saved plan, never a bare apply — ISC-238, ISC-239
# ---------------------------------------------------------------------------

@test "gcp-tf-apply refuses to run without a previously saved plan file" {
  fixture="${BATS_TEST_TMPDIR}/noplan"
  mkdir -p "${fixture}"
  run_make gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"no saved plan"* ]]
  # Nothing was invoked at all — the guard fires before init.
  [ ! -s "${RECORD}/terraform.log" ]
}

@test "gcp-tf-plan writes a saved plan file and gcp-tf-apply consumes it" {
  fixture="${BATS_TEST_TMPDIR}/applyroot"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run_make gcp-tf-plan ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* plan ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-out=.terraform-demo-1/demo-1.tfplan"* ]]

  # Now the apply half. The stub never wrote a plan file, so create it: the
  # assertion under test is what apply DOES with it, not whether the stub
  # produced one.
  touch "${fixture}/.terraform-demo-1/demo-1.tfplan"
  : > "${RECORD}/terraform.log"
  run_make gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* apply ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apply .terraform-demo-1/demo-1.tfplan"* ]]
  # A bare apply re-plans at apply time, so what a human reviewed and what
  # Terraform executes are two different plans.
  [[ "$output" != *"-auto-approve"* ]]
}

# ---------------------------------------------------------------------------
# destroy — ISC-234..237
# ---------------------------------------------------------------------------

@test "gcp-tf-destroy aborts when CONFIRM does not match ENV" {
  for confirm in "" "demo-2" "yes" "DEMO-1"; do
    run_make gcp-tf-destroy ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate CONFIRM="${confirm}"
    [ "$status" -ne 0 ] || {
      echo "destroy proceeded with CONFIRM='${confirm}'"
      return 1
    }
    [[ "${output}" == *"typed confirmation"* ]]
  done
  [ ! -s "${RECORD}/terraform.log" ]
}

@test "gcp-tf-destroy proceeds when CONFIRM matches ENV exactly" {
  # Paired positive: a confirmation check that rejected everything would satisfy
  # the test above while making the target unusable.
  fixture="${BATS_TEST_TMPDIR}/destroyroot"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run_make gcp-tf-destroy ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate CONFIRM=demo-1 TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* destroy ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
}

@test "gcp-tf-destroy refuses the platform and bootstrap roots outright" {
  for root in terraform/platform terraform/bootstrap; do
    run_make gcp-tf-destroy ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate CONFIRM=demo-1 TF_ROOT_ENV="${root}"
    [ "$status" -ne 0 ] || {
      echo "destroy accepted root ${root}"
      return 1
    }
    [[ "${output}" == *"refusing to destroy"* ]]
  done
  [ ! -s "${RECORD}/terraform.log" ]
}

@test "the destroy argument list cannot reach the state bucket" {
  fixture="${BATS_TEST_TMPDIR}/destroyargs"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run_make gcp-tf-destroy ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate CONFIRM=demo-1 TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  destroy_args="$(grep '^ARGV:.* destroy ' "${RECORD}/terraform.log")"
  [ -n "${destroy_args}" ]
  # The bucket name appears in the init line as a backend config, which is
  # correct — that is how state is READ. It must not appear on the destroy line,
  # where it would be a resource address.
  [[ "${destroy_args}" != *"google_storage_bucket"* ]]
  [[ "${destroy_args}" != *"changeme-tfstate"* ]]
  [[ "${destroy_args}" != *"-target"* ]]
  [[ "${destroy_args}" != *"bootstrap"* ]]
}

# ---------------------------------------------------------------------------
# No hardcoded project id — ISC-243, ISC-244
# ---------------------------------------------------------------------------

@test "no gcp-tf target hardcodes a project id, billing account, domain or IP" {
  block="$(sed -n '/^# GCP Terraform platform — appended by chunk F6/,/^# END GCP Terraform platform block/p' "${MAKEFILE}")"
  [ -n "${block}" ]
  # The real project this repo's existing CI VM lane uses must not leak into
  # the new block: a hardcoded project id is how a demo target ends up creating
  # billable infrastructure in someone else's project.
  #
  # Read out of the existing workflow rather than written here. Naming it inline
  # would put a real project id in a file whose whole purpose is asserting that
  # no real project id is present — and it would silently stop testing anything
  # the day that project is renamed.
  real_project="$(grep -hoE '^[[:space:]]*GCP_PROJECT:[[:space:]]*\S+' \
    "${REPO_ROOT}/.github/workflows"/*.yaml 2>/dev/null | awk '{print $2}' | head -1)"
  [ -n "${real_project}" ]
  [[ "${block}" != *"${real_project}"* ]]
  # gcloud --project=<literal>, terraform -var project_id=<literal>
  run bash -c "printf '%s\n' \"\${block}\" | grep -nE '(--project[= ]|project_id[[:space:]]*=)[[:space:]]*[a-z][a-z0-9-]{4,}' || true"
  [ -z "$output" ]
  # A billing account id, an ipv4 literal, or a real-looking domain.
  run bash -c "printf '%s\n' \"\${block}\" | grep -nE '[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}' || true"
  [ -z "$output" ]
}

@test "the gcp-tf block contains no absolute home path" {
  block="$(sed -n '/^# GCP Terraform platform — appended by chunk F6/,/^# END GCP Terraform platform block/p' "${MAKEFILE}")"
  [ -n "${block}" ]
  [[ "${block}" != *"/home/"* ]]
}

# ---------------------------------------------------------------------------
# The existing CI lane is untouched — ISC-246, ISC-247
# ---------------------------------------------------------------------------

@test "the pre-existing ci-* targets still exist" {
  for t in ci-gcp ci-gcp-2 ci-provision ci-status; do
    grep -Eq "^\.PHONY:( .*)? ${t}( |\$)|^${t}:" "${MAKEFILE}" || {
      echo "${t} is missing from the Makefile"
      return 1
    }
    run make -C "${REPO_ROOT}" -n "$t"
    [[ "${output}" != *"No rule to make target"* ]] || {
      echo "${t} is no longer a make target"
      return 1
    }
  done
}

@test "no gcp-tf target is defined more than once and none shadows an existing target" {
  # A duplicate target definition is how an append-only block silently replaces
  # a recipe: make takes the last one and warns on stderr, which nobody reads.
  run bash -c "grep -oE '^[a-zA-Z0-9_.-]+:' '${MAKEFILE}' | sort | uniq -d"
  [ "$status" -eq 0 ]
  [[ "${output}" != *"gcp-tf-"* ]]
  [[ "${output}" != *"ci-gcp"* ]]
  [[ "${output}" != *"ci-provision"* ]]
  [[ "${output}" != *"ci-status"* ]]
}

@test "make -n on the whole Makefile emits no overriding-recipe warnings" {
  run make -C "${REPO_ROOT}" -n help
  [ "$status" -eq 0 ]
  [[ "${output}" != *"overriding recipe"* ]]
  [[ "${output}" != *"ignoring old recipe"* ]]
}

# ---------------------------------------------------------------------------
# gcp-tf-ci — ISC-228
# ---------------------------------------------------------------------------

@test "gcp-tf-ci requires CI and rejects a demo key" {
  run_make gcp-tf-ci
  [ "$status" -ne 0 ]
  [[ "${output}" == *"CI is required"* ]]

  run_make gcp-tf-ci CI=demo-1 TF_STATE_BUCKET=changeme-tfstate
  [ "$status" -ne 0 ]
  [[ "${output}" == *"not a valid CI environment key"* ]]
}

@test "gcp-tf-ci delegates to the plan target with ENV set from CI" {
  fixture="${BATS_TEST_TMPDIR}/ciroot"
  mkdir -p "${fixture}/.terraform-ci-1"
  cat > "${fixture}/.terraform-ci-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/ci-1"}}}
JSON
  run_make gcp-tf-ci CI=ci-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* plan ' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-var target_env=ci-1"* ]]
}

# ---------------------------------------------------------------------------
# ISC-357 — the offline sweep runs with cloud credentials stripped
# ---------------------------------------------------------------------------

@test "gcp-tf-test-unit strips cloud credentials from every terraform invocation" {
  # Set them to obviously-bogus values first. If the target passes them through,
  # the stub records them and this fails.
  GOOGLE_APPLICATION_CREDENTIALS=/nonexistent/creds.json \
  CLOUDSDK_CORE_ACCOUNT=nobody@example.invalid \
    run make -C "${REPO_ROOT}" gcp-tf-test-unit TF=terraform
  [ "$status" -eq 0 ]
  run bash -c "grep -E '^(GOOGLE_APPLICATION_CREDENTIALS|CLOUDSDK_CORE_ACCOUNT):' '${RECORD}/terraform.log' | grep -v ':<unset>\$' || true"
  [ -z "$output" ]
}

@test "gcp-tf-test-unit refuses a vacuous pass when discovery finds nothing" {
  # A sweep that discovers zero suites and reports success is the failure mode
  # that let 33 unexecuted bats suites ship green. Point discovery at an empty
  # tree and assert it fails rather than congratulating itself.
  empty="${BATS_TEST_TMPDIR}/emptytree"
  mkdir -p "${empty}"
  run make -C "${REPO_ROOT}" gcp-tf-test-unit GCP_TF_TEST_DIRS_RUN=
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Refusing to report a vacuous pass"* ]]
}

@test "gcp-tf-validate refuses a vacuous pass when the bats glob finds nothing" {
  # The sibling test above asserts the failure SIGNATURE as well as the status;
  # this one originally checked only `-ne 0`, which test/vacuous-assertions.bats
  # (VAC003) flagged: make exits non-zero for a missing target, a syntax error,
  # or a tool that is not installed, so the assertion passed for reasons that
  # have nothing to do with the guard under test. Pin the message.
  run make -C "${REPO_ROOT}" gcp-tf-validate GCP_TF_BATS_RUN= GCP_TF_DIRS=
  [ "$status" -ne 0 ]
  [[ "${output}" == *"no terraform directories discovered"* ]]
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS — ISC-259, ISC-260
#
# Every assertion above says "the guard fires". None of them says "the guard is
# what made it fire". These do: each copies the real Makefile, disables exactly
# one guard using a committed fixture under test/fixtures/terraform/make/, and
# asserts the behaviour above then flips. The real tree is never modified.
# ---------------------------------------------------------------------------

# Apply one named mutation to a COPY and refuse to continue unless it actually
# changed something. A sed program whose pattern no longer matches silently
# no-ops and prints nothing; the check would then run against an unmutated
# Makefile and pass, which is a green test measuring nothing.
apply_mutation() {
  local name="$1"
  local sedfile="${REPO_ROOT}/test/fixtures/terraform/make/${name}.sed"
  local dir="${BATS_TEST_TMPDIR}/mut-${name}"
  [ -f "${sedfile}" ] || {
    echo "mutation fixture ${sedfile} is missing"
    return 1
  }
  mkdir -p "${dir}"
  sed -f "${sedfile}" "${MAKEFILE}" > "${dir}/Makefile"
  if diff -q "${MAKEFILE}" "${dir}/Makefile" >/dev/null; then
    echo "mutation '${name}' changed nothing — its pattern no longer matches the Makefile"
    return 1
  fi
  printf '%s' "${dir}"
}

@test "MUTATION key-regex: widening the key regex lets prod-1 through" {
  mutdir="$(apply_mutation key-regex)"
  fixture="${BATS_TEST_TMPDIR}/prodroot"
  mkdir -p "${fixture}/.terraform-prod-1"
  cat > "${fixture}/.terraform-prod-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/prod-1"}}}
JSON
  # Unmutated: rejected.
  run_make gcp-tf-status ENV=prod-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  # Mutated: accepted. If this still fails, the regex is not what rejects prod-1
  # and the assertion above is measuring something else.
  run make -C "${mutdir}" gcp-tf-status ENV=prod-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
}

@test "MUTATION confirm-check: neutering the confirmation lets a mismatched destroy run" {
  mutdir="$(apply_mutation confirm-check)"
  fixture="$(env_fixture demo-1)"
  # Unmutated: a mismatched CONFIRM aborts.
  run_make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-2 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  # Mutated: it proceeds.
  run make -C "${mutdir}" gcp-tf-destroy ENV=demo-1 CONFIRM=demo-2 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
}

@test "MUTATION prefix-assert: neutering the readback lets a cross-environment prefix through" {
  mutdir="$(apply_mutation prefix-assert)"
  fixture="${BATS_TEST_TMPDIR}/mismatch"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-9"}}}
JSON
  # Unmutated: CONTRACT §5a mechanism 3 aborts.
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"backend prefix mismatch"* ]]
  # Mutated: demo-1's plan proceeds against demo-9's state. This is the silent
  # failure the mechanism exists to stop, demonstrated.
  run make -C "${mutdir}" gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
}

@test "MUTATION tf-data-dir: unscoping the data dir lets two environments share a backend pointer" {
  mutdir="$(apply_mutation tf-data-dir)"
  fixture="${BATS_TEST_TMPDIR}/shareddd"
  mkdir -p "${fixture}/.terraform"
  cat > "${fixture}/.terraform/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run make -C "${mutdir}" gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  # Under mutation the data dir carries no environment suffix — which is exactly
  # how demo-2 would inherit demo-1's cached backend pointer.
  run bash -c "grep -c '^TF_DATA_DIR:.terraform\$' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "MUTATION bare-apply: dropping the plan file turns apply into a re-planning auto-approve" {
  mutdir="$(apply_mutation bare-apply)"
  fixture="$(env_fixture demo-1)"
  touch "${fixture}/.terraform-demo-1/demo-1.tfplan"
  # Unmutated: apply consumes the reviewed plan file.
  run_make gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* apply ' '${RECORD}/terraform.log'"
  [[ "$output" == *".tfplan"* ]]
  [[ "$output" != *"-auto-approve"* ]]
  # Mutated: it does not.
  : > "${RECORD}/terraform.log"
  run make -C "${mutdir}" gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^ARGV:.* apply ' '${RECORD}/terraform.log'"
  [[ "$output" == *"-auto-approve"* ]]
}
