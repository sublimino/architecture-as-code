#!/usr/bin/env bash
#
# slsi-bundle-build-driver.sh - run named package-tenant-bundle.sh stages
# against an alternate BUNDLE_DIR, offline.
#
# @id     slsi-bundle-build-driver
# @target scripts/package-tenant-bundle.sh
# @tests  test/slsi-bundle-osd.bats
#
# Why this exists rather than invoking the bundler directly: BUNDLE_DIR is
# assigned unconditionally at scripts/package-tenant-bundle.sh:69
# (BUNDLE_DIR="${REPO_ROOT}/bundle", not "${BUNDLE_DIR:-...}"), so an
# environment variable cannot redirect it and a test that tried would silently
# build against the repository's own bundle tree and mutate tracked files.
# Sourcing the script and assigning afterwards is the only redirection that
# works, and it keeps the hermetic suite off the real bundle.
#
# Stages are invoked through run_stage, not called directly, deliberately:
# run_stage no-ops silently on a function-name mismatch
# (`declare -F "${stage_name}" >/dev/null || return 0`), so a new stage that was
# never wired into VALID_STAGES would otherwise read as a pass. Driving through
# the dispatcher means the suite proves dispatch as well as behaviour.
#
# usage: slsi-bundle-build-driver.sh <repo-root> <bundle-dir> <stage>...

cd "$1" || exit 90
_slsi_root="$1"
_slsi_bundle="$2"
shift 2
[ "$#" -gt 0 ] || { echo "slsi-bundle-build-driver: no stage named" >&2; exit 91; }

# shellcheck source=../scripts/package-tenant-bundle.sh
source "${_slsi_root}/scripts/package-tenant-bundle.sh"

# shellcheck disable=SC2034  # read by the stages sourced above, not by this file
BUNDLE_DIR="${_slsi_bundle}"

for _slsi_stage in "$@"; do
	run_stage "${_slsi_stage}"
done
