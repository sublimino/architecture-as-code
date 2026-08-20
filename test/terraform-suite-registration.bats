#!/usr/bin/env bats
#
# Test registration is DEFAULT-ON, and this suite is what keeps it that way.
#
# This repo has already shipped 33 bats suites that no runner executed: all
# passing, all measuring nothing, because the runner named files by hand and
# nobody re-edited the list when a suite landed. The same shape had already bitten
# Playwright here (a spec matching no project's testMatch is silently skipped,
# exit 0, no warning). Ten-plus terraform suites are landing across six parallel
# branches right now, so a hand-maintained list would reproduce the fault at
# scale on day one.
#
# The fix is discovery: `make gcp-tf-validate` globs `test/terraform-*.bats` and
# `make gcp-tf-test-unit` discovers every directory holding `tests/*.tftest.hcl`.
# The fix is only worth anything if it cannot be quietly reverted, which is what
# these tests are for. They EXECUTE the targets with a recording stub and diff
# what actually ran against what exists on disk.
#
# Offline: no network, no cloud credentials, no real terraform or bats run.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export MAKEFILE="${REPO_ROOT}/Makefile"
  export FIXTURES="${REPO_ROOT}/test/fixtures/terraform/make"
  export WORKFLOW="${REPO_ROOT}/.github/workflows/terraform-validate.yaml"
}

setup() {
  # Presence first, always.
  [ -f "${MAKEFILE}" ]
  [ -d "${FIXTURES}" ]
  [ -f "${WORKFLOW}" ]
  grep -q '^# END GCP Terraform platform block' "${MAKEFILE}"

  STUBDIR="${BATS_TEST_TMPDIR}/stubs"
  RECORD="${BATS_TEST_TMPDIR}/record"
  mkdir -p "${STUBDIR}" "${RECORD}"

  # Recording stubs. `bats` and `terraform test` are the two things whose
  # ARGUMENTS are the evidence here — what a runner was asked to run is the
  # only honest answer to "is this suite registered?".
  cat > "${STUBDIR}/bats" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done >> "${STUB_RECORD}/bats.log"
exit 0
STUB

  cat > "${STUBDIR}/terraform" <<'STUB'
#!/usr/bin/env bash
chdir=""
for a in "$@"; do
  case "$a" in -chdir=*) chdir="${a#-chdir=}" ;; esac
done
case " $* " in
  *" test "*) printf 'TEST:%s\n' "${chdir}" >> "${STUB_RECORD}/terraform.log" ;;
  *" validate "*) printf 'VALIDATE:%s\n' "${chdir}" >> "${STUB_RECORD}/terraform.log" ;;
esac
exit 0
STUB

  cat > "${STUBDIR}/tflint" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in --chdir=*) printf 'TFLINT:%s\n' "${a#--chdir=}" >> "${STUB_RECORD}/terraform.log" ;; esac
done
exit 0
STUB

  chmod +x "${STUBDIR}/bats" "${STUBDIR}/terraform" "${STUBDIR}/tflint"
  export STUB_RECORD="${RECORD}"
  export GCP_TF_PROOFS_RUN=/usr/bin/true
  export PATH="${STUBDIR}:${PATH}"
}

@test "terraform workflow registers GCP Terraform trigger paths" {
  grep -Fqx '      - "scripts/gcp-tf/**"' "${WORKFLOW}"
  grep -Fqx '      - "test/fixtures/gcp-tf/**"' "${WORKFLOW}"
}

# Copy the real Makefile, apply one named mutation fixture, and REFUSE to
# continue unless the mutation actually changed something. A sed program whose
# pattern no longer matches silently no-ops; the mutation check would then run
# against an unmutated Makefile and pass, which is the precise failure mode this
# whole file exists to prevent.
apply_mutation() {
  local name="$1"
  local sedfile="${FIXTURES}/${name}.sed"
  local dir="${BATS_TEST_TMPDIR}/mut-${name}"
  [ -f "${sedfile}" ] || {
    echo "mutation fixture ${sedfile} is missing"
    return 1
  }
  mkdir -p "${dir}"
  sed -f "${sedfile}" "${MAKEFILE}" > "${dir}/Makefile"
  if diff -q "${MAKEFILE}" "${dir}/Makefile" >/dev/null; then
    echo "mutation '${name}' applied cleanly but changed nothing."
    echo "Its pattern no longer matches the Makefile, so it is testing nothing."
    return 1
  fi
  printf '%s' "${dir}/Makefile"
}

# The suites that exist on disk, one per line.
disk_bats() {
  ( cd "${REPO_ROOT}" && ls test/terraform-*.bats 2>/dev/null | sort )
}

# The directories holding a native terraform test suite, one per line.
disk_test_dirs() {
  ( cd "${REPO_ROOT}" && find terraform -type f -name '*.tftest.hcl' \
      -not -path '*/.terraform*' -printf '%h\n' 2>/dev/null \
      | sed 's#/tests$##' | sort -u )
}

# ---------------------------------------------------------------------------
# The mechanism is present
# ---------------------------------------------------------------------------

@test "at least one terraform bats suite and one tftest suite exist on disk" {
  # Without this, every "everything on disk is registered" assertion below is
  # vacuously true against an empty disk.
  [ -n "$(disk_bats)" ]
  [ -n "$(disk_test_dirs)" ]
}

@test "the Makefile discovers terraform bats suites by glob, not by a hand-written list" {
  run grep -E '^GCP_TF_BATS = ' "${MAKEFILE}"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"wildcard test/terraform-"* ]]
  # A hand-written list is the anti-pattern: two or more literal .bats paths on
  # the assignment line.
  literal_count="$(printf '%s\n' "${output}" | grep -oE 'test/terraform-[a-z0-9-]+\.bats' | wc -l)"
  [ "${literal_count}" -eq 0 ]
}

@test "the Makefile discovers terraform test directories by find, not by a hand-written list" {
  run grep -E '^GCP_TF_TEST_DIRS = ' "${MAKEFILE}"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"find terraform"* ]]
  [[ "${output}" == *".tftest.hcl"* ]]
}

# ---------------------------------------------------------------------------
# Everything on disk is actually executed
# ---------------------------------------------------------------------------

@test "make gcp-tf-validate executes every test/terraform-*.bats on disk" {
  run make -C "${REPO_ROOT}" gcp-tf-validate
  [ "$status" -eq 0 ]
  [ -f "${RECORD}/bats.log" ]

  # Diff what was RUN against what EXISTS. Not a count, not a spot check — the
  # two sets must be identical, so a suite that lands tomorrow is caught the
  # day it lands rather than the day someone remembers to look.
  disk_bats | sort > "${BATS_TEST_TMPDIR}/expected"
  sort "${RECORD}/bats.log" | grep -E '^test/terraform-.*\.bats$' | sort -u > "${BATS_TEST_TMPDIR}/actual"
  run diff -u "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
  [ "$status" -eq 0 ]
}

@test "make gcp-tf-test-unit reaches every directory holding a .tftest.hcl" {
  run make -C "${REPO_ROOT}" gcp-tf-test-unit
  [ "$status" -eq 0 ]
  [ -f "${RECORD}/terraform.log" ]

  disk_test_dirs > "${BATS_TEST_TMPDIR}/expected"
  grep '^TEST:' "${RECORD}/terraform.log" | sed 's/^TEST://' | sort -u > "${BATS_TEST_TMPDIR}/actual"
  run diff -u "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
  [ "$status" -eq 0 ]
}

@test "make gcp-tf-validate validates and lints every directory holding .tf files" {
  run make -C "${REPO_ROOT}" gcp-tf-validate
  [ "$status" -eq 0 ]
  ( cd "${REPO_ROOT}" && find terraform -type f -name '*.tf' -not -path '*/.terraform*' \
      -printf '%h\n' 2>/dev/null | sort -u ) > "${BATS_TEST_TMPDIR}/expected"
  [ -s "${BATS_TEST_TMPDIR}/expected" ]

  grep '^VALIDATE:' "${RECORD}/terraform.log" | sed 's/^VALIDATE://' | sort -u > "${BATS_TEST_TMPDIR}/actual-validate"
  run diff -u "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual-validate"
  [ "$status" -eq 0 ]

  grep '^TFLINT:' "${RECORD}/terraform.log" | sed 's/^TFLINT://' | sort -u > "${BATS_TEST_TMPDIR}/actual-tflint"
  run diff -u "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual-tflint"
  [ "$status" -eq 0 ]
}

@test "gcp-tf-validate invokes gcp-tf-test-unit" {
  # ISC-354. Asserted by execution: the tftest sweep must have run as part of
  # validate, not merely be mentioned in the recipe text.
  run make -C "${REPO_ROOT}" gcp-tf-validate
  [ "$status" -eq 0 ]
  run grep -c '^TEST:' "${RECORD}/terraform.log"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "gcp-tf-validate executes the Dex origin mutation proof" {
  run env -u GCP_TF_PROOFS_RUN make -C "${REPO_ROOT}" -n gcp-tf-validate
  [ "$status" -eq 0 ]
  [[ "${output}" == *"bash test/dex-origin-mutation-proof.sh"* ]]
}

# ---------------------------------------------------------------------------
# Every root and module that holds resources also holds a tests/ directory
# ---------------------------------------------------------------------------

@test "every terraform directory declaring resources ships a tests directory" {
  # ISC-355. Reported as a list rather than a bare failure, because at merge
  # time the useful output is "which module is missing its suite".
  missing=()
  while read -r d; do
    [ -n "$d" ] || continue
    # A directory that declares no resource or module block is variables-only
    # scaffolding and needs no plan to assert on.
    if ! grep -rqE '^(resource|module)[[:space:]]+"' "${REPO_ROOT}/${d}"/*.tf 2>/dev/null; then
      continue
    fi
    if ! ls "${REPO_ROOT}/${d}"/tests/*.tftest.hcl >/dev/null 2>&1; then
      missing+=("$d")
    fi
  done < <( cd "${REPO_ROOT}" && find terraform -type f -name '*.tf' -not -path '*/.terraform*' \
              -printf '%h\n' 2>/dev/null | sort -u )

  if [ "${#missing[@]}" -ne 0 ]; then
    echo "terraform directories declaring resources but shipping no tests/*.tftest.hcl:"
    printf '  %s\n' "${missing[@]}"
    return 1
  fi
}

@test "every .tftest.hcl declares mock_provider and none uses command = apply" {
  # ISC-332/333/334/335. Whole-tree absence — the one class terraform test
  # genuinely cannot assert about itself.
  files="$( cd "${REPO_ROOT}" && find terraform -type f -name '*.tftest.hcl' -not -path '*/.terraform*' | sort )"
  [ -n "${files}" ]
  for f in ${files}; do
    grep -q 'mock_provider "google"' "${REPO_ROOT}/${f}" || {
      echo "${f} does not declare mock_provider \"google\" — it could reach a real provider"
      return 1
    }
    if grep -qE '^[[:space:]]*command[[:space:]]*=[[:space:]]*apply' "${REPO_ROOT}/${f}"; then
      echo "${f} uses command = apply; apply against a mocked provider still writes state"
      return 1
    fi
  done
}

@test "every .tftest.hcl using expect_failures also contains a passing run" {
  # ISC-347. A run block that fails for an unrelated reason is indistinguishable
  # from a validation rule firing correctly, so a negative with no paired
  # positive is a test that proves nothing.
  files="$( cd "${REPO_ROOT}" && find terraform -type f -name '*.tftest.hcl' -not -path '*/.terraform*' | sort )"
  [ -n "${files}" ]
  for f in ${files}; do
    if grep -q 'expect_failures' "${REPO_ROOT}/${f}"; then
      grep -q '^[[:space:]]*assert[[:space:]]*{' "${REPO_ROOT}/${f}" || {
        echo "${f} has expect_failures but no asserting run — its negatives are unpaired"
        return 1
      }
    fi
  done
}

# ---------------------------------------------------------------------------
# Exclusion lists carry reasons
# ---------------------------------------------------------------------------

@test "every excluded bats suite and test directory names a file that exists" {
  # An exclusion naming a file that does not exist rots into a list that
  # silently pre-approves anything.
  excluded="$(make -C "${REPO_ROOT}" -s -p 2>/dev/null \
    | grep -E '^GCP_TF_EXCLUDED_(BATS|TEST_DIRS) :?=' | sed 's/^[^=]*= *//' || true)"
  for e in ${excluded}; do
    [ -e "${REPO_ROOT}/${e}" ] || {
      echo "exclusion '${e}' names something that does not exist"
      return 1
    }
  done
}

@test "every mutation fixture is referenced by a suite" {
  # A fixture nothing consumes is dead weight that looks like coverage.
  for f in "${FIXTURES}"/*.sed; do
    name="$(basename "${f}" .sed)"
    grep -rq "${name}" "${REPO_ROOT}/test"/terraform-*.bats || {
      echo "mutation fixture ${name}.sed is referenced by no suite"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS — the glob cannot be quietly reverted to a hand list
# ---------------------------------------------------------------------------

@test "MUTATION bats-hand-list: reverting the glob to a hand list stops running a suite" {
  mutated="$(apply_mutation bats-hand-list)"
  [ -n "${mutated}" ]

  # Run the mutated recipe against the real tree, so discovery sees the real
  # files and only the registration mechanism differs.
  run make -C "${REPO_ROOT}" -f "${mutated}" gcp-tf-validate
  [ "$status" -eq 0 ]

  disk_bats | sort > "${BATS_TEST_TMPDIR}/expected"
  sort "${RECORD}/bats.log" | grep -E '^test/terraform-.*\.bats$' | sort -u > "${BATS_TEST_TMPDIR}/actual"

  # The mutated Makefile must run FEWER suites than exist. If this passes, the
  # hand list happens to be complete today and the guard above is not yet
  # measuring anything — which is itself the finding.
  run diff -q "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
  [ "$status" -ne 0 ]
}

@test "MUTATION tftest-hand-list: hand-listing test directories stops sweeping a module" {
  mutated="$(apply_mutation tftest-hand-list)"
  [ -n "${mutated}" ]

  run make -C "${REPO_ROOT}" -f "${mutated}" gcp-tf-test-unit
  [ "$status" -eq 0 ]

  disk_test_dirs > "${BATS_TEST_TMPDIR}/expected"
  grep '^TEST:' "${RECORD}/terraform.log" | sed 's/^TEST://' | sort -u > "${BATS_TEST_TMPDIR}/actual"
  run diff -q "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
  [ "$status" -ne 0 ]
}
