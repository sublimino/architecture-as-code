#!/usr/bin/env bats
#
# @id      agent-behavior-signal-loop
# @target  scripts/signalloom-agents.sh
#
# Verifies that scripts/signalloom-agents.sh supports an active behavior loop mode
# (up-active) that provisions an active telemetry pulse and canary probe sidecar,
# while the standard up command provisions an inert pod without the behavior loop.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/signalloom-agents.sh"
  FAKE="${BATS_TEST_TMPDIR}/fake"
  mkdir -p "${FAKE}/bin"
  export FAKE_APPLIED="${FAKE}/applied-manifests.yaml"
  : >"${FAKE_APPLIED}"

  cat >"${FAKE}/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "${args}" == *" apply -f - "* ]]; then
  echo "---" >>"${FAKE_APPLIED}"
  cat >>"${FAKE_APPLIED}"
  exit 0
fi
if [[ "${args}" == *" get namespace "* ]]; then
  exit 0
fi
if [[ "${args}" == *" delete pods "* ]]; then
  exit 0
fi
if [[ "${args}" == *" get pods "* ]]; then
  exit 0
fi
echo "fake kubectl: unhandled: $*" >&2
exit 1
STUB
  chmod +x "${FAKE}/bin/kubectl"
  export PATH="${FAKE}/bin:${PATH}"
  export KUBECTL="${FAKE}/bin/kubectl"
}

@test "signalloom-agents up creates inert agent without behavior-loop container" {
  run "${SCRIPT}" up 1
  [ "$status" -eq 0 ]
  # Inert pod must NOT have behavior-loop sidecar
  ! grep -q "name: behavior-loop" "${FAKE_APPLIED}"
  # Inert pod must have state idle
  grep -q "signalloom.ai/state: idle" "${FAKE_APPLIED}"
}

@test "signalloom-agents up-active creates agent with active behavior-loop sidecar" {
  run "${SCRIPT}" up-active 1
  [ "$status" -eq 0 ]
  # Active pod MUST have behavior-loop sidecar
  grep -q "name: behavior-loop" "${FAKE_APPLIED}"
  # Active pod MUST have behavior label
  grep -q "signalloom.ai/behavior: active-loop" "${FAKE_APPLIED}"
  # Active pod MUST target signal-ingest in observation pulse
  grep -q "signal-ingest.fe-signalloom" "${FAKE_APPLIED}"
}

@test "signalloom-agents usage reports up-active command" {
  run "${SCRIPT}" --invalid-flag
  [ "$status" -eq 64 ]
  [[ "${output}" =~ "up-active" ]]
}
