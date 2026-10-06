#!/usr/bin/env bats
#
# Offline proof that the agent identity-binding ValidatingAdmissionPolicy
# renders in the same Flux-owned Kustomization chain as the rest of
# fleet-manager, is wired to the single-source-of-truth identity map (the
# fleet-config ConfigMap), and that its CEL actually rejects the spoof case
# hosted-daytona-coder could create.
#
# @target d2-signalloom/apps/fleet-manager/base/agent-identity-binding.yaml
# @tests  d2-signalloom/apps/fleet-manager/agent_identity_binding_vap_test.go

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	VAP="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/agent-identity-binding.yaml"
	FM_KUST="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/kustomization.yaml"
	FE_KUST="$REPO_ROOT/d2-signalloom/apps/fe-signalloom/base/kustomization.yaml"
	CONFIGMAP="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/configmap.yaml"
}

@test "agent-identity-binding.yaml declares exactly the ValidatingAdmissionPolicy and its Binding" {
	run yq -N '.kind' "$VAP"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "ValidatingAdmissionPolicy" ]
	[ "${lines[1]}" = "ValidatingAdmissionPolicyBinding" ]

	run yq -N '.metadata.name' "$VAP"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "sl-agent-identity-binding" ]
	[ "${lines[1]}" = "sl-agent-identity-binding-binding" ]
}

@test "the policy is listed as a resource in fleet-manager's own Kustomization" {
	run yq -N '.resources[]' "$FM_KUST"
	[ "$status" -eq 0 ]
	printf '%s\n' "${lines[@]}" | grep -qx "agent-identity-binding.yaml"
}

@test "fleet-manager/base is pulled in by fe-signalloom/base, the Flux-reconciled Kustomization" {
	run yq -N '.resources[]' "$FE_KUST"
	[ "$status" -eq 0 ]
	printf '%s\n' "${lines[@]}" | grep -qx "../../fleet-manager/base"
}

@test "the binding's paramRef names the fleet-config ConfigMap that carries the identity map" {
	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.paramRef.name' "$VAP"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-config" ]

	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.paramRef.namespace' "$VAP"
	[ "$status" -eq 0 ]
	[ "$output" = "fe-signalloom" ]

	# The params object this binding names must actually carry identity.*
	# (ServiceAccount) keys, in the SAME file fleet-manager/identity_map.go
	# reads -- one authored list, proven by structure rather than by a
	# second hardcoded list in this test.
	run yq -N '.data | keys | .[] | select(test("^identity\\."))' "$CONFIGMAP"
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	# And the identity-ns.* (namespace) half of every pair, the one Andy's
	# review added: a ServiceAccount name alone is only unique within its
	# namespace.
	run yq -N '.data | keys | .[] | select(test("^identity-ns\\."))' "$CONFIGMAP"
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	# Every identity.<name> key has a matching identity-ns.<name> sibling --
	# a half-authored pair is dropped by every reader (identity_map.go,
	# agent_identity_map.py, this policy's `registered` variable), so an
	# orphaned half would silently stop protecting that agent.
	sa_names=$(yq -N '.data | keys | .[] | select(test("^identity\\.")) | sub("^identity\\.", "")' "$CONFIGMAP" | sort)
	ns_names=$(yq -N '.data | keys | .[] | select(test("^identity-ns\\.")) | sub("^identity-ns\\.", "")' "$CONFIGMAP" | sort)
	[ "$sa_names" = "$ns_names" ]
}

@test "the binding targets fe-signalloom-agents and denies" {
	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[0]' "$VAP"
	[ "$status" -eq 0 ]
	[ "$output" = "Deny" ]

	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.matchResources.namespaceSelector.matchExpressions[0].values[0]' "$VAP"
	[ "$status" -eq 0 ]
	[ "$output" = "fe-signalloom-agents" ]
}

@test "the policy's own CEL rejects a pod spoofing a registered agent's identity label" {
	run env CGO_ENABLED=0 go test -C "$REPO_ROOT/d2-signalloom/apps/fleet-manager" \
		-count=1 -run '^TestIdentityBindingVAP_' .
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ok"
}
