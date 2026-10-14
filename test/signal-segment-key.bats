#!/usr/bin/env bats
# @id     signal-segment-key
# @target scripts/signal-segment-key.sh
# @doc    docs/signalloom/sldp-downstream-contract.md
# @spec   signal-ingest with SIGNAL_STORE=frostdb needs Secret signal-ingest-segment-pseudonym
#         (SIGNAL_SEGMENT_PSEUDONYM_KEY: 32 bytes hex, SIGNAL_SEGMENT_PSEUDONYM_EPOCH), minted
#         idempotently by the bring-up; the key never reaches argv.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/signal-segment-key.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}/ns" "${BATS_TEST_TMPDIR}/bin"
  # The fake cluster is NAMESPACE-AWARE: one stored Secret per namespace under
  # ${FAKE_STATE}/ns/<namespace>. A single global `stored` file cannot represent
  # "present in fe-signalloom, absent in inf-signalloom", which is the exact
  # state that produced the defect this suite guards.
  #
  # ${FAKE_STATE}/applied is the concatenation of everything applied during ONE
  # script invocation: `cluster-info` runs exactly once per invocation, before
  # any apply, so it is the invocation boundary and truncates the file.
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"

ns="" verb="" jsonpath=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) ns="$2"; shift 2 ;;
    -o) jsonpath="$2"; shift 2 ;;
    --context) shift 2 ;;
    cluster-info|apply|get) [ -n "${verb}" ] || verb="$1"; shift ;;
    *) shift ;;
  esac
done

case "${verb}" in
  cluster-info)
    rm -f "${FAKE_STATE}/applied"
    if [ "${FAKE_KUBECTL_FAIL_CLUSTER_INFO:-0}" = "1" ]; then
      echo "Unable to connect to the server" >&2
      exit 1
    fi
    echo "Kubernetes control plane is running" ;;
  apply)
    manifest="$(cat)"
    printf '%s\n' "${manifest}" >>"${FAKE_STATE}/applied"
    target="$(awk '$1=="namespace:" {print $2; exit}' <<<"${manifest}")"
    [ -n "${target}" ] || { echo "fake kubectl: manifest has no namespace" >&2; exit 1; }
    mkdir -p "${FAKE_STATE}/ns"
    printf '%s\n' "${manifest}" >"${FAKE_STATE}/ns/${target}" ;;
  get)
    [ -n "${ns}" ] || { echo "fake kubectl: get without -n" >&2; exit 1; }
    [ -f "${FAKE_STATE}/ns/${ns}" ] || exit 1
    k="$(sed -n 's/.*{\.data\.\([A-Za-z0-9._-]*\)}.*/\1/p' <<<"${jsonpath}")"
    awk -v k="  ${k}:" 'index($0,k)==1 {print $2; exit}' "${FAKE_STATE}/ns/${ns}" | tr -d '\n' ;;
esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

# value KEY — the value from the FIRST manifest applied in the last invocation,
# which is the primary namespace (fe-signalloom).
value() { awk -v k="  $1:" 'index($0,k)==1 {print $2; exit}' "${STATE}/applied"; }

# nsvalue NS KEY — the value the fake cluster currently holds in NS.
nsvalue() {
  [ -f "${STATE}/ns/$1" ] || return 1
  awk -v k="  $2:" 'index($0,k)==1 {print $2; exit}' "${STATE}/ns/$1"
}

# seed_ns NS KEY_HEX EPOCH — put a Secret in NS without running the script, so
# a test can start from "present in one namespace, absent in another".
seed_ns() {
  mkdir -p "${STATE}/ns"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: signal-ingest-segment-pseudonym\n  namespace: %s\ntype: Opaque\ndata:\n  SIGNAL_SEGMENT_PSEUDONYM_KEY: %s\n  SIGNAL_SEGMENT_PSEUDONYM_EPOCH: %s\n' \
    "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')" "$(printf '%s' "$3" | base64 | tr -d '\n')" \
    >"${STATE}/ns/$1"
}

applies() { grep -c ' apply -f -' "${STATE}/argv" 2>/dev/null || true; }

@test "signal-segment-key: --context is required, exit 2, nothing applied" {
  run "${SCRIPT}"
  [ "$status" -eq 2 ]
  [ ! -f "${STATE}/applied" ]
}

@test "signal-segment-key: fresh run creates the Secret with a 32-byte hex key and epoch 1" {
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"created"* ]]
  grep -q 'name: signal-ingest-segment-pseudonym' "${STATE}/applied"
  grep -q 'namespace: fe-signalloom' "${STATE}/applied"
  key="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [ "${#key}" -eq 64 ]
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "1" ]
}

@test "signal-segment-key: re-run keeps the key (zero apply calls)" {
  "${SCRIPT}" --context kind-test >/dev/null
  first="$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY)"
  [ -n "${first}" ]
  : >"${STATE}/argv"
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept"* ]]
  [ "$(applies)" -eq 0 ]
  [ "$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY)" = "${first}" ]
  [ "$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY)" = "${first}" ]
}

@test "signal-segment-key: --rotate writes a new key and bumps the epoch" {
  "${SCRIPT}" --context kind-test >/dev/null
  first="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)"
  run "${SCRIPT}" --context kind-test --rotate
  [ "$status" -eq 0 ]
  [[ "$output" == *"rotated"* ]]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)" != "${first}" ]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "2" ]
}

@test "signal-segment-key: the key never appears in argv, stdout or stderr" {
  run --separate-stderr "${SCRIPT}" --context kind-test
  key="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [ -n "${key}" ]
  ! grep -qF "${key}" "${STATE}/argv"
  [[ "$output" != *"${key}"* ]]
  [[ "$stderr" != *"${key}"* ]]
}

@test "signal-segment-key: unreachable cluster is exit 1 with nothing applied" {
  FAKE_KUBECTL_FAIL_CLUSTER_INFO=1 run "${SCRIPT}" --context kind-test
  [ "$status" -eq 1 ]
  [ ! -f "${STATE}/applied" ]
}

@test "signal-segment-key: a fresh run mints the Secret into BOTH fe-signalloom and inf-signalloom" {
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [ "$(applies)" -eq 2 ]
  fe="$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  inf="$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [[ "${fe}" =~ ^[0-9a-f]{64}$ ]]
  [[ "${inf}" =~ ^[0-9a-f]{64}$ ]]
  # The HMAC domain is per cluster: the SAME bytes in every namespace.
  [ "${fe}" = "${inf}" ]
  [ "$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "1" ]
  [ "$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "1" ]
}

@test "signal-segment-key: an existing fe-signalloom key is PROPAGATED to inf-signalloom, not regenerated" {
  pre="aa11bb22cc33dd44ee55ff6600778899aa11bb22cc33dd44ee55ff6600778899"
  seed_ns fe-signalloom "${pre}" 7
  : >"${STATE}/argv"
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"propagated"* ]]
  # Exactly one apply — inf-signalloom only; fe-signalloom was already correct.
  [ "$(applies)" -eq 1 ]
  [ "$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)" = "${pre}" ]
  # The key BYTES must be equal, not merely present: a fresh key here would
  # split the HMAC domain and no component would report it.
  [ "$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)" = "${pre}" ]
  # Propagation is not a rotation: the epoch carries over untouched.
  [ "$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "7" ]
  [ "$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "7" ]
  [[ "$output" != *"rotated"* ]]
}

@test "signal-segment-key: --rotate lands one identical new key in both namespaces with a bumped epoch" {
  pre="aa11bb22cc33dd44ee55ff6600778899aa11bb22cc33dd44ee55ff6600778899"
  seed_ns fe-signalloom "${pre}" 3
  seed_ns inf-signalloom "${pre}" 3
  run "${SCRIPT}" --context kind-test --rotate
  [ "$status" -eq 0 ]
  [[ "$output" == *"rotated"* ]]
  fe="$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  inf="$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [[ "${fe}" =~ ^[0-9a-f]{64}$ ]]
  [ "${fe}" != "${pre}" ]
  [ "${fe}" = "${inf}" ]
  [ "$(nsvalue fe-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "4" ]
  [ "$(nsvalue inf-signalloom SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "4" ]
}

@test "signal-segment-key: with both namespaces in sync nothing is applied" {
  pre="aa11bb22cc33dd44ee55ff6600778899aa11bb22cc33dd44ee55ff6600778899"
  seed_ns fe-signalloom "${pre}" 5
  seed_ns inf-signalloom "${pre}" 5
  : >"${STATE}/argv"
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept"* ]]
  [ "$(applies)" -eq 0 ]
}

@test "signal-segment-key: policy-engine mounts the Secret this script mints, in both namespaces" {
  pe="${REPO_ROOT}/d2-signalloom/apps/policy-engine/base/deployment.yaml"
  # The mount is why inf-signalloom is a target at all.
  [ "$(grep -c 'name: signal-ingest-segment-pseudonym' "$pe")" -eq 2 ]
  # supercred-demo.sh applies that base into inf-signalloom.
  grep -q 'NAMESPACE_INFRA="inf-signalloom"' "${REPO_ROOT}/scripts/supercred-demo.sh"
  grep -q 'apps/policy-engine/base/ -n "\$NAMESPACE_INFRA"' "${REPO_ROOT}/scripts/supercred-demo.sh"
  # ...and refuses to start there without the Secret, so the Secret is
  # preflighted in that namespace before the 120s rollout is spent. A comment
  # mentioning the Secret must not satisfy this: assert the actual get.
  grep -qE 'kubectl -n "\$NAMESPACE_INFRA" get secret "\$segment_secret"' \
    "${REPO_ROOT}/scripts/supercred-demo.sh"
  # The failure must name the Secret AND the namespace AND the fix, on one
  # line, because the bare message sent an investigator to the wrong service.
  msg="$(grep -E '^ *fail "Secret \$segment_secret is missing from namespace \$NAMESPACE_INFRA' \
    "${REPO_ROOT}/scripts/supercred-demo.sh")"
  [ -n "${msg}" ]
  [[ "${msg}" == *'make signal-segment-key CONTEXT='* ]]
  # The rollout failure path reports the pod's own reason, not just "failed".
  grep -q 'rollout_failure_detail policy-engine "\$NAMESPACE_INFRA"' \
    "${REPO_ROOT}/scripts/supercred-demo.sh"
  grep -q '^rollout_failure_detail() {' "${REPO_ROOT}/scripts/supercred-demo.sh"
}

@test "signal-segment-key: the Deployment reads both values from the Secret this script mints" {
  ds="${REPO_ROOT}/d2-signalloom/apps/signal-ingest/base/deployment.yaml"
  grep -q 'name: SIGNAL_SEGMENT_PSEUDONYM_KEY' "$ds"
  grep -q 'name: SIGNAL_SEGMENT_PSEUDONYM_EPOCH' "$ds"
  [ "$(grep -c 'name: signal-ingest-segment-pseudonym' "$ds")" -eq 2 ]
  ! grep -A4 'name: SIGNAL_SEGMENT_PSEUDONYM_KEY' "$ds" | grep -q 'optional: true'
  grep -q 'signal-segment-key CONTEXT' "${REPO_ROOT}/Makefile"
}
