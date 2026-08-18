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
  #
  # It does three things beyond recording, each of which exists because a target
  # under test consumes terraform's *output*, not just its exit code:
  #
  #   plan -out=F   writes F, so `gcp-tf-up`'s "did this run create the plan I am
  #                 about to apply?" check has something real to decide about.
  #                 STUB_TF_NO_PLAN_FILE=1 suppresses it and STUB_TF_PLAN_MTIME
  #                 backdates it, so both halves of that check are reachable.
  #   show          emits a plan summary line, so the summary step is observable.
  #   output -json  emits the fixture in STUB_TF_OUTPUT_JSON (or a default that
  #                 models a fully-wired root), so the hand-off generator has
  #                 real JSON to derive from.
  cat > "${STUBDIR}/terraform" <<'STUB'
#!/usr/bin/env bash
{
  printf 'ARGV:'
  for a in "$@"; do printf ' %s' "$a"; done
  printf '\n'
  printf 'TF_DATA_DIR:%s\n' "${TF_DATA_DIR-<unset>}"
  printf 'GOOGLE_APPLICATION_CREDENTIALS:%s\n' "${GOOGLE_APPLICATION_CREDENTIALS-<unset>}"
  printf 'CLOUDSDK_CORE_ACCOUNT:%s\n' "${CLOUDSDK_CORE_ACCOUNT-<unset>}"
  printf 'GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:%s\n' "${GOOGLE_IMPERSONATE_SERVICE_ACCOUNT-<unset>}"
} >> "${STUB_RECORD}/terraform.log"

stub_chdir=""
stub_verb=""
stub_out=""
stub_json=0
for a in "$@"; do
  case "$a" in
    -chdir=*) stub_chdir="${a#-chdir=}" ;;
    -out=*)   stub_out="${a#-out=}" ;;
    -json)    stub_json=1 ;;
    -*)       ;;
    *)        [ -z "${stub_verb}" ] && stub_verb="$a" ;;
  esac
done

case "${stub_verb}" in
  plan)
    if [ -n "${stub_out}" ] && [ "${STUB_TF_NO_PLAN_FILE-0}" != "1" ]; then
      target="${stub_out}"
      [ -n "${stub_chdir}" ] && target="${stub_chdir}/${stub_out}"
      mkdir -p "$(dirname "${target}")"
      printf 'stub plan: %s\n' "$*" > "${target}"
      [ -n "${STUB_TF_PLAN_MTIME-}" ] && touch -d "${STUB_TF_PLAN_MTIME}" "${target}"
    fi
    ;;
  show)
    printf 'Terraform will perform the following actions:\n'
    printf '\n'
    printf 'Plan: 3 to add, 0 to change, 0 to destroy.\n'
    ;;
  output)
    if [ "${stub_json}" = "1" ]; then
      if [ -n "${STUB_TF_OUTPUT_JSON-}" ]; then
        cat "${STUB_TF_OUTPUT_JSON}"
      else
        cat <<'JSON'
{
  "target_env": { "value": "demo-1" },
  "target_environment": { "value": {
    "environment_key": "demo-1",
    "name_prefix": "osramp-demo-1",
    "region": "us-east4",
    "zone": "us-east4-a",
    "app_port": 8080,
    "hostname": "demo-1.changeme.invalid"
  } },
  "integration_inputs": { "value": {
    "project_id": "changeme-sandbox",
    "access_mode": "iap"
  } },
  "instance_name": { "value": "osramp-demo-1-vm" },
  "internal_ip": { "value": "10.20.0.7" }
}
JSON
      fi
    fi
    ;;
esac
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

teardown() {
  # gcp-tf-bootstrap is the one target whose root is not redirected by any test:
  # the assertion is about the DEFAULT path, so it plans against
  # terraform/bootstrap for real. The stub writes whatever `-out=` names, which
  # means running this suite leaves a plan file in the working tree. It is
  # gitignored, but an untracked artefact that appears whenever the tests run is
  # still noise a reviewer has to explain away.
  rm -f "${REPO_ROOT}/${TF_ROOT_BOOTSTRAP_DEFAULT}/bootstrap.tfplan"
}

TF_ROOT_BOOTSTRAP_DEFAULT='terraform/bootstrap'

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
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci \
           gcp-tf-up gcp-tf-handoff; do
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
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci \
           gcp-tf-up gcp-tf-handoff; do
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
           gcp-tf-test gcp-tf-test-unit gcp-tf-destroy gcp-tf-validate gcp-tf-ci \
           gcp-tf-up gcp-tf-handoff; do
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
  for t in gcp-tf-plan gcp-tf-apply gcp-tf-status gcp-tf-test gcp-tf-destroy gcp-tf-up gcp-tf-handoff; do
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
  for t in gcp-tf-plan gcp-tf-apply gcp-tf-status gcp-tf-test gcp-tf-destroy gcp-tf-up gcp-tf-handoff; do
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
# bootstrap — ISC-234
# ---------------------------------------------------------------------------

@test "gcp-tf-bootstrap plans using the explicit bootstrap input" {
  run_make gcp-tf-bootstrap
  [ "$status" -eq 0 ]

  plan_args="$(grep '^ARGV:.* plan ' "${RECORD}/terraform.log")"
  [ -n "${plan_args}" ]
  [[ "${plan_args}" == *"-chdir=terraform/bootstrap"* ]]
  [[ "${plan_args}" == *"-var-file=../../deploy/gcp/bootstrap.tfvars"* ]]
  [[ "${plan_args}" == *"-out=bootstrap.tfplan"* ]]
  [[ "${plan_args}" != *" apply "* ]]
  [[ "${output}" == *"apply bootstrap.tfplan"* ]]
}

# ---------------------------------------------------------------------------
# destroy — ISC-235..237
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

# Regression for an adversarial-review finding. The §5a readback was
# `case "$resolved" in *"$(ENV)"*)`, a substring match, so a backend resolved to
# osramp/environments/demo-10 satisfied the assertion for ENV=demo-1. That is
# precisely the hand-edit the mechanism exists to catch, and it was the one case
# it let through — while the typed CONFIRM on destroy still matched, because that
# compares ENV against the operator's typing, not against the resolved state.
@test "a prefix that merely CONTAINS the env key is rejected, not accepted" {
  fixture="${BATS_TEST_TMPDIR}/prefixsuperstring"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-10"}}}
JSON
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"backend prefix mismatch"* ]]
}

@test "the exact-match prefix guard still accepts the genuinely correct prefix" {
  # Paired positive: without this, the test above passes even if the guard
  # started rejecting everything, which is a different bug wearing the same green.
  fixture="${BATS_TEST_TMPDIR}/prefixexact"
  mkdir -p "${fixture}/.terraform-demo-1"
  cat > "${fixture}/.terraform-demo-1/terraform.tfstate" <<'JSON'
{"version":3,"backend":{"type":"gcs","config":{"bucket":"changeme-tfstate","prefix":"osramp/environments/demo-1"}}}
JSON
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}"
  [[ "${output}" != *"backend prefix mismatch"* ]]
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

# ---------------------------------------------------------------------------
# Impersonation — the estate is applied by a service account, never by a human
#
# Every test below pins GCP_TF_DEPLOY_SA_FILE. The default is an untracked file
# that exists on an operator's machine and not on a runner, so a suite that left
# it at the default would assert different things in the two places — and would
# pass in both.
# ---------------------------------------------------------------------------

SA_EMAIL='changeme-deploy@changeme-sandbox.iam.gserviceaccount.com'

# A path that is guaranteed not to exist, so TF_DEPLOY_SA resolves empty.
no_sa_file() {
  printf '%s' "GCP_TF_DEPLOY_SA_FILE=${BATS_TEST_TMPDIR}/no-such-deploy-sa"
}

# A one-line deploy-sa file, as an operator would write it.
sa_file() {
  local f="${BATS_TEST_TMPDIR}/deploy-sa"
  printf '%s\n' "${SA_EMAIL}" > "${f}"
  printf '%s' "${f}"
}

@test "GOOGLE_IMPERSONATE_SERVICE_ACCOUNT is exported on every terraform invocation when GCP_TF_IMPERSONATE is set" {
  fixture="$(env_fixture demo-1)"
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}"
  [ "$status" -eq 0 ]

  # More than one invocation happened, so "every" is a claim about a set with
  # something in it. status runs init, state list and output.
  invocations="$(grep -c '^ARGV:' "${RECORD}/terraform.log")"
  [ "${invocations}" -ge 3 ]

  carried="$(grep -c "^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:${SA_EMAIL}\$" "${RECORD}/terraform.log")"
  [ "${carried}" -eq "${invocations}" ]

  # And not one invocation ran without it. An invocation that slipped through
  # unimpersonated is the whole failure mode: it runs as the human.
  run bash -c "grep '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:' '${RECORD}/terraform.log' | grep -v '${SA_EMAIL}' || true"
  [ -z "$output" ]
}

@test "no terraform invocation carries an impersonation target when none is configured" {
  # The paired negative. Without it, a Makefile that hardcoded the variable
  # would satisfy the test above and prove nothing about GCP_TF_IMPERSONATE.
  fixture="$(env_fixture demo-1)"
  run_make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" GCP_TF_IMPERSONATE=
  [ "$status" -eq 0 ]
  run bash -c "grep '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:' '${RECORD}/terraform.log' | grep -v '<unset>' || true"
  [ -z "$output" ]
}

@test "TF_DEPLOY_SA is read from the deploy-sa file so nobody retypes it" {
  fixture="$(env_fixture demo-1)"
  run_make gcp-tf-plan ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "GCP_TF_DEPLOY_SA_FILE=$(sa_file)"
  [ "$status" -eq 0 ]
  run bash -c "grep -c '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:${SA_EMAIL}\$' '${RECORD}/terraform.log'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "a mutating target refuses to run when impersonation is configured but empty" {
  local sa; sa="$(sa_file)"
  fixture="$(env_fixture demo-1)"
  touch "${fixture}/.terraform-demo-1/demo-1.tfplan"

  for t in gcp-tf-plan gcp-tf-apply gcp-tf-destroy gcp-tf-up; do
    : > "${RECORD}/terraform.log"
    run make -C "${REPO_ROOT}" "$t" ENV=demo-1 CONFIRM=demo-1 \
      TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}" \
      "GCP_TF_DEPLOY_SA_FILE=${sa}" GCP_TF_IMPERSONATE=
    [ "$status" -ne 0 ] || {
      echo "${t} ran as a user identity with a deploy SA configured"
      return 1
    }
    [[ "${output}" == *"impersonation"* ]] || {
      echo "${t} refused without naming impersonation: ${output}"
      return 1
    }
    # The guard fires before anything is invoked. A refusal that happens after
    # init has already touched the backend is not a refusal.
    [ ! -s "${RECORD}/terraform.log" ] || {
      echo "${t} invoked terraform before refusing"
      return 1
    }
  done
}

@test "the refusal names impersonation as the cause and IAM only as the symptom" {
  local sa; sa="$(sa_file)"
  fixture="$(env_fixture demo-1)"
  run make -C "${REPO_ROOT}" gcp-tf-apply ENV=demo-1 \
    TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}" \
    "GCP_TF_DEPLOY_SA_FILE=${sa}" GCP_TF_IMPERSONATE=
  [ "$status" -ne 0 ]
  [[ "${output}" == *"without impersonation"* ]]
  [[ "${output}" == *"half-applied"* ]]
  [[ "${output}" == *"IAM"* ]]
  # Order matters. The observed failure names an IAM permission, which invites
  # widening IAM. If this message led with IAM it would reinforce exactly that.
  imp_at="$(printf '%s\n' "${output}" | grep -n 'impersonation' | head -1 | cut -d: -f1)"
  iam_at="$(printf '%s\n' "${output}" | grep -n 'IAM' | head -1 | cut -d: -f1)"
  [ "${imp_at}" -lt "${iam_at}" ]
}

@test "a mutating target proceeds when impersonation resolves" {
  # Paired positive for the refusal above: a guard that refused unconditionally
  # would satisfy every assertion in that test.
  local sa; sa="$(sa_file)"
  fixture="$(env_fixture demo-1)"
  run make -C "${REPO_ROOT}" gcp-tf-plan ENV=demo-1 \
    TF_STATE_BUCKET=changeme-tfstate TF_ROOT_ENV="${fixture}" \
    "GCP_TF_DEPLOY_SA_FILE=${sa}"
  [ "$status" -eq 0 ]
  [[ "${output}" != *"without impersonation"* ]]
}

@test "the offline sweep strips an inherited impersonation target" {
  # A developer with GOOGLE_IMPERSONATE_SERVICE_ACCOUNT exported must not get a
  # different offline result from a runner that has none.
  run env "GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=${SA_EMAIL}" \
    make -C "${REPO_ROOT}" gcp-tf-test-unit
  [ "$status" -eq 0 ]
  run bash -c "grep '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:' '${RECORD}/terraform.log' | grep -v '<unset>' || true"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# gcp-tf-up — one ordered sequence, applying only a plan it just created
# ---------------------------------------------------------------------------

@test "gcp-tf-up produces a plan file and applies THAT file" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-up"
  run make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]

  # The plan step wrote the file...
  [ -f "${fixture}/.terraform-demo-1/demo-1.tfplan" ]
  grep -q '^stub plan:' "${fixture}/.terraform-demo-1/demo-1.tfplan"

  plan_args="$(grep '^ARGV:.* plan ' "${RECORD}/terraform.log")"
  [[ "${plan_args}" == *"-out=.terraform-demo-1/demo-1.tfplan"* ]]

  # ...and the apply consumed exactly it, with no re-plan at apply time.
  apply_args="$(grep '^ARGV:.* apply ' "${RECORD}/terraform.log")"
  [[ "${apply_args}" == *"apply .terraform-demo-1/demo-1.tfplan"* ]]
  [[ "${apply_args}" != *"-auto-approve"* ]]
}

@test "gcp-tf-up runs init, plan, show, apply and output in that order" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-order"
  run make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]

  at() { grep -n "^ARGV:.* $1" "${RECORD}/terraform.log" | head -1 | cut -d: -f1; }
  n_init="$(at 'init ')"; n_plan="$(at 'plan ')"
  n_show="$(at 'show ')"; n_apply="$(at 'apply ')"
  n_out="$(at 'output -json')"
  for n in "${n_init}" "${n_plan}" "${n_show}" "${n_apply}" "${n_out}"; do
    [ -n "$n" ]
  done
  [ "${n_init}" -lt "${n_plan}" ]
  [ "${n_plan}" -lt "${n_show}" ]
  [ "${n_show}" -lt "${n_apply}" ]
  [ "${n_apply}" -lt "${n_out}" ]

  # The summary the operator reads comes from the saved plan, not from a re-plan.
  [[ "${output}" == *"Plan: 3 to add, 0 to change, 0 to destroy."* ]]
}

@test "gcp-tf-up refuses to apply when the plan step produced no plan file" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-noplan"
  run env STUB_TF_NO_PLAN_FILE=1 \
    make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"Refusing to apply a plan this run did not create"* ]]
  run bash -c "grep '^ARGV:.* apply ' '${RECORD}/terraform.log' || true"
  [ -z "$output" ]
  [ ! -f "${hdir}/demo-1.handoff.json" ]
}

@test "gcp-tf-up refuses a plan file that predates the run" {
  # The second half of the provenance check. A plan file exists — so the
  # existence test above is satisfied — but it is older than the sentinel this
  # invocation stamped, so it is not the diff this run produced.
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-stale"
  run env "STUB_TF_PLAN_MTIME=2020-01-01 00:00:00" \
    make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"predates this run"* ]]
  run bash -c "grep '^ARGV:.* apply ' '${RECORD}/terraform.log' || true"
  [ -z "$output" ]
}

@test "gcp-tf-up carries impersonation through to the sub-make invocations" {
  # gcp-tf-up delegates to gcp-tf-plan and gcp-tf-apply. GCP_TF_IMPERSONATE has a
  # computed default, so it does not reach a sub-make through MAKEFLAGS on its
  # own — an apply that silently lost it is the failure this forwards against.
  local sa; sa="$(sa_file)"
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-forward"
  run make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "GCP_TF_DEPLOY_SA_FILE=${sa}" "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]
  run bash -c "grep '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:' '${RECORD}/terraform.log' | grep -v '${SA_EMAIL}' || true"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# gcp-tf-handoff — one file, no flags, every value derived from state
# ---------------------------------------------------------------------------

# Every key the test code is entitled to rely on. hostname is deliberately not
# here: an environment with no DNS has none, and demanding a non-empty value
# would force a fabricated one.
HANDOFF_REQUIRED='project_id environment_key region zone instance_name internal_ip app_port state_bucket deploy_sa access_mode generated_at'

@test "gcp-tf-handoff writes valid JSON with every required key present and non-empty" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff"
  run make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]

  # Existence before content.
  [ -f "${hdir}/demo-1.handoff.json" ]
  run jq -e . "${hdir}/demo-1.handoff.json"
  [ "$status" -eq 0 ]

  for k in ${HANDOFF_REQUIRED}; do
    run jq -r --arg k "$k" 'if has($k) then (.[$k] | tostring) else "<<ABSENT>>" end' \
      "${hdir}/demo-1.handoff.json"
    [ "$status" -eq 0 ]
    [ "$output" != "<<ABSENT>>" ] || { echo "key ${k} absent"; return 1; }
    [ -n "$output" ] || { echo "key ${k} present but empty"; return 1; }
  done

  # hostname must be a key even when the value is empty, so the test code reads
  # a field rather than discovering an absent one at runtime.
  run jq -e 'has("hostname")' "${hdir}/demo-1.handoff.json"
  [ "$status" -eq 0 ]
}

@test "every hand-off value is derived from terraform output, not from the Makefile" {
  # Change what terraform reports and the hand-off must change with it. A value
  # baked into the Makefile would survive this and still satisfy the test above.
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-derived"
  outputs="${BATS_TEST_TMPDIR}/outputs-derived.json"
  cat > "${outputs}" <<'JSON'
{
  "target_env": { "value": "demo-1" },
  "target_environment": { "value": {
    "region": "europe-west2", "zone": "europe-west2-b",
    "app_port": 9443, "hostname": "elsewhere.changeme.invalid"
  } },
  "integration_inputs": { "value": {
    "project_id": "changeme-other", "access_mode": "allowlist"
  } },
  "instance_name": { "value": "osramp-demo-1-elsewhere" },
  "internal_ip": { "value": "10.99.0.42" }
}
JSON
  run env "STUB_TF_OUTPUT_JSON=${outputs}" \
    make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-other-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]

  h="${hdir}/demo-1.handoff.json"
  [ "$(jq -r .project_id "$h")"      = "changeme-other" ]
  [ "$(jq -r .environment_key "$h")" = "demo-1" ]
  [ "$(jq -r .region "$h")"          = "europe-west2" ]
  [ "$(jq -r .zone "$h")"            = "europe-west2-b" ]
  [ "$(jq -r .instance_name "$h")"   = "osramp-demo-1-elsewhere" ]
  [ "$(jq -r .internal_ip "$h")"     = "10.99.0.42" ]
  [ "$(jq -r .app_port "$h")"        = "9443" ]
  [ "$(jq -r .access_mode "$h")"     = "allowlist" ]
  [ "$(jq -r .hostname "$h")"        = "elsewhere.changeme.invalid" ]
  # app_port is a JSON number, not a string: the test code compares it to a port.
  [ "$(jq -r '.app_port | type' "$h")" = "number" ]
  # And the two values Make owns rather than Terraform.
  [ "$(jq -r .state_bucket "$h")" = "changeme-other-tfstate" ]
  [ "$(jq -r .deploy_sa "$h")"    = "${SA_EMAIL}" ]
}

@test "gcp-tf-handoff accepts an empty hostname and still writes the file" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-nohost"
  outputs="${BATS_TEST_TMPDIR}/outputs-nohost.json"
  cat > "${outputs}" <<'JSON'
{
  "target_env": { "value": "demo-1" },
  "target_environment": { "value": {
    "region": "us-east4", "zone": "us-east4-a", "app_port": 8080, "hostname": ""
  } },
  "integration_inputs": { "value": { "project_id": "changeme-sandbox", "access_mode": "iap" } },
  "instance_name": { "value": "osramp-demo-1-vm" },
  "internal_ip": { "value": "10.20.0.7" }
}
JSON
  run env "STUB_TF_OUTPUT_JSON=${outputs}" \
    make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]
  [ -f "${hdir}/demo-1.handoff.json" ]
  [ "$(jq -r .hostname "${hdir}/demo-1.handoff.json")" = "" ]
  [ "$(jq -r .instance_name "${hdir}/demo-1.handoff.json")" = "osramp-demo-1-vm" ]
}

@test "gcp-tf-handoff writes nothing when a required output is missing" {
  # This is today's real state for instance_name and internal_ip: the compute
  # module publishes them, the environments root does not re-export them. The
  # target must say so rather than emit a file with two blank fields.
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-partial"
  outputs="${BATS_TEST_TMPDIR}/outputs-partial.json"
  cat > "${outputs}" <<'JSON'
{
  "target_env": { "value": "demo-1" },
  "target_environment": { "value": {
    "region": "us-east4", "zone": "us-east4-a", "app_port": 8080, "hostname": ""
  } },
  "integration_inputs": { "value": { "project_id": "changeme-sandbox", "access_mode": "iap" } }
}
JSON
  run env "STUB_TF_OUTPUT_JSON=${outputs}" \
    make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"instance_name"* ]]
  [[ "${output}" == *"internal_ip"* ]]
  [[ "${output}" == *"outputs.tf"* ]]
  [ ! -f "${hdir}/demo-1.handoff.json" ]
}

@test "gcp-tf-handoff refuses when no deploy identity can be recorded" {
  # A hand-off that cannot say which identity built the estate leaves the test
  # code unable to tell a half-applied estate from a complete one.
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-nosa"
  run make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" GCP_TF_IMPERSONATE= \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"deploy_sa"* ]]
  [ ! -f "${hdir}/demo-1.handoff.json" ]
}

@test "gcp-tf-handoff is read-only: it never plans, applies or destroys" {
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-ro"
  run make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]
  run bash -c "grep -E '^ARGV:.* (plan|apply|destroy) ' '${RECORD}/terraform.log' || true"
  [ -z "$output" ]
  run bash -c "grep -c '^ARGV:.* output -json' '${RECORD}/terraform.log'"
  [ "$output" -ge 1 ]
}

@test "the hand-off and the deploy identity are gitignored, and the README is not" {
  run git -C "${REPO_ROOT}" check-ignore -q deploy/gcp/demo-1.handoff.json
  [ "$status" -eq 0 ] || { echo "deploy/gcp/*.handoff.json is not gitignored"; return 1; }
  run git -C "${REPO_ROOT}" check-ignore -q deploy/gcp/deploy-sa
  [ "$status" -eq 0 ] || { echo "deploy/gcp/deploy-sa is not gitignored"; return 1; }
  # Paired positive: a blanket ignore over deploy/gcp/ would satisfy both checks
  # above and hide the documentation too.
  run git -C "${REPO_ROOT}" check-ignore -q deploy/gcp/README.md
  [ "$status" -ne 0 ] || { echo "deploy/gcp/README.md is gitignored"; return 1; }
}

@test "saved plan files are gitignored and none is tracked" {
  run git -C "${REPO_ROOT}" check-ignore -q "${TF_ROOT_BOOTSTRAP_DEFAULT}/bootstrap.tfplan"
  [ "$status" -eq 0 ] || { echo "*.tfplan is not gitignored"; return 1; }
  run bash -c "git -C '${REPO_ROOT}' ls-files -- '*.tfplan'"
  [ -z "$output" ] || { echo "tracked plan files: ${output}"; return 1; }
}

@test "running this suite leaves no artefact in the working tree" {
  # The stub writes whatever `-out=` names, and gcp-tf-bootstrap plans against
  # the real default root. Without the teardown this suite would deposit a plan
  # file in terraform/bootstrap/ on every run.
  run_make gcp-tf-bootstrap
  [ "$status" -eq 0 ]
  [ -f "${REPO_ROOT}/${TF_ROOT_BOOTSTRAP_DEFAULT}/bootstrap.tfplan" ]
  teardown
  [ ! -f "${REPO_ROOT}/${TF_ROOT_BOOTSTRAP_DEFAULT}/bootstrap.tfplan" ]
}

@test "no hand-off or deploy-identity file is tracked" {
  run bash -c "git -C '${REPO_ROOT}' ls-files -- 'deploy/gcp/*.handoff.json' 'deploy/gcp/deploy-sa'"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "tracked: ${output}"; return 1; }
}

@test "no gcp-tf target writes into the repository's deploy/gcp during the suite" {
  # The suite redirects GCP_TF_HANDOFF_DIR into a temp dir precisely so it cannot
  # write a real hand-off. If that ever stopped working, a test run against a
  # live checkout would emit a file naming the real estate.
  run bash -c "ls '${REPO_ROOT}'/deploy/gcp/*.handoff.json 2>/dev/null || true"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# The pre-existing CI lane is untouched by any of this
# ---------------------------------------------------------------------------

@test "no ci-* target's recipe references the gcp-tf block" {
  # The kind-based CI lane and the GCP Terraform block are separate machines.
  # A ci-* recipe reaching into GCP_TF_* would couple them, and the first
  # symptom would be a CI run trying to impersonate a service account.
  run bash -c "awk '/^ci-[a-zA-Z0-9_-]*:/{inr=1;next} /^[^\t]/{inr=0} inr' '${MAKEFILE}' | grep -n 'GCP_TF_\|gcp-tf' || true"
  [ -z "$output" ] || { echo "a ci-* recipe references the gcp-tf block: ${output}"; return 1; }
}

@test "the gcp-tf block defines no target outside its own prefix" {
  # Everything this chunk adds is namespaced. A target defined inside the block
  # without the prefix could shadow one above it, and make resolves the last
  # definition — silently.
  run bash -c "awk '/^# GCP Terraform platform — appended by chunk F6/{inb=1} /^# END GCP Terraform platform block/{inb=0} inb' '${MAKEFILE}' | grep -E '^[a-zA-Z0-9_.-]+:' | grep -v '^gcp-tf-' | grep -v '^\.PHONY' || true"
  [ -z "$output" ] || { echo "unprefixed target inside the block: ${output}"; return 1; }
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS for this chunk
# ---------------------------------------------------------------------------

@test "MUTATION impersonation-guard: neutering the guard lets a mutating target run as the user" {
  mutdir="$(apply_mutation impersonation-guard)"
  local sa; sa="$(sa_file)"
  fixture="$(env_fixture demo-1)"
  touch "${fixture}/.terraform-demo-1/demo-1.tfplan"

  # Unmutated: refused.
  run make -C "${REPO_ROOT}" gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "GCP_TF_DEPLOY_SA_FILE=${sa}" GCP_TF_IMPERSONATE=
  [ "$status" -ne 0 ]
  [[ "${output}" == *"without impersonation"* ]]

  # Mutated: the apply proceeds, unimpersonated. That is the half-applied estate.
  : > "${RECORD}/terraform.log"
  run make -C "${mutdir}" gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "GCP_TF_DEPLOY_SA_FILE=${sa}" GCP_TF_IMPERSONATE=
  [ "$status" -eq 0 ]
  run bash -c "grep -c '^GOOGLE_IMPERSONATE_SERVICE_ACCOUNT:<unset>\$' '${RECORD}/terraform.log'"
  [ "$output" -ge 1 ]
}

@test "MUTATION up-plan-provenance: neutering the sentinel lets a stale plan be applied" {
  mutdir="$(apply_mutation up-plan-provenance)"
  fixture="$(env_fixture demo-1)"
  hdir="${BATS_TEST_TMPDIR}/handoff-mut"

  # Unmutated: a backdated plan file is refused.
  run env "STUB_TF_PLAN_MTIME=2020-01-01 00:00:00" \
    make -C "${REPO_ROOT}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"predates this run"* ]]

  # Mutated: the same stale plan is applied without comment.
  : > "${RECORD}/terraform.log"
  run env "STUB_TF_PLAN_MTIME=2020-01-01 00:00:00" \
    make -C "${mutdir}" gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir}"
  [ "$status" -eq 0 ]
  run bash -c "grep -c '^ARGV:.* apply ' '${RECORD}/terraform.log'"
  [ "$output" -ge 1 ]
}

@test "MUTATION handoff-completeness: neutering the check writes a hand-off with blank fields" {
  mutdir="$(apply_mutation handoff-completeness)"
  fixture="$(env_fixture demo-1)"
  outputs="${BATS_TEST_TMPDIR}/outputs-mut.json"
  cat > "${outputs}" <<'JSON'
{
  "target_env": { "value": "demo-1" },
  "target_environment": { "value": {
    "region": "us-east4", "zone": "us-east4-a", "app_port": 8080, "hostname": ""
  } },
  "integration_inputs": { "value": { "project_id": "changeme-sandbox", "access_mode": "iap" } }
}
JSON

  # Unmutated: nothing written.
  hdir_ok="${BATS_TEST_TMPDIR}/handoff-hc-ok"
  run env "STUB_TF_OUTPUT_JSON=${outputs}" \
    make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir_ok}"
  [ "$status" -ne 0 ]
  [ ! -f "${hdir_ok}/demo-1.handoff.json" ]

  # Mutated: a file appears, and the test code would happily parse it.
  hdir_mut="${BATS_TEST_TMPDIR}/handoff-hc-mut"
  run env "STUB_TF_OUTPUT_JSON=${outputs}" \
    make -C "${mutdir}" gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=changeme-tfstate \
    TF_ROOT_ENV="${fixture}" "$(no_sa_file)" "GCP_TF_IMPERSONATE=${SA_EMAIL}" \
    "GCP_TF_HANDOFF_DIR=${hdir_mut}"
  [ "$status" -eq 0 ]
  [ -f "${hdir_mut}/demo-1.handoff.json" ]
  [ "$(jq -r .instance_name "${hdir_mut}/demo-1.handoff.json")" = "" ]
}
