#!/usr/bin/env bats
# ==============================================================================
# test/prelive-clean-down.bats — Verification of clean-down reset and swarm lifecycle
# ==============================================================================

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/prelive-clean-down.sh"
}

@test "prelive-clean-down.sh exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

@test "prelive-clean-down.sh is syntactically valid bash" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "prelive-clean-down.sh --help documents --clean, --check, --full, and --restore-swarm" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--clean"* ]]
  [[ "$output" == *"--check"* ]]
  [[ "$output" == *"--full"* ]]
  [[ "$output" == *"--restore-swarm"* ]]
}

@test "prelive-clean-down.sh rejects unknown options with code 2" {
  run "$SCRIPT" --invalid-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: unknown option: --invalid-flag"* ]]
}

@test "do_clean_down contains agent-swarm suspension and fe-signalloom-agents scale-down logic" {
  # Invariant: ResourceSet suspension MUST use fluxcd.controlplane.io/reconcile=disabled
  run grep -E "annotate.*resourceset.*agent-swarm.*reconcile=disabled" "$SCRIPT"
  [ "$status" -eq 0 ]

  # Invariant: deployments and statefulsets in fe-signalloom-agents must be scaled to 0
  run grep -E "scale deployment.*-n fe-signalloom-agents.*--replicas=0" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E "scale statefulset.*-n fe-signalloom-agents.*--replicas=0" "$SCRIPT"
  [ "$status" -eq 0 ]

  # Invariant: agent pods in fe-signalloom-agents must be deleted
  run grep -E "delete pod.*-n fe-signalloom-agents.*signalloom\.ai/agent=true" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "do_restore_swarm function exists and contains un-suspend and scale-up logic" {
  run grep -E "do_restore_swarm\(\)" "$SCRIPT"
  [ "$status" -eq 0 ]

  # Invariant: ResourceSet un-suspend must remove reconcile annotation
  run grep -E "annotate.*resourceset.*agent-swarm.*reconcile-" "$SCRIPT"
  [ "$status" -eq 0 ]

  # Invariant: scale fe-signalloom-agents back up
  run grep -E "scale deployment.*-n fe-signalloom-agents.*--replicas=1" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Makefile wires demo-signalloom-swarm-restore to prelive-clean-down.sh --restore-swarm" {
  run grep -E "^demo-signalloom-swarm-restore:" "${REPO_ROOT}/Makefile"
  [ "$status" -eq 0 ]

  run grep -E "prelive-clean-down\.sh.*--restore-swarm" "${REPO_ROOT}/Makefile"
  [ "$status" -eq 0 ]
}

@test "Mock execution of prelive-clean-down.sh --clean invokes swarm suspension, workload scale-down, and pod deletion" {
  local mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$mock_bin"
  local log_file="${BATS_TEST_TMPDIR}/kubectl.log"
  cat <<'EOF' > "${mock_bin}/kubectl"
#!/usr/bin/env bash
echo "$*" >> "${MOCK_KUBECTL_LOG}"
if [[ "$*" == *"get deployment"* ]] || [[ "$*" == *"get nodes"* ]]; then
  exit 0
fi
if [[ "$*" == *"psql"* ]] || [[ "$*" == *"SELECT COUNT"* ]]; then
  echo "0"
  exit 0
fi
exit 0
EOF
  chmod +x "${mock_bin}/kubectl"

  # Stub psql and redis-cli if needed
  cat <<'EOF' > "${mock_bin}/redis-cli"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${mock_bin}/redis-cli"

  MOCK_KUBECTL_LOG="$log_file" PATH="${mock_bin}:${PATH}" run "$SCRIPT" --clean
  [ "$status" -eq 0 ]

  run grep "annotate resourceset agent-swarm fluxcd.controlplane.io/reconcile=disabled" "$log_file"
  [ "$status" -eq 0 ]

  run grep "annotate resourceset signalloom-infra fluxcd.controlplane.io/reconcile=disabled" "$log_file"
  [ "$status" -eq 0 ]

  run grep "scale deployment --all -n fe-signalloom-agents --replicas=0" "$log_file"
  [ "$status" -eq 0 ]

  run grep "scale statefulset --all -n fe-signalloom-agents --replicas=0" "$log_file"
  [ "$status" -eq 0 ]

  run grep "delete pod -n fe-signalloom-agents -l signalloom.ai/agent=true" "$log_file"
  [ "$status" -eq 0 ]
}

@test "Mock execution of prelive-clean-down.sh --restore-swarm invokes swarm un-suspend and workload scale-up" {
  local mock_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$mock_bin"
  local log_file="${BATS_TEST_TMPDIR}/kubectl.log"
  cat <<'EOF' > "${mock_bin}/kubectl"
#!/usr/bin/env bash
echo "$*" >> "${MOCK_KUBECTL_LOG}"
exit 0
EOF
  chmod +x "${mock_bin}/kubectl"

  MOCK_KUBECTL_LOG="$log_file" PATH="${mock_bin}:${PATH}" run "$SCRIPT" --restore-swarm
  [ "$status" -eq 0 ]

  run grep "annotate resourceset agent-swarm fluxcd.controlplane.io/reconcile-" "$log_file"
  [ "$status" -eq 0 ]

  run grep "annotate resourceset signalloom-infra fluxcd.controlplane.io/reconcile-" "$log_file"
  [ "$status" -eq 0 ]

  run grep "scale deployment --all -n fe-signalloom-agents --replicas=1" "$log_file"
  [ "$status" -eq 0 ]

  run grep "scale statefulset --all -n fe-signalloom-agents --replicas=1" "$log_file"
  [ "$status" -eq 0 ]
}
