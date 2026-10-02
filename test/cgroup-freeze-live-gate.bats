#!/usr/bin/env bats
#
# @id      cgroup-freeze-live-gate
# @target  scripts/lib/live-gate.sh, test/cgroup-freeze-stun.bats,
#          test/cgroup-freeze-adversarial.bats, scripts/test-cgroup-freezer.sh,
#          scripts/stress-agent-cgroups.sh
#
# An "offline" run must never reach a shared kind node. On 2026-10-02 a run of
# the two cgroup-freeze suites under KUBECONFIG=/dev/null docker-cp'd a binary
# onto osramp-control-plane and pkill'd the deployed stun-sentinel (restart
# count 2): their live gate was `docker inspect <node>` alone.
#
# Every docker and kubectl call here goes to a recorder (SLDC_DOCKER,
# SLDC_KUBECTL), and the recorder answers as a live estate would: the node
# exists and the API server is up, even under KUBECONFIG=/dev/null, so the
# gate's own checks are what refuse. A broken gate is caught as a recorded
# node-touching call, and never reaches a real node, even under mutation.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FAKE="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls.log"
  mkdir -p "${FAKE}"
  : >"${CALLS}"
  cat >"${FAKE}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"${SLDC_CALLS:?}"
case "$1" in
  inspect) exit 0 ;;   # the node exists
  *)       exit 1 ;;   # anything else fails fast once recorded
esac
EOF
  cat >"${FAKE}/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"${SLDC_CALLS:?}"
case "$*" in
  *"get --raw /readyz"*) exit 0 ;;   # the API answers, whatever KUBECONFIG says
  *) exit 1 ;;
esac
EOF
  chmod +x "${FAKE}/docker" "${FAKE}/kubectl"
  export SLDC_DOCKER="${FAKE}/docker" SLDC_KUBECTL="${FAKE}/kubectl" SLDC_CALLS="${CALLS}"
  unset SLDC_LIVE
  # shellcheck source=../scripts/lib/live-gate.sh
  source "${REPO_ROOT}/scripts/lib/live-gate.sh"
}

# node_touches: recorded calls that reach into the node (exec, cp) or kill.
node_touches() { grep -E '^docker (exec|cp)|pkill' "${CALLS}" || true; }

@test "live-gate: closed without SLDC_LIVE=1 even when the node and API answer" {
  KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" run sldc_live_gate kind-osramp osramp-control-plane
  [ "$status" -eq 1 ]
  [ ! -s "${CALLS}" ]   # refused before asking docker or kubectl anything
}

@test "live-gate: closed under KUBECONFIG=/dev/null even with SLDC_LIVE=1" {
  SLDC_LIVE=1 KUBECONFIG=/dev/null run sldc_live_gate kind-osramp osramp-control-plane
  [ "$status" -eq 1 ]
  ! grep -q '^docker' "${CALLS}"
}

@test "live-gate: closed when the context does not answer /readyz" {
  printf '#!/usr/bin/env bash\necho "kubectl $*" >>"$SLDC_CALLS"; exit 1\n' >"${FAKE}/kubectl"
  SLDC_LIVE=1 KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" run sldc_live_gate kind-osramp osramp-control-plane
  [ "$status" -eq 1 ]
  ! grep -q '^docker' "${CALLS}"
}

@test "live-gate: open only with the opt-in, a reachable API and the node (positive control)" {
  SLDC_LIVE=1 KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" run sldc_live_gate kind-osramp osramp-control-plane
  [ "$status" -eq 0 ]
  grep -q 'get --raw /readyz' "${CALLS}"
  grep -q '^docker inspect osramp-control-plane' "${CALLS}"
}

@test "live-gate: both freeze harnesses refuse offline with exit 3 and touch no node" {
  for h in test-cgroup-freezer.sh stress-agent-cgroups.sh; do
    KUBECONFIG=/dev/null SLDC_LIVE=1 run bash "${REPO_ROOT}/scripts/${h}"
    [ "$status" -eq 3 ] || { echo "${h}: exit ${status}: ${output}"; return 1; }
    [[ "$output" == *"KUBECONFIG=/dev/null"* ]]
  done
  [ -z "$(node_touches)" ]
}

@test "live-gate: a harness with the gate open does reach the recorder (the recorder is not blind)" {
  KUBECONFIG="${BATS_TEST_TMPDIR}/kubeconfig" SLDC_LIVE=1 run bash "${REPO_ROOT}/scripts/test-cgroup-freezer.sh"
  [ "$status" -eq 3 ]   # stopped by the fake node having no curl
  grep -q '^docker exec osramp-control-plane' "${CALLS}"
}

# Each suite run includes one live test: offline it must SKIP (the suite's own
# gate said no), not fail, and nothing may have reached the node.
@test "live-gate: the stun suite run offline skips its live half and touches no node" {
  KUBECONFIG=/dev/null run bats --tap --filter 'arity|harness ran every probe' "${REPO_ROOT}/test/cgroup-freeze-stun.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ok 1 live: the harness ran every probe it declared # skip"* ]]
  [ -z "$(node_touches)" ] || { echo "touched: $(node_touches)"; return 1; }
}

@test "live-gate: the adversarial suite run offline skips its live half and touches no node" {
  KUBECONFIG=/dev/null run bats --tap --filter 'arity|harness ran every probe' "${REPO_ROOT}/test/cgroup-freeze-adversarial.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ok 1 live: the harness ran every probe it declared # skip"* ]]
  [ -z "$(node_touches)" ] || { echo "touched: $(node_touches)"; return 1; }
}
