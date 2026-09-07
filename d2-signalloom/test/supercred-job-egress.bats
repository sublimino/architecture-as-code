#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  job="$root/d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml"
  policies="$root/d2-signalloom/infra/agent-swarm/networkpolicy.yaml"
}

@test "SuperCred runtime Job does not inherit generic agent network grants" {
  run yq 'select(.kind == "Job") | .spec.template.metadata.labels."signalloom.ai/agent"' "$job"
  [ "$status" -eq 0 ]
  [ "$output" = null ]
}

@test "SuperCred retains OpenBao consumer identity and workload service account" {
  [ "$(yq 'select(.kind == "Job") | .spec.template.metadata.labels."bao.controlplane.io/consumer"' "$job")" = cardvault-agent ]
  [ "$(yq 'select(.kind == "Job") | .spec.template.spec.serviceAccountName' "$job")" = cardvault-agent ]
}

@test "SuperCred agent Job declares its framework for admission" {
  [ "$(yq 'select(.kind == "Job") | .spec.template.metadata.labels."signalloom.ai/framework"' "$job")" = custom ]
}

@test "SuperCred Cardvault egress is scoped to the workload and destination" {
  yq -o=json 'select(.kind == "NetworkPolicy") | .spec' "$job" | python3 -c 'import json,sys
s=json.load(sys.stdin)
assert s["podSelector"] == {"matchLabels":{"app.kubernetes.io/name":"cardvault-agent","signalloom.ai/supercred":"true"}}
assert s["policyTypes"] == ["Egress"]
assert s["egress"] == [{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"inf-signalloom"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"cardvault"}}}],"ports":[{"protocol":"TCP","port":8080}]},{"to":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"inf-bao"}},"podSelector":{"matchLabels":{"app.kubernetes.io/name":"openbao"}}}],"ports":[{"protocol":"TCP","port":8200}]}]'
}

@test "Identity-plane egress stays opt-in and restricted to identity namespace ports" {
  run yq -o=json 'select(.metadata.name == "allow-identity-plane-egress") | .spec' "$policies"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys
s=json.load(sys.stdin)
assert s["podSelector"] == {"matchLabels":{"signalloom.ai/agent":"true"}}
assert s["policyTypes"] == ["Egress"]
assert len(s["egress"]) == 1
r=s["egress"][0]
assert r["to"] == [{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"inf-bao"}}}]
assert {(p["protocol"],p["port"]) for p in r["ports"]} == {("TCP",8081),("TCP",8200)}'
}
