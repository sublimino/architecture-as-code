#!/usr/bin/env bash
#
# Proves that test/terraform-tailscale-cert-state.bats can actually FAIL.
#
# ─── Why this file exists ───────────────────────────────────────────────────
#
# That suite is mostly greps and absence-of-bad assertions. Both shapes pass
# trivially when the thing they read has moved, been renamed, or is empty — so a
# green run is not on its own evidence of anything. This harness mutates the
# REAL files, one property at a time, and requires the specific test guarding
# that property to go red. A mutation that leaves the suite green names a guard
# that was never testing what its name claims.
#
# ─── Safety ─────────────────────────────────────────────────────────────────
#
# Files are backed up by COPY and restored from that copy. Deliberately NOT
# `git checkout` / `git stash`: this repo is worked in worktrees with
# uncommitted changes in flight, and a proof harness that reverts tracked files
# destroys the very work it was invoked to check — which reads exactly like a
# real finding and has cost this repo a session before.
#
# The restore runs from a trap on EXIT, INT, TERM and HUP. It cannot cover
# SIGKILL; if this script is `kill -9`d the repo is left mutated, and
# `git diff` is the recovery.
#
# No `set -e`. An errexit shell combined with an EXIT trap lets a failing last
# command in the trap replace the script's real verdict, which has previously
# turned an 8/8 pass into a reported failure here.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SUITE="${REPO_ROOT}/test/terraform-tailscale-cert-state.bats"

readonly CERT_STATE="${REPO_ROOT}/scripts/gcp-tf/tailscale-cert-state.sh"
readonly DOCTOR="${REPO_ROOT}/scripts/node-doctor.sh"
readonly DOCTOR_LIB="${REPO_ROOT}/scripts/node-doctor/lib.sh"
readonly DEMO_UP="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"

readonly FILES=("${CERT_STATE}" "${DOCTOR}" "${DOCTOR_LIB}" "${DEMO_UP}")

PASS=0
FAIL=0

# ── The shared safety rail ──────────────────────────────────────────────────
#
# An EXIT trap was the whole protection here, and it does not survive SIGKILL —
# which is what a tool timeout escalates to. $DEMO_UP is shared with three other
# proofs, and a hard kill leaving it mutated has already happened in this tree.
# The helper leaves a marker that outlives the kill, REFUSES to start on top of
# one rather than repairing it, and verifies the restore on content AND mode.
#
# The hand-rolled backup_key that used to live here is gone, and so is the
# collision check that guarded it. Both were answering the question "can two
# managed files land on the same backup path?" — a real defect, found in the
# sibling proof where three files are called main.tf, keyed on `basename`,
# collided, and made nine mutations report "changed nothing" because they were
# applied to the wrong content. The rail mirrors each file under its FULL
# repo-relative path inside the backup directory, so the mapping is injective by
# construction and there is nothing left for a collision check to catch.
#
# ms_guard_on_exit also keeps the property the old `cleanup` was written for:
# NOTHING that can fail runs after the restore, because the status is captured
# first and re-raised. See test/helpers/mutation-sentinel.bash.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init gcp-demo-tailscale-cert-state "${FILES[@]}"
trap ms_guard_on_exit EXIT INT TERM HUP

restore_all() { ms_guard_restore; }

# Runs ONE test by name and reports whether it failed.
#
# `bats -f` takes a regex over test names. The name is matched loosely so a
# later rewording of the test does not silently stop matching and report a
# vacuous pass — MUTATION_TEST_MISSING below catches the case where it matches
# nothing at all.
suite_test_fails() {
  local pattern="$1" out rc
  out="$(cd "${REPO_ROOT}" && bats -f "${pattern}" "${SUITE}" 2>&1)"
  rc=$?

  # A pattern that matched NO test exits 0 with no test lines, which would read
  # as "the guard did not fire" when the truth is "there is no such guard".
  if ! grep -qE '^(ok|not ok) ' <<<"$out"; then
    echo "    HARNESS FAULT: no test matched /${pattern}/" >&2
    return 2
  fi

  [[ $rc -ne 0 ]]
}

# mutate <label> <test-name-regex> <file> <sed-expression>
#
# Applies the mutation, asserts the named guard goes red, restores.
mutate() {
  local label="$1" pattern="$2" file="$3" expr="$4"
  local before after

  # Armed by hand, and BEFORE the write. This deliberately does NOT use ms_sed:
  # ms_sed ABORTS on a no-op, and this harness records a no-op as [BROKEN] and
  # carries on, so one dead pattern cannot hide the verdict on every mutation
  # after it. The sentinel is what ms_sed would have provided; the no-op policy
  # below is this harness's own and is left exactly as it was.
  ms_guard_arm "${label} — ${file}"
  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i -e "$expr" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"

  # A sed that matched nothing is a NO-OP that prints success — the exact way a
  # mutation harness certifies a guard it never actually challenged.
  if [[ "$before" == "$after" ]]; then
    echo "  [BROKEN] ${label}"
    echo "    the mutation changed nothing; the pattern no longer matches the file"
    FAIL=$((FAIL + 1))
    restore_all
    return 0
  fi

  if suite_test_fails "$pattern"; then
    echo "  [RED   ] ${label}"
    PASS=$((PASS + 1))
  else
    echo "  [GREEN ] ${label}"
    echo "    the suite stayed green under this mutation — the guard is not testing"
    echo "    the property its name claims"
    FAIL=$((FAIL + 1))
  fi

  restore_all
}

echo "=== baseline: the suite must be GREEN before any mutation ==="
if (cd "${REPO_ROOT}" && bats "${SUITE}" >/dev/null 2>&1); then
  echo "  [OK    ] baseline green"
else
  echo "  [FATAL ] the suite is already failing; mutation results would be meaningless" >&2
  exit 1
fi

echo
echo "=== mutations ==="

# 1. The journal match stops being anchored on THIS node's name, so another
#     lane's rate-limit window is adopted as this one's. That error was worth
#     20 hours.
mutate "journal match no longer anchored on this lane's name" \
  "another lane's 429 is NOT adopted" \
  "${CERT_STATE}" \
  's|grep -F "cert(\\"${fqdn}\\")" 2>/dev/null|cat|g'

# 2. The retry-after is never extracted, so a 429 stops being recorded as a
#     rate limit and nobody learns when the window rolls.
mutate "retry-after extraction removed" \
  "recorded as rate_limited" \
  "${CERT_STATE}" \
  's|sed -n .s/.*retry after \\(\[0-9-\]\* \[0-9:\]\*\\) UTC.*/\\1/p.|cat|'

# 3. The HTTP fallback is never applied — the estate simply serves nothing
#     during a rate-limit window.
mutate "HTTP fallback serve removed" \
  "HTTP fallback is applied" \
  "${CERT_STATE}" \
  's|"\$TS_CMD" serve --bg --http=80|true --bg --http-DISABLED=80|'

# 4. The downgrade goes SILENT. This is the vacuous-pass shape: the estate
#     serves HTTP, everything reports fine, and nobody knows TLS is gone.
mutate "the loud fallback banner removed" \
  "fallback is LOUD" \
  "${CERT_STATE}" \
  's|SERVING OVER PLAIN HTTP|serving normally|g'

# 5. The fallback path exits non-zero, so a rate-limit window aborts the
#     deploy and blocks acceptance testing of everything else.
mutate "fallback path made blocking (exit 1)" \
  "NON-BLOCKING" \
  "${CERT_STATE}" \
  's|^    apply_serve http "\$APP_PORT" .. warn "could not configure the HTTP fallback"$|    apply_serve http "$APP_PORT"; return 1|'

# 6. Expiry checking removed, so a restored EXPIRED certificate counts as
#     valid — tailscaled serves something browsers refuse AND the fallback
#     never fires. Strictly worse than having no certificate.
mutate "certificate expiry check removed" \
  "EXPIRED restored certificate" \
  "${CERT_STATE}" \
  's|"\$OPENSSL_CMD" x509 -in "\$crt" -noout -checkend 0|true|'

# 7. The doctor reports the HTTP fallback as a PASS — a certificate outage
#     becomes a green run.
mutate "HTTP fallback downgraded to a pass in the doctor" \
  "routes to nd_degraded" \
  "${DOCTOR}" \
  's|^          nd_degraded "serving over HTTP because the certificate is unavailable|          nd_pass "serving over HTTP because the certificate is unavailable|'

# 7b. The arm is routed through nd_warn instead. This is the SUBTLE one and it
#     is what the first draft actually did: the call site names a plausible
#     reporter, the source-grep guard is satisfied, and the lane still
#     summarises as HEALTHY because ND_WARN does not move the verdict.
mutate "HTTP fallback routed through nd_warn, which the verdict ignores" \
  "routes to nd_degraded" \
  "${DOCTOR}" \
  's|^          nd_degraded "serving over HTTP because the certificate is unavailable|          nd_warn "serving over HTTP because the certificate is unavailable|'

# 7c. The verdict arm itself is deleted, so a degraded check summarises green.
mutate "DEGRADED dropped from the summary verdict" \
  "SUMMARY VERDICT non-green" \
  "${DOCTOR_LIB}" \
  's|^  elif \[ "\$ND_DEGRADED" -gt 0 \]; then verdict=DEGRADED; rc=0$|  elif [ "$ND_DEGRADED" -gt 0 ]; then verdict=PASS; rc=0|'

# 7d. DEGRADED starts failing the sweep, which blocks acceptance testing on a
#     condition that cannot be fixed for up to 168h.
mutate "DEGRADED made to fail the sweep" \
  "without failing" \
  "${DOCTOR_LIB}" \
  's|then verdict=DEGRADED; rc=0$|then verdict=DEGRADED; rc=1|'

# 7e. DEGRADED is tested before FAIL, so a real fault sharing a run with a
#     certificate outage is silently downgraded.
mutate "DEGRADED allowed to mask a real failure" \
  "does not mask a real failure" \
  "${DOCTOR_LIB}" \
  's|^  if   \[ "\$ND_FAIL" -gt 0 \];     then verdict=FAIL;     rc=1$|  if   [ "$ND_DEGRADED" -gt 0 ]; then verdict=DEGRADED; rc=0|'

# 8. HTTP_FALLBACK collapses into HTTPS_OK in the classifier itself.
mutate "HTTP fallback collapsed into HTTPS_OK" \
  "classifies all five tailnet states" \
  "${DOCTOR}" \
  "s|printf 'HTTP_FALLBACK'; return|printf 'HTTPS_OK'; return|"

# 9. TLS-never-completes collapses into the generic nothing-serving arm, so a
#     certificate outage is misdiagnosed as a networking failure.
mutate "TLS-never-completes collapsed into NOTHING_SERVING" \
  "classifies all five tailnet states" \
  "${DOCTOR}" \
  "s@TLS_NEVER_COMPLETES' ;;@NOTHING_SERVING' ;;@"

# 10. The deploy stops determining the certificate state at all.
mutate "cert-state probe removed from the deploy path" \
  "demo-up runs the certificate-state probe" \
  "${DEMO_UP}" \
  's|assert_tailnet_cert_state|assert_tailnet_cert_state_REMOVED|g'

# 11. The `|| warn` guard is dropped, so a certificate outage can abort a
#     deploy that was otherwise passing.
mutate "cert-state probe made able to fail the deploy" \
  "never fail a deploy" \
  "${DEMO_UP}" \
  's|^  assert_tailnet_cert_state ..$|  assert_tailnet_cert_state \&\&|'


echo
echo "=== result ==="
echo "  mutations that turned the suite red : ${PASS}"
echo "  mutations the suite did not catch   : ${FAIL}"

if [[ "${FAIL}" -ne 0 ]]; then
  echo
  echo "FAIL: ${FAIL} mutation(s) left the suite green. Those guards do not test" >&2
  echo "the property their names claim." >&2
  exit 1
fi

echo
echo "PASS: every mutation was caught."
