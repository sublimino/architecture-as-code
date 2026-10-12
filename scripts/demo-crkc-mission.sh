#!/usr/bin/env bash
# scripts/demo-crkc-mission.sh — Signal Loom CRKC mission demonstration, offline.
#
# ═══ THE ONE RULE OF THIS SCRIPT ════════════════════════════════════════════
#
# It prints only figures it computed during this run. A metric with no producer
# in this environment is printed as UNAVAILABLE with a reason, never as a
# number — not a sensible default, not a representative constant, not a figure
# borrowed from a different run.
#
# This is enforced, not aspirational: test/demo-mission-honesty.bats asserts
# that no metric-shaped token in this script's output is a literal in this
# script's source. A measured value reaches stdout through a variable and so
# cannot be a source literal. Keeping that test green is the whole contract.
#
# Corollary, and the reason the rule is stated so bluntly: this script prints no
# thresholds either. "SLA: < 1000ms" reads as a result when it sits next to a
# figure, and once a threshold is on screen the temptation to put a passing
# number beside it is the defect this file used to have. Declared thresholds
# live in docs/signalloom/benchmarks/mission-benchmarks.json, labelled as
# requirements rather than observations.
#
# ═══ What this replaced, so it is not reintroduced by someone tidying up ════
#
#   1. A hardcoded closing banner — "Mission Demonstration Completed
#      Successfully (100% Green)" plus four metric constants, no shell
#      expansion anywhere in them. It contradicted the script's own
#      measurement: line 31 printed a genuinely measured ${CALC_MS} and line 52
#      then printed an unrelated 18.4ms for the same metric.
#
#   2. `riskctl baseline > /dev/null 2>&1 || true` followed by an echo of
#      "ALE £13,346.97, VaR95 £308,558.93". The output went to /dev/null, the
#      failure was swallowed, and the binary is not committed — so that
#      invocation had never once succeeded in the lifetime of the file. Both
#      figures are real riskctl outputs but from DIFFERENT agents: the ALE from
#      agent-remediation@2.1.0, the VaR95 from agent-olly-sentinel@2.1.0. No
#      single invocation can produce the pair. The real VaR95 for the agent
#      named is £0 — the distribution is tail-dominated, so more than 95% of
#      simulated years cost nothing — and the real verdict is `denied`. A zero
#      and a denial were replaced by another agent's figure, which is the exact
#      shape of the failure: a derivable number swapped for a better-looking one.
#
#   3. `sum(x**0.5 for x in range(20000))` timed under a comment calling it an
#      OpenFAIR stochastic draw, with the result asserted against a 35ms SLA.
#      The clock was honest; the thing on the clock was not the product. Phase 2
#      now times the real Monte Carlo and says precisely what it timed.
#
#   4. `[ -f ... ]` under a heading reading "Verification of Demo Artifacts &
#      Evidence". A file being on disk measures nothing. Phase 5 now calls
#      itself a presence check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Injectable boundaries. The risk engine and the policy compiler are the two
# real producers this script has; both are overridable so the honesty suite can
# prove the script dies rather than degrades when a producer is missing.
RISKCTL_BIN="${RISKCTL_BIN:-${REPO_ROOT}/tools/riskctl/riskctl}"
POLICY_COMPILER_BIN="${POLICY_COMPILER_BIN:-${REPO_ROOT}/bin/policy-compiler}"
RISK_AGENT="${RISK_AGENT:-agent-remediation}"
RISK_PACK="${RISK_PACK:-2.1.0}"
RISK_ORG="${RISK_ORG:-acme}"

refuse() {
	# One line per metric with no producer here. The reason is mandatory: a bare
	# UNAVAILABLE invites the reader to assume a transient glitch rather than a
	# structural absence, and then to accept a number next time.
	printf '  %-28s UNAVAILABLE\n' "$1"
	printf '  %-28s reason: %s\n' "" "$2"
}

echo "=========================================================="
echo "  Signal Loom CRKC Mission Demonstration"
echo "  Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Scope:     offline. No cluster, no network, no API key."
echo "=========================================================="

echo ""
echo "--- Phase 1: OpenFAIR exposure, computed now ---"

if [ ! -x "${RISKCTL_BIN}" ]; then
	echo "FATAL: no risk engine at ${RISKCTL_BIN}" >&2
	echo "       Build it with: make riskctl" >&2
	echo "       This phase has exactly one producer. Without it there is no" >&2
	echo "       exposure figure, and a demonstration that prints one anyway is" >&2
	echo "       the defect this script was rewritten to remove." >&2
	exit 1
fi

RISK_CMD=("${RISKCTL_BIN}" risk --json --agent "${RISK_AGENT}" --pack "${RISK_PACK}" --org "${RISK_ORG}")
RISK_JSON="$(mktemp)"
trap 'rm -f "${RISK_JSON}"' EXIT

# Wall clock around the real Monte Carlo. No `|| true`: a risk engine that
# cannot produce a figure is a failed demonstration, not a quiet one.
RISK_START_NS=$(date +%s%N)
"${RISK_CMD[@]}" > "${RISK_JSON}"
RISK_END_NS=$(date +%s%N)
RISK_ELAPSED_MS=$(( (RISK_END_NS - RISK_START_NS) / 1000000 ))

echo "  command: riskctl risk --json --agent ${RISK_AGENT} --pack ${RISK_PACK} --org ${RISK_ORG}"
python3 - "${RISK_JSON}" <<'PY'
import json, sys

rep = json.load(open(sys.argv[1]))
sim = rep["Simulation"]
exp = rep["Exposure"]
sym = {"GBP": "£", "EUR": "€", "USD": "$", "JPY": "¥"}.get(rep["Currency"], "")


def amount(key):
    m = exp[key]
    return f"{sym}{m['amount']:,.2f}"


print(f"  seed {sim['seed']}, {sim['iterations']:,} iterations, "
      f"risk load {sim['riskLoad']:.2f}, reported in {rep['Currency']}")
print(f"  ALE    (the average year)      {amount('ale'):>18}")
print(f"  VaR95  (the bad year)          {amount('var95'):>18}")
print(f"  TVaR   (the tail beyond VaR95) {amount('tvar'):>18}")
print(f"  carried (TVaR + risk load)     {amount('carried'):>18}")
if sim.get("tailDominated"):
    print("  NOTE: tail-dominated — VaR95 sits at or below ALE because the 95th")
    print("        percentile year costs nothing. A VaR95 of zero here is a result,")
    print("        not a missing value, and must not be replaced.")
guards = {k: v for k, v in sim.get("guards", {}).items() if v}
print(f"  simulation guards fired: {guards if guards else 'none'}")
print(f"  tier verdict: {rep['Tier']} — {rep['TierReason']}")
PY

echo ""
echo "--- Phase 2: Latency of the exposure computation above ---"
echo "  Timed: wall clock around the riskctl invocation in Phase 1, including"
echo "  process start and JSON encode, on this host under its current load."
echo "  riskctl risk wall clock: ${RISK_ELAPSED_MS}ms"
echo "  NOT a service-level figure. The in-cluster policy-engine FAIR endpoint"
echo "  is the thing the latency SLA is written against, and it is not being"
echo "  exercised here, so no threshold is assessed against this number."

echo ""
echo "--- Phase 3: Tier 0 in-kernel killswitch ---"
refuse "Killswitch freeze latency" \
	"needs a live cgroup v2 freezer acting on a running agent workload; no cluster in scope here"
refuse "TC classifier packet drop" \
	"needs a tc clsact qdisc on a real veth under measured load; no dataplane in scope here"
echo "  The local delegate this phase used to call, test/bench-redteam-stress.sh,"
echo "  is not a measurement: it derives its per-cycle figure from a modulo of a"
echo "  python loop's duration and then hardcodes its p95 outright. It is a known"
echo "  fabrication owned elsewhere (P6-1) and is deliberately NOT invoked from"
echo "  an operator-facing script. Run 'make bench-redteam-stress' if you want"
echo "  to see it knowingly."

echo ""
echo "--- Phase 4: Tier 1 invariant compilation and cross-tier equivalence ---"
if [ ! -x "${POLICY_COMPILER_BIN}" ]; then
	echo "FATAL: no policy compiler at ${POLICY_COMPILER_BIN}" >&2
	exit 1
fi
"${POLICY_COMPILER_BIN}" validate -i "${REPO_ROOT}/config/security-invariants.yaml"
refuse "GitOps label retention" \
	"needs N observed Flux reconcile cycles against a live cluster; the compiler proves the manifest, not the retention"

echo ""
echo "--- Phase 5: Presence check on the demonstration artefacts ---"
echo "  Presence only. A file being on disk is not a measurement of anything it"
echo "  describes, and this phase makes no claim about its contents."
for artefact in \
	"docs/signalloom/benchmarks/mission-benchmarks.json" \
	"docs/signalloom/evidence/mission-demonstration-proof.json" \
	"docs/signalloom/media/mission-architecture.svg"; do
	if [ -f "${REPO_ROOT}/${artefact}" ]; then
		printf '  present   %s\n' "${artefact}"
	else
		printf '  MISSING   %s\n' "${artefact}"
		exit 1
	fi
done
echo "  NOTE: mission-demonstration-proof.json is an authored artefact with no"
echo "  producer — its six lifecycle steps and its metrics block are typed"
echo "  constants, not observations. It is not owned by this script and nothing"
echo "  here treats it as evidence."

echo ""
echo "=========================================================="
echo "  Measured in this run"
echo "=========================================================="
echo "  OpenFAIR exposure           see Phase 1 (riskctl, pinned seed)"
echo "  riskctl wall clock          ${RISK_ELAPSED_MS}ms"
echo "  Invariant manifest          validated by policy-compiler (Phase 4)"
echo ""
echo "  Refused — no producer in this environment"
refuse "Killswitch freeze latency" "no live cgroup v2 freezer"
refuse "TC classifier packet drop" "no dataplane"
refuse "GitOps label retention"    "no Flux reconcile loop"
echo "=========================================================="
echo "  This run demonstrated the offline half of the lifecycle and refused the"
echo "  other half rather than narrating it. There is no overall pass rate to"
echo "  report: the script does not know one, so it does not print one."
echo "=========================================================="
