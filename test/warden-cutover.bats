#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      warden-cutover
# @target  scripts/warden-cutover.sh
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 3, ADR-07 (P3-1)
#
# Test harness for the no-overlap warden cutover script against fake kubectl and flux.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/warden-cutover.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${STATE}" "${BIN}"

  # Default fake secrets present
  touch "${STATE}/secret_fe-signalloom_signal-ingest-key-signalloom-warden"
  touch "${STATE}/secret_fe-signalloom-agents_signalloom-warden-ingest-token"
  touch "${STATE}/secret_fe-signalloom-agents_signalloom-warden-fleet-key"

  cat >"${BIN}/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"${FAKE_STATE}/log"
case "$*" in
  *"get secret"*)
    ns="$(sed -n 's/.*-n \([^ ]*\).*/\1/p' <<<"$*")"
    name="$(awk '{print $NF}' <<<"$*")"
    if [ -f "${FAKE_STATE}/secret_${ns}_${name}" ]; then
      exit 0
    else
      exit 1
    fi
    ;;
  *"delete ds stun-sentinel"*)
    echo "deleted_stun_sentinel" >>"${FAKE_STATE}/events"
    rm -f "${FAKE_STATE}/stun_sentinel_running"
    exit 0
    ;;
  *"get pods -l app.kubernetes.io/name=stun-sentinel"*)
    if [ -f "${FAKE_STATE}/stun_sentinel_running" ]; then
      echo "pod/stun-sentinel-abcde"
    fi
    exit 0
    ;;
  *"rollout status ds/signalloom-warden"*)
    if [ -f "${FAKE_STATE}/fail_rollout" ]; then
      exit 1
    fi
    exit 0
    ;;
  *"get ds -l signalloom.ai/role=sentinel"*)
    if [ -f "${FAKE_STATE}/extra_probe_ds" ]; then
      echo "signalloom-warden stun-sentinel"
    elif [ -f "${FAKE_STATE}/fail_rollout" ]; then
      echo ""
    else
      echo "signalloom-warden"
    fi
    exit 0
    ;;
  *"apply --server-side --dry-run=server"*)
    if [ -f "${FAKE_STATE}/fail_serverside_dry_run" ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${BIN}/kubectl"

  cat >"${BIN}/flux" <<'EOF'
#!/usr/bin/env bash
echo "flux $*" >>"${FAKE_STATE}/log"
case "$*" in
  *"suspend kustomization agent-signalloom-stun-sentinel"*)
    echo "suspended_legacy_kustomization" >>"${FAKE_STATE}/events"
    exit 0
    ;;
  *"reconcile kustomization"*|"reconcile kustomization tenants"*)
    echo "reconciled_flux" >>"${FAKE_STATE}/events"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${BIN}/flux"

  export SLDC_KUBECTL="${BIN}/kubectl"
  export SLDC_FLUX="${BIN}/flux"
  export FAKE_STATE="${STATE}"
  export KUBECONFIG=/dev/null
}

@test "warden-cutover: --context is required, exit 2" {
  run bash "${SCRIPT}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--context is required"* ]]
}

@test "warden-cutover: preflight fails and names missing secret before mutating cluster" {
  rm -f "${STATE}/secret_fe-signalloom-agents_signalloom-warden-ingest-token"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"fe-signalloom-agents/signalloom-warden-ingest-token is missing"* ]]
  [ ! -f "${STATE}/events" ]
}

@test "warden-cutover: preflight server-side dry-run failure stops and does not delete legacy probe" {
  touch "${STATE}/fail_serverside_dry_run"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"server-side dry-run failed"* ]]
  [ ! -f "${STATE}/events" ]
}

@test "warden-cutover: --dry-run exits 0 without mutating cluster" {
  run bash "${SCRIPT}" --context kind-osramp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] preflight successful"* ]]
  [ ! -f "${STATE}/events" ]
}

@test "warden-cutover: executes ordered cutover and verifies single probe DaemonSet" {
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 0 ]
  [[ "$output" == *"cutover successfully completed: signalloom-warden active and verified"* ]]
  grep -q "deleted_stun_sentinel" "${STATE}/events"
  grep -q "reconciled_flux" "${STATE}/events"
}

@test "warden-cutover: rollout failure stops and never recreates old DaemonSet" {
  touch "${STATE}/fail_rollout"
  run bash "${SCRIPT}" --context kind-osramp
  [ "$status" -eq 1 ]
  [[ "$output" == *"signalloom-warden rollout failed. Legacy daemonset was NOT recreated."* ]]
  # Assert legacy DaemonSet recreation was never attempted in log
  ! grep -q "apply.*stun-sentinel" "${STATE}/log"
}
