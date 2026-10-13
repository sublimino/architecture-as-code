#!/usr/bin/env bats
#
# Offline proof that the agent identity-binding ValidatingAdmissionPolicy is
# delivered through the fleet's cluster-level ResourceSet (reconciled by
# flux-system), NOT through any tenant-reconciled Kustomization, is wired to
# the single-source-of-truth identity map (the fleet-config ConfigMap), and
# that its CEL actually rejects the spoof case hosted-daytona-coder could
# create.
#
# This policy used to live at
# d2-signalloom/apps/fleet-manager/base/agent-identity-binding.yaml, pulled
# into fe-signalloom's `apps` Kustomization. That Kustomization is
# reconciled by the TENANT ServiceAccount
# system:serviceaccount:fe-signalloom:flux, which has no RBAC to touch
# cluster-scoped ValidatingAdmissionPolicy/-Binding objects -- a live
# deploy found that this made the tenant's entire `apps` dry-run apply
# fail, taking down everything else in that Kustomization with it
# (2026-10-07). The fix is NOT to grant the tenant SA admission-policy
# RBAC (a tenant that can edit admission policies can disable its own
# guardrails) -- it is to deliver the policy from the fleet's own
# cluster-level ResourceSet instead, the same way the pre-existing
# source.policy.fluxcd.controlplane.io policy already is.
#
# @target d2-osramp-fleet/tenants/base/policies.yaml
# @tests  d2-signalloom/apps/fleet-manager/agent_identity_binding_vap_test.go

bats_require_minimum_version 1.5.0

setup() {
	export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH"
	export GOPATH="/tmp/gopath"
	export GOCACHE="${GOCACHE:-/tmp/gocache}"
	export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
	export GONOSUMDB="*"
	mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"

	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	POLICIES="$REPO_ROOT/d2-osramp-fleet/tenants/base/policies.yaml"
	FM_KUST="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/kustomization.yaml"
	CONFIGMAP="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/configmap.yaml"
	OLD_BASE_FILE="$REPO_ROOT/d2-signalloom/apps/fleet-manager/base/agent-identity-binding.yaml"
}

# policy_field / binding_field query a field off the single matching
# spec.resources[] entry, selected by kind AND metadata.name together (not
# metadata.name alone) so a future same-named resource of a different kind
# cannot be matched by accident.
policy_field() {
	yq -N '.spec.resources[] | select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "sl-agent-identity-binding") | '"$1" "$POLICIES"
}

binding_field() {
	yq -N '.spec.resources[] | select(.kind == "ValidatingAdmissionPolicyBinding" and .metadata.name == "sl-agent-identity-binding-binding") | '"$1" "$POLICIES"
}

@test "policies.yaml is a cluster-level ResourceSet reconciled by flux-system, not a tenant Kustomization" {
	run yq -N '.kind' "$POLICIES"
	[ "$status" -eq 0 ]
	[ "$output" = "ResourceSet" ]

	run yq -N '.metadata.namespace' "$POLICIES"
	[ "$status" -eq 0 ]
	[ "$output" = "flux-system" ]
}

@test "the ResourceSet's spec.resources declares exactly the policy and its binding" {
	run policy_field '.metadata.name'
	[ "$status" -eq 0 ]
	[ "$output" = "sl-agent-identity-binding" ]

	run binding_field '.metadata.name'
	[ "$status" -eq 0 ]
	[ "$output" = "sl-agent-identity-binding-binding" ]
}

@test "the old fleet-manager/base copy is gone: one source of truth" {
	[ ! -e "$OLD_BASE_FILE" ]

	run yq -N '.resources[]' "$FM_KUST"
	[ "$status" -eq 0 ]
	! printf '%s\n' "${lines[@]}" | grep -qx "agent-identity-binding.yaml"
}

@test "the binding's paramRef names the fleet-config ConfigMap that carries the identity map, and fails closed" {
	run binding_field '.spec.paramRef.name'
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-config" ]

	run binding_field '.spec.paramRef.namespace'
	[ "$status" -eq 0 ]
	[ "$output" = "fe-signalloom" ]

	# A missing fleet-config ConfigMap must deny, not silently admit every
	# spoof -- enforced by the API server before this policy's CEL ever
	# runs, so this is the one guarantee no CEL expression could provide on
	# its own.
	run binding_field '.spec.paramRef.parameterNotFoundAction'
	[ "$status" -eq 0 ]
	[ "$output" = "Deny" ]

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

@test "the binding denies and is NOT restricted to a single namespace" {
	run binding_field '.spec.validationActions[0]'
	[ "$status" -eq 0 ]
	[ "$output" = "Deny" ]

	# The spoof this policy guards against is cross-namespace (a decoy in
	# hosted-daytona-coder's own namespace naming a registered agent's
	# ServiceAccount), so matchResources must carry no namespaceSelector --
	# restricting to fe-signalloom-agents would let that exact spoof through
	# in any other namespace.
	run binding_field '.spec.matchResources.namespaceSelector'
	[ "$status" -eq 0 ]
	[ "$output" = "null" ]
}

@test "the policy gates evaluation on matchConditions, not on namespace" {
	# Cluster-wide matchResources with no matchConditions would run this
	# policy's CEL on every pod create/update in the cluster. matchConditions
	# must filter on the agent-name label so an ordinary unlabelled workload,
	# anywhere, is never evaluated.
	run policy_field '.spec.matchConditions[0].expression'
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom.ai/agent-name"* ]]
}

@test "the policy's own CEL rejects a pod spoofing a registered agent's identity label" {
	run env CGO_ENABLED=0 GOPATH="$GOPATH" GOCACHE="$GOCACHE" GOMODCACHE="$GOMODCACHE" GONOSUMDB="*" \
		go test -C "$REPO_ROOT/d2-signalloom/apps/fleet-manager" \
		-count=1 -run '^TestIdentityBindingVAP_' .
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ok"
}
