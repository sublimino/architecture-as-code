#!/usr/bin/env bats
#
# @id      live-gate-ci-wiring
# @target  scripts/ci/vm-pipeline.sh, scripts/gcp-tf/demo-pipeline.sh
# @doc     scripts/lib/live-gate.sh
#
# scripts/lib/live-gate.sh refuses live node work unless SLDC_LIVE=1 is set and
# a cluster is reachable. That is right for an offline run: before it, an
# "offline" run docker-cp'd onto the shared node and killed the deployed
# sentinel. But a suite whose live half needs SLDC_LIVE=1 is run by CI with the
# variable unset, so its live half skips on every run. CI reports green and
# never exercises it.
#
# So, in EACH lane, every suite that uses the gate must be run by some stage
# that:
#   * comes after the staleness proof (stage6b), so the cluster is converged
#     and is this checkout;
#   * sets SLDC_LIVE=1 in that stage's own command.
#
# The suite list is derived from what sources live-gate.sh. The gate's own unit
# suite is excluded (live-gate.sh's @tests header names it): it drives the gate
# against stubs and is not live.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  cd "${REPO_ROOT}"
}

live_suites() {
  local own
  own="$(sed -n 's/^# @tests[[:space:]]*//p' scripts/lib/live-gate.sh | tr ' ,' '\n\n' | grep . )"
  # Suites that SOURCE the gate, not files that only mention it.
  rg -l --glob '*.bats' '^\s*(source|\.)\s+\S*scripts/lib/live-gate\.sh' test d2-signalloom/test | sort \
    | grep -vxF -f <(printf '%s\n' "${own}")
}

# lane_violations LANE_FILE -> one line per live suite with no post-stage6b
# run_stage that both names it and sets SLDC_LIVE=1.
lane_violations() {
  python3 - "$1" <(live_suites) <<'PY'
import re, sys
text = open(sys.argv[1]).read()
suites = [s for s in open(sys.argv[2]).read().split() if s]
stage = re.compile(r'run_stage \\\n\s*"[^"]*" \\\n\s*"([^"]*)" \\\n\s*"((?:[^"\\]|\\.)*)"', re.S)
stages = [(m.start(), m.group(1), m.group(2)) for m in stage.finditer(text)]
conv = [pos for pos, report, _ in stages if report.startswith("stage6b-deployed-staleness")]
if len(conv) != 1:
    print(f"CONVERGENCE-MARKER stage6b-deployed-staleness found {len(conv)} times")
    sys.exit(0)
for s in suites:
    ok = any(pos > conv[0] and s in cmd and re.search(r'(^|[\s;&])SLDC_LIVE=1\b', cmd)
             for pos, _, cmd in stages)
    if not ok:
        print(s)
PY
}

@test "live-gate wiring: the gated suite list is derived and non-trivial" {
  run live_suites
  [ "$status" -eq 0 ]
  [ "$(grep -c . <<<"$output")" -ge 3 ]
  [[ "$output" != *cgroup-freeze-live-gate.bats* ]]
}

@test "live-gate wiring: the CI lane runs every live-gated suite after convergence with SLDC_LIVE=1" {
  run lane_violations scripts/ci/vm-pipeline.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "vm-pipeline.sh never runs these live, so their live halves always skip:"; echo "$output"; return 1; }
}

@test "live-gate wiring: the demo lane runs every live-gated suite after convergence with SLDC_LIVE=1" {
  run lane_violations scripts/gcp-tf/demo-pipeline.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "demo-pipeline.sh never runs these live, so their live halves always skip:"; echo "$output"; return 1; }
}
