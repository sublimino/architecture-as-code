#!/usr/bin/env bash
# erasure-legal-hold-mutation-proof.sh — prove the SLDP-P3-2 erasure gate guards can actually fail.
#
# ─── What this proves ────────────────────────────────────────────────────────
#
# SLDP-P3-2 added an Article 17(3) legal-hold gate in front of key destruction.
# Every one of its controls is a refusal, and a refusal is the easiest thing in
# software to implement vacuously: a test asserting "this was refused" passes
# just as well against code that refuses everything, or against a guard whose
# predicate can never match.
#
# This repository has been bitten by that shape repeatedly — a green suite is
# not evidence that the suite asserts anything. So each case below REMOVES one
# real control from the real source file, requires the named test to go red,
# then restores the file and requires the suite to go green again.
#
# A control whose deletion fails nothing is not a control. A guard never
# observed failing is an untested claim.
#
# ─── Traps this harness defends against ──────────────────────────────────────
#
#  * `go test -run <pattern>` matching ZERO tests exits 0. A typo in a pattern
#    would therefore read as "the mutation survived" and falsely acquit a
#    working guard. Every case asserts its pattern selects at least one test
#    BEFORE mutating.
#  * A killed harness leaves the repository mutated. An EXIT/INT/TERM trap
#    restores every touched file, and the run ends by verifying each file's
#    checksum matches what it was at start.
#  * A sed that matches nothing is a silent no-op that looks like a successful
#    mutation. Every mutation asserts the file actually changed.
#  * The suite must be GREEN before mutating, or a pre-existing failure wears
#    the mutation's clothes and every case "passes" for the wrong reason.
#
# Usage: test/erasure-legal-hold-mutation-proof.sh
# Exit:  0 if every control was proven failable; 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ING="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
BACKUP_DIR="$(mktemp -d)"

# Files this harness is permitted to mutate, keyed by a short label. Backups are
# keyed by LABEL, not by basename: three different packages here contain a file
# called erasure.go, and a basename-keyed backup would restore one over another.
declare -A TARGETS=(
  [erasure]="${ING}/privacy/erasure.go"
  [hold]="${ING}/privacy/hold.go"
  [exception]="${ING}/privacy/exception.go"
  [operator]="${ING}/privacy/operator.go"
  [retention]="${ING}/privacy/retention.go"
  [migrations]="${ING}/identity/migrations.go"
)

declare -A ORIGINAL_SUM=()

restore_all() {
  local label
  for label in "${!TARGETS[@]}"; do
    if [[ -f "${BACKUP_DIR}/${label}" ]]; then
      cp -p "${BACKUP_DIR}/${label}" "${TARGETS[$label]}"
    fi
  done
}
trap 'restore_all; rm -rf "${BACKUP_DIR}"' EXIT INT TERM

gotest() {
  ( cd "${ING}" && env GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" \
      CGO_ENABLED=0 go test "$@" ) 2>&1
}

PASS=0
FAIL=0
CASE_NUM=0

# ---------------------------------------------------------------------------
# preflight: back up every target and record its checksum; require a green
# starting suite.
# ---------------------------------------------------------------------------
for label in "${!TARGETS[@]}"; do
  path="${TARGETS[$label]}"
  [[ -f "$path" ]] || { echo "FATAL: target ${label} missing at ${path}" >&2; exit 1; }
  cp -p "$path" "${BACKUP_DIR}/${label}"
  ORIGINAL_SUM[$label]="$(sha256sum "$path" | cut -d' ' -f1)"
done

echo "── preflight ──────────────────────────────────────────────────────────"
if ! gotest ./privacy/ ./api/ ./identity/ -count=1 >/dev/null 2>&1; then
  echo "FATAL: the suite is ALREADY RED before any mutation." >&2
  echo "       Every case below would report a failure that is not the mutation's." >&2
  exit 1
fi
echo "baseline suite is green; mutations are attributable"
echo

# ---------------------------------------------------------------------------
# run_case LABEL PKG TEST_PATTERN DESCRIPTION SED_EXPR
#
# Asserts the pattern selects >0 tests, applies the mutation, asserts the file
# changed, requires the test to FAIL, then restores and requires it to pass.
# ---------------------------------------------------------------------------
run_case() {
  local label="$1" pkg="$2" pattern="$3" desc="$4" expr="$5"
  local path="${TARGETS[$label]}"
  CASE_NUM=$((CASE_NUM + 1))

  printf '── case %02d ── %s\n' "$CASE_NUM" "$desc"

  # Guard against the zero-match false-acquittal: a pattern selecting no tests
  # exits 0 and would read as "mutation survived".
  local selected
  selected="$(gotest "${pkg}" -run "${pattern}" -count=1 -v 2>/dev/null | grep -c '^=== RUN' || true)"
  if [[ "${selected}" -eq 0 ]]; then
    echo "   ✗ pattern ${pattern} selects ZERO tests — cannot acquit or convict"
    FAIL=$((FAIL + 1))
    return
  fi

  local before after
  before="$(sha256sum "$path" | cut -d' ' -f1)"
  perl -0pi -e "${expr}" "$path"
  after="$(sha256sum "$path" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "   ✗ mutation did not change ${path##*/} — the pattern matched nothing (silent no-op)"
    cp -p "${BACKUP_DIR}/${label}" "$path"
    FAIL=$((FAIL + 1))
    return
  fi

  # A non-zero exit is NOT sufficient evidence of a kill, and trusting it is the inverse of
  # "a check that never ran looks like a check that passed".
  #
  # In Go, deleting a control line routinely leaves an import or a local variable unused, and both
  # are COMPILE ERRORS. `go test` then exits non-zero from a build failure, for a test that never
  # ran and an assertion that was never evaluated. A harness reading "non-zero ⇒ killed" records a
  # kill it did not earn, and the headline "N/N, zero survivors" is partially fiction.
  #
  # So the kill condition is the explicit line `--- FAIL: <TestName>` in the output, which only
  # appears when a test actually executed and actually failed. A build break is detected separately
  # and reported as an INCONCLUSIVE case, never as a kill.
  local out
  out="$(gotest "${pkg}" -run "${pattern}" -count=1 -v || true)"

  if grep -qE '^(# |.*\[build failed\]|.*cannot use|.*undefined:|.*declared and not used|.*imported and not used)' <<<"$out"; then
    echo "   ⚠ INCONCLUSIVE — the mutation broke the build, so the test never ran"
    echo "     $(grep -m1 -E 'declared and not used|imported and not used|undefined:|build failed' <<<"$out" | sed 's/^[[:space:]]*//')"
    FAIL=$((FAIL + 1))
    cp -p "${BACKUP_DIR}/${label}" "$path"
    return
  fi

  if grep -q -- '--- FAIL: ' <<<"$out"; then
    local killer
    killer="$(grep -m1 -- '--- FAIL: ' <<<"$out" | sed 's/^[[:space:]]*--- FAIL: //; s/ .*//')"
    echo "   ✓ mutation killed — ${killer} ran and FAILED (${selected} test(s) selected)"
    PASS=$((PASS + 1))
  else
    echo "   ✗ MUTATION SURVIVED — ${selected} test(s) ran and stayed green with the control removed"
    FAIL=$((FAIL + 1))
  fi

  cp -p "${BACKUP_DIR}/${label}" "$path"
  if ! gotest "${pkg}" -run "${pattern}" -count=1 >/dev/null 2>&1; then
    echo "   ✗ the suite did NOT return to green after restore — the harness has corrupted the tree"
    FAIL=$((FAIL + 1))
  fi
}

echo "── mutations ──────────────────────────────────────────────────────────"

# 1. Fail-open on unavailable incident state: ignore the lookup error entirely.
run_case erasure ./privacy/ 'TestErasureHold_UnavailableIncidentStateRefuses' \
  'incident-state error no longer refuses (fail open)' \
  's/\treturn s\.refuse\(ctx, d, req, OutcomeRefusedIncidentStateUnavailable,\n\t\t\tfmt\.Errorf\("%w: %v", ErrIncidentStateUnavailable, err\)\)/\terr = nil/'

# 2. Jurisdiction declination treated as "no holds".
run_case erasure ./privacy/ 'TestErasureHold_NoJurisdictionRefuses' \
  'a declined (no-jurisdiction) answer is read as "found nothing"' \
  's/\tif !res\.Jurisdiction \{/\tif false \{/'

# 3. Composite source returns a partial view instead of refusing.
run_case hold ./privacy/ 'TestHoldCompositeSourceRefusesPartialViews' \
  'composite ignores a failing constituent and returns a partial union' \
  's/\t\t\treturn HoldQueryResult\{\}, fmt\.Errorf\("%w: source %d: %v", ErrIncidentStateUnavailable, i, err\)/\t\t\tres = HoldQueryResult\{Jurisdiction: true\}; _ = i/'

# 4. Composite with zero authoritative sources answers "no holds".
run_case hold ./privacy/ 'TestHoldCompositeSourceRefusesPartialViews' \
  'composite whose every member declined answers "no holds"' \
  's/\tif authoritative == 0 \{/\tif false \{/'

# 5. Quarantine source answers "no holds" for a tenant it does not serve.
run_case hold ./privacy/ 'TestHoldQuarantineSourceDerivesContainmentHolds' \
  'quarantine source claims jurisdiction over every tenant' \
  's/\t\treturn HoldQueryResult\{Jurisdiction: false\}, nil/\t\treturn HoldQueryResult\{Jurisdiction: true\}, nil/'

# 6. Dual-operator distinctness removed — one person signing twice suffices.
#
# COMPOUND, and it has to be. Two separate lines enforce distinctness: the explicit duplicate
# check, and the fact that the final count is taken over the deduplicated `seen` map rather than
# over the raw approvals slice. Removing either alone leaves the other catching it, so a
# single-line mutation reports "survived" while the property is in fact enforced. The realistic
# regression is someone "simplifying" both at once into `len(approvals) >= 2`, which is exactly
# what this reproduces.
run_case exception ./privacy/ 'TestOverrideRequiresTwoDistinctOperators' \
  'distinctness removed AND the count taken over raw approvals (len(approvals) >= 2)' \
  's/\t\tif seen\[approval\.OperatorID\] \{/\t\tif false \{/; s/\tif len\(seen\) < MinApprovals \{/\tif len(e.Approvals) < MinApprovals \{/'

# 7. Requester may approve their own erasure.
run_case exception ./privacy/ 'TestOverrideRequesterMayNotApprove' \
  'requester-is-approver separation of duties removed' \
  's/\t\tif requesterID != "" && approval\.OperatorID == requesterID \{/\t\tif false \{/'

# 8. Minimum-approvals floor removed.
run_case exception ./privacy/ 'TestOverrideRequiresTwoDistinctOperators' \
  'the two-approval minimum is no longer enforced' \
  's/\tif len\(seen\) < MinApprovals \{/\tif false \{/'

# 9. Signature verification removed.
run_case exception ./privacy/ 'TestOverrideSignatureIsBoundToEveryMaterialField' \
  'Ed25519 signature verification removed' \
  's/\t\tif !ed25519\.Verify\(operator\.PublicKey, signingMessage\(e, approval\.OperatorID\), approval\.Signature\) \{/\t\tif operator.ID == "" \{/'

# 10. Exception validity ceiling removed — permanent overrides accepted.
run_case exception ./privacy/ 'TestRetentionExceptionMustBeTimeBounded' \
  'MaxExceptionValidity ceiling removed; an override may run indefinitely' \
  's/\tif e\.ExpiresAt\.Sub\(e\.IssuedAt\) > MaxExceptionValidity \{/\tif false \{/; s/\tif e\.ExpiresAt\.Sub\(now\) > MaxExceptionValidity \{/\tif false \{/'

# 11. Expiry requirement removed.
#
# COMPOUND, and it took three lines rather than the two first attempted. THREE independent checks
# refuse a zero ExpiresAt: the explicit IsZero test, the "expiry must be after issue" ordering test
# (the zero time is never after a real IssuedAt), and the freshness test (now is never before the
# zero time). Removing two of the three still left the third catching it, and the case reported
# "survived" while the property was in fact enforced — which is the whole reason this harness
# exists and is worth recording. With all three gone, both the zero-expiry and already-expired
# subtests admit an invalid override.
run_case exception ./privacy/ 'TestRetentionExceptionMustBeTimeBounded' \
  'all three checks that would refuse an unexpiring override are removed' \
  's/\tif e\.ExpiresAt\.IsZero\(\) \{/\tif false \{/; s/\tif !e\.ExpiresAt\.After\(e\.IssuedAt\) \{/\tif false \{/; s/\tif !now\.Before\(e\.ExpiresAt\) \{/\tif false \{/'

# 12. Enumerated-ground requirement removed — free-form justifications accepted.
run_case exception ./privacy/ 'TestRetentionExceptionMustNameAnEnumeratedGround' \
  'free-form grounds accepted in place of the five Article 17(3) values' \
  's/\tif !e\.Ground\.Valid\(\) \{/\tif false \{/'

# 13. Request-to-exception binding removed — an override becomes replayable.
run_case exception ./privacy/ 'TestRetentionExceptionMustBeBoundToThisRequest' \
  'override is no longer bound to its request id (replayable)' \
  's/\tif e\.RequestID != req\.RequestID \{/\tif false \{/'

# 14. Operator registry bound removed.
run_case operator ./privacy/ 'TestOperatorRegistryIsBounded' \
  'MaxOperators bound removed; the authorised set becomes unbounded' \
  's/\tif len\(operators\) > MaxOperators \{/\tif false \{/'

# 15. Registry accepts an absent environment variable as an empty permissive set.
#
# COMPOUND. Three independent things refuse an absent variable: the empty-string check, the JSON
# parse (which rejects ""), and NewOperatorRegistry's refusal of an empty list. Disabling only the
# first leaves the parse failing, which reads as "survived" while the property holds. This
# reproduces the whole helpful-default regression: treat absent as "[]", then let an empty
# registry through.
run_case operator ./privacy/ 'TestOperatorRegistryFromEnvFailsClosed' \
  'absent registry variable defaults to an empty, permissive registry' \
  's/\tif raw == "" \{\n\t\treturn nil, fmt\.Errorf\("%s is required: the set of operators authorised to override a legal hold must be explicitly configured", OperatorRegistryEnvVar\)\n\t\}/\tif raw == "" \{\n\t\traw = "[]"\n\t\}/; s/\tif len\(operators\) == 0 \{/\tif false \{/'

# 16. Request staleness bound removed.
run_case erasure ./privacy/ 'TestErasureHold_StaleRequestIsRefused' \
  'MaxRequestAge removed; an arbitrarily old pending request executes' \
  's/\tif now\.Sub\(req\.RequestedAt\) > MaxRequestAge \{/\tif false \{/'

# 17. Zero requested_at accepted (every stale request would read as fresh).
run_case erasure ./privacy/ 'TestErasureHold_ZeroAndFutureRequestTimesAreRefused' \
  'a zero requested_at is accepted and treated as age zero' \
  's/\tif req\.RequestedAt\.IsZero\(\) \{/\tif false \{/'

# 18. Audit failure no longer blocks destruction.
run_case erasure ./privacy/ 'TestErasureHold_AuditFailureRefusesAndDoesNotDestroy' \
  'a failed audit write no longer prevents key destruction' \
  's/\tif err := s\.writeDecision\(ctx, d\); err != nil \{\n\t\td\.Permitted = false/\tif false \{\n\t\td.Permitted = false/'

# 19. Refusal audit write removed entirely.
run_case erasure ./privacy/ 'TestErasureHold_ContainedActorErasureIsRefused' \
'refusals are no longer written to the audit trail' \
  's/^func \(s \*Service\) writeDecision\(ctx context\.Context, d Decision\) error \{$/func (s *Service) writeDecision(ctx context.Context, d Decision) error \{\n\tif d.RequestID != "" \{ return nil \}/m'

# 20. Retention precedence inverted — expiry overrides an active hold.
run_case retention ./privacy/ 'TestRetentionPrecedenceTruthTable' \
  'retention expiry overrides an active legal hold (precedence inverted)' \
  's/\tcase len\(active\) > 0:\n\t\td\.Deletable = false/\tcase len(active) > 0:\n\t\td.Deletable = true/'

# 21. Retention evaluation fails open on unavailable incident state.
#
# COMPOUND. Dropping only the error return lets control reach the jurisdiction check, which refuses
# anyway because the zero-valued result reports no jurisdiction. Both arms go, so what is being
# proven is the behaviour — a sweeper that cannot read holds must not delete — rather than one line.
run_case retention ./privacy/ 'TestRetentionPrecedenceFailsClosed' \
  'retention sweeper proceeds when holds cannot be read at all' \
  's/\t\treturn d, fmt\.Errorf\("%w: %v", ErrIncidentStateUnavailable, err\)/\t\terr = nil/; s/\tif !res\.Jurisdiction \{/\tif false \{/'

# 22. Migration 008 embedded and concatenated but never executed.
run_case migrations ./identity/ 'TestMigration008IsWiredIntoApplyMigrations' \
  'migration 008 is declared but never executed by ApplyMigrations' \
  's/\tif _, err := tx\.ExecContext\(ctx, Migration008RetentionLegalHolds\); err != nil \{\n\t\treturn fmt\.Errorf\("failed to execute identity graph migration 008: %w", err\)\n\t\}//'

# 23. The erasure route loses its dedicated permission.
run_case operator ./privacy/ 'TestErasureHold_NoDevelopmentOptInRelaxesAnyGate' \
  'a development opt-in environment variable is introduced into the package' \
  's/\traw := os\.Getenv\(OperatorRegistryEnvVar\)/\tif os.Getenv("INSECURE_SKIP_ERASURE_HOLD") == "1" \{ return \&OperatorRegistry\{byID: map[string]Operator\{\}\}, nil \}\n\traw := os.Getenv(OperatorRegistryEnvVar)/'

echo
echo "── integrity ──────────────────────────────────────────────────────────"
INTEGRITY_OK=1
for label in "${!TARGETS[@]}"; do
  now="$(sha256sum "${TARGETS[$label]}" | cut -d' ' -f1)"
  if [[ "$now" != "${ORIGINAL_SUM[$label]}" ]]; then
    echo "✗ ${label} was NOT restored to its original content"
    INTEGRITY_OK=0
  fi
done
[[ "$INTEGRITY_OK" -eq 1 ]] && echo "every mutated file restored byte-for-byte"

echo
echo "══ result ═════════════════════════════════════════════════════════════"
echo "controls proven failable: ${PASS}"
echo "controls NOT proven:      ${FAIL}"
if [[ "$FAIL" -eq 0 && "$INTEGRITY_OK" -eq 1 && "$PASS" -gt 0 ]]; then
  echo "VERDICT: PASS — every mutated control was caught by its named test"
  exit 0
fi
echo "VERDICT: FAIL"
exit 1
