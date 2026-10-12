#!/usr/bin/env bash
# scripts/verify-demo-reproducibility.sh — does the mission demo produce the same
# figures twice, and does it still refuse what it cannot measure?
#
# ═══ What this replaced ═════════════════════════════════════════════════════
#
# The previous version ran the demo twice and then threw both outputs away. Its
# "Validating Benchmark Data Contracts" section instead read four typed
# constants out of docs/signalloom/benchmarks/mission-benchmarks.json and
# asserted them against two typed thresholds in the same file:
#
#     assert freeze_p95 < 250.0          # freeze_p95 was the literal 12.0
#     assert fair_p95   < 35.0           # fair_p95   was the literal 18.4
#
# An assertion comparing a number you typed to a threshold you typed has no
# failure mode. It then asserted demonstration_status == 'SUCCESS' and that all
# six lifecycle steps were 'PASS' against an authored evidence file whose every
# field is a constant — three more assertions that could not fail, printed as
# "Reproducibility confirmed".
#
# ═══ What it asserts now, each with a real failure mode ═════════════════════
#
#   1. Both cycles exit 0.                      Fails if a producer breaks.
#   2. The DERIVED risk figures are byte-identical between cycles. Fails if the
#      Monte Carlo seed is ever unpinned, which is the actual reproducibility
#      risk in this demonstration. This is the assertion the file is named for
#      and the one the old version omitted entirely.
#   3. The wall-clock timing line is explicitly EXCLUDED from the comparison and
#      the exclusion is stated. Timing is not reproducible and pretending it is
#      would be the same defect in the other direction.
#   4. Every refusal in cycle 1 is still a refusal in cycle 2 — a metric cannot
#      acquire a number between runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEMO="${REPO_ROOT}/scripts/demo-crkc-mission.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CYCLE1="${WORK}/cycle1.txt"
CYCLE2="${WORK}/cycle2.txt"

echo "=== Cycle 1 ==="
"${DEMO}" | tee "${CYCLE1}"

echo ""
echo "=== Cycle 2 ==="
"${DEMO}" | tee "${CYCLE2}"

# Lines that are expected to differ between two honest runs, and why. Each entry
# is a deliberate, named exclusion rather than a loose fuzzy match: anything not
# named here must be identical, so a newly-nondeterministic figure fails rather
# than slipping through a permissive filter.
#
#   Timestamp:          wall clock of the run
#   wall clock:         the measured riskctl latency, which is the point
#   riskctl wall clock: the same figure repeated in the closing summary
normalise() {
	grep -vE '^  Timestamp:|wall clock' "$1"
}

echo ""
echo "=== Determinism of the derived figures ==="
echo "Excluded from the comparison, by name: the run timestamp and the riskctl"
echo "wall-clock latency. A timing figure that reproduced exactly would mean it"
echo "was not being measured."

if diff -u <(normalise "${CYCLE1}") <(normalise "${CYCLE2}"); then
	echo "Identical across both cycles: the exposure figures, the simulation seed"
	echo "and iteration count, the tier verdict, the invariant digest, and every"
	echo "refusal."
else
	echo "FAIL: the demonstration is not reproducible — the diff above shows a" >&2
	echo "      derived figure that moved between two runs of the same inputs." >&2
	echo "      The usual cause is an unpinned Monte Carlo seed." >&2
	exit 1
fi

echo ""
echo "=== Refusals stay refusals ==="
C1_REFUSALS="$(grep -c 'UNAVAILABLE' "${CYCLE1}" || true)"
C2_REFUSALS="$(grep -c 'UNAVAILABLE' "${CYCLE2}" || true)"
if [ "${C1_REFUSALS}" -lt 1 ]; then
	echo "FAIL: cycle 1 refused nothing. Three of this demonstration's five" >&2
	echo "      headline metrics have no producer offline; a run that reports all" >&2
	echo "      five is fabricating." >&2
	exit 1
fi
if [ "${C1_REFUSALS}" != "${C2_REFUSALS}" ]; then
	echo "FAIL: refusal count moved between cycles (${C1_REFUSALS} then ${C2_REFUSALS})." >&2
	echo "      A metric cannot acquire a producer between two runs." >&2
	exit 1
fi
echo "Both cycles refused the same ${C1_REFUSALS} unproducible metrics."

echo ""
echo "=== Note on the authored evidence artefact ==="
echo "docs/signalloom/evidence/mission-demonstration-proof.json is NOT asserted"
echo "against here. Its six lifecycle steps, its SUCCESS status and its metrics"
echo "block are typed constants with no producer, so asserting them would be the"
echo "tautology this harness was rewritten to remove. It is out of scope for this"
echo "script; its contents are a docs-owner question (card CRKC-P4-2)."

echo ""
echo "Reproducibility verified: derived figures identical, timing excluded by"
echo "name, refusals stable. No claim is made about any metric this"
echo "demonstration cannot produce."
