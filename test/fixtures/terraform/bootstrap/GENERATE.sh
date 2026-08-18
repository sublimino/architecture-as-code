#!/usr/bin/env bash
#
# Regenerate the deliberately-broken fixture copies used by the mutation checks in
# test/terraform-state-protection.bats and test/terraform-conventions.bats.
#
# Each fixture is a copy of a real file from terraform/bootstrap/ with exactly ONE invariant
# broken. The mutation checks assert that the corresponding guard FAILS on the broken copy,
# which is what proves the guard is capable of failing at all.
#
# This script is run BY A HUMAN when the real files change and a fixture has drifted. It is
# never run by the test suite: a suite that regenerates its own fixtures would repair the very
# drift the fidelity check exists to detect, and would then always pass.
#
# Every mutation below asserts that it actually changed the file. A sed expression that stops
# matching after a refactor otherwise no-ops silently, and the fixture ships identical to the
# real file — at which point the mutation check passes for the wrong reason and the guard is
# never exercised.

set -eo pipefail

FIXTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${FIXTURE_ROOT}/../../../.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/terraform/bootstrap"

[ -d "${BOOTSTRAP_DIR}" ] || { echo "FATAL: ${BOOTSTRAP_DIR} does not exist" >&2; exit 1; }

# make_fixture <dir> <source-basename> <sed-expression...>
# Copies the real file, applies the mutations, and refuses to leave behind a fixture that is
# byte-identical to its source.
make_fixture() {
  local dir="$1" src_name="$2"
  shift 2

  local src="${BOOTSTRAP_DIR}/${src_name}"
  local dst="${FIXTURE_ROOT}/${dir}/${src_name}"

  [ -f "${src}" ] || { echo "FATAL: source ${src} does not exist" >&2; exit 1; }

  mkdir -p "${FIXTURE_ROOT}/${dir}"
  cp "${src}" "${dst}"

  local expr
  for expr in "$@"; do
    sed -i -e "${expr}" "${dst}"
  done

  if cmp -s "${src}" "${dst}"; then
    echo "FATAL: fixture ${dir}/${src_name} is identical to its source — a mutation expression" >&2
    echo "       no longer matches. Fix the expression; do not ship an unbroken fixture." >&2
    exit 1
  fi

  echo "ok: ${dir}/${src_name}"
}

make_fixture broken-prevent-destroy main.tf \
  's/prevent_destroy = true/prevent_destroy = false/'

make_fixture broken-public-access main.tf \
  's/public_access_prevention    = "enforced"/public_access_prevention    = "inherited"/'

make_fixture broken-versioning main.tf \
  '/versioning {/,/}/ s/enabled = true/enabled = false/'

make_fixture broken-force-destroy main.tf \
  's/force_destroy               = false/force_destroy               = true/'

make_fixture broken-public-principal main.tf \
  's/  members = var.state_object_admins/  members = ["allUsers"]/'

# The multi-line list form is the one a single-line `members = .*allUsers` regex misses, and
# terraform fmt produces it as soon as the list has more than one entry. Guarding only the
# single-line form would leave the realistic spelling of this mistake undetected.
make_fixture broken-public-principal-multiline main.tf \
  's|^  members = var.state_object_admins|  members = [\n    "allUsers",\n  ]|'

make_fixture broken-absolute-path main.tf \
  '1i # Reproduced from /home/exampleuser/src/osramp/terraform/bootstrap/main.tf'

# Indentation is destroyed wholesale so `terraform fmt -check` rejects the file.
make_fixture broken-unformatted main.tf \
  's/^[[:space:]]\+//'

make_fixture broken-backend-block versions.tf \
  's|^  required_version = ">= 1.9"$|  required_version = ">= 1.9"\n\n  backend "gcs" {}|'

make_fixture broken-untyped-variable variables.tf \
  '/^variable "project_id" {/,/^}/ { /^  type        = string$/d }'

make_fixture broken-undescribed-variable variables.tf \
  '/^variable "location" {/,/^}/ { s/^  description = ".*"$/  description = ""/ }'

# Appended rather than substituted: the point of this fixture is a SECOND binding that grants
# bucket administration alongside the legitimate object-admin one, which is what a real
# privilege-escalation diff would look like.
# shellcheck disable=SC2016  # "$a" is sed's append command, not a shell expansion.
make_fixture broken-storage-admin main.tf \
  '$a\
\
resource "google_storage_bucket_iam_binding" "state_bucket_admins" {\
  bucket  = google_storage_bucket.terraform_state.name\
  role    = "roles/storage.admin"\
  members = var.state_object_admins\
}'

# Native `terraform test` fixtures. These mutate the tftest suite rather than a .tf file, and
# they live here rather than under terraform/ on purpose: a fixture containing `command = apply`
# inside terraform/ would trip the very guard it exists to exercise.
make_tftest_fixture() {
  local dir="$1"
  shift

  local src="${BOOTSTRAP_DIR}/tests/state-bucket.tftest.hcl"
  local dst="${FIXTURE_ROOT}/${dir}/state-bucket.tftest.hcl"

  [ -f "${src}" ] || { echo "FATAL: source ${src} does not exist" >&2; exit 1; }

  mkdir -p "${FIXTURE_ROOT}/${dir}"
  cp "${src}" "${dst}"

  local expr
  for expr in "$@"; do
    sed -i -e "${expr}" "${dst}"
  done

  if cmp -s "${src}" "${dst}"; then
    echo "FATAL: fixture ${dir} is identical to its source — a mutation expression no longer" >&2
    echo "       matches. Fix the expression; do not ship an unbroken fixture." >&2
    exit 1
  fi

  echo "ok: ${dir}/state-bucket.tftest.hcl"
}

make_tftest_fixture broken-tftest-no-mock-provider \
  '/^mock_provider /d'

make_tftest_fixture broken-tftest-command-apply \
  '0,/^  command = plan$/ s//  command = apply/'

echo "all fixtures regenerated"
