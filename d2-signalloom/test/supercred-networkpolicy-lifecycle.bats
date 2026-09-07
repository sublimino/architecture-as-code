#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  fleet="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
  lifecycle="$repo_root/scripts/supercred-demo.sh"
  policy="allow-supercred-cardvault-egress"

  command -v yq >/dev/null || skip "yq is required to inspect fleet RBAC"
}

runner_agent_role() {
  yq -o=json 'select(.metadata.name == "signalloom-infra") | .spec.resources[] |
    select(.kind == "Role" and .metadata.name == "supercred-demo-runner" and
      .metadata.namespace == "fe-signalloom-agents")' "$fleet"
}

@test "SUPERCRED-NETPOL runner may create NetworkPolicies only inside agents namespace" {
  role="$(runner_agent_role)"
  [ -n "$role" ]

  run jq -e '[.rules[] | select(
    .apiGroups == ["networking.k8s.io"] and
    .resources == ["networkpolicies"] and
    .verbs == ["create"] and
    (has("resourceNames") | not))] | length == 1' <<<"$role"
  [ "$status" -eq 0 ]
}

@test "SUPERCRED-NETPOL name-addressable permissions are restricted to the demo policy" {
  role="$(runner_agent_role)"

  run jq -e --arg policy "$policy" '[.rules[] | select(
    .apiGroups == ["networking.k8s.io"] and
    .resources == ["networkpolicies"] and
    .resourceNames == [$policy] and
    ((.verbs | sort) == (["delete", "get", "patch"] | sort)))] | length == 1' <<<"$role"
  [ "$status" -eq 0 ]
}

make_kubectl_stub() {
  stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
if [[ "$*" == *"delete networkpolicy allow-supercred-cardvault-egress"* ]]; then
  exit "${POLICY_DELETE_RC:-0}"
fi
if [[ "$*" == *"get networkpolicy allow-supercred-cardvault-egress"* ]]; then
  exit "${POLICY_GET_RC:-1}"
fi
if [[ "$*" == *"get pod -l app.kubernetes.io/name=spire-server"* ]]; then
  exit 0
fi
case " $* " in
  *" delete "*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_dir/kubectl"
  export PATH="$stub_dir:$PATH"
  export KUBECTL_LOG="$BATS_TEST_TMPDIR/kubectl.log"
}

@test "SUPERCRED-NETPOL teardown fails when named policy deletion fails" {
  make_kubectl_stub

  run env POLICY_DELETE_RC=42 KUBECTL_LOG="$KUBECTL_LOG" PATH="$PATH" \
    bash "$lifecycle" 5
  [ "$status" -ne 0 ]
  grep -Fq "delete networkpolicy $policy -n fe-signalloom-agents" "$KUBECTL_LOG"
}

@test "SUPERCRED-NETPOL teardown verifies the named policy is absent" {
  make_kubectl_stub

  run env KUBECTL_LOG="$KUBECTL_LOG" PATH="$PATH" bash "$lifecycle" 5
  [ "$status" -eq 0 ]
  grep -Fq "get networkpolicy $policy -n fe-signalloom-agents" "$KUBECTL_LOG"
}

@test "SUPERCRED-NETPOL teardown fails when the named policy remains" {
  make_kubectl_stub

  run env POLICY_GET_RC=0 KUBECTL_LOG="$KUBECTL_LOG" PATH="$PATH" \
    bash "$lifecycle" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"NetworkPolicy $policy still exists after teardown"* ]]
}
