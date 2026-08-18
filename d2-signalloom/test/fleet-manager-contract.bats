#!/usr/bin/env bats
#
# Static contract tests for the fleet-manager service.
# No cluster required — validates YAML manifests only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	base="$repo_root/d2-signalloom/apps/fleet-manager/base"
	# The cross-namespace RBAC lives here, not in base/ — see the Role section.
	resourceset="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"

	command -v yq >/dev/null || skip "yq is required"
	[ -f "$resourceset" ] || skip "signalloom ResourceSet not found at $resourceset"
}

# --- Deployment ---

@test "deployment exists" {
	[ -f "$base/deployment.yaml" ]
}

@test "deployment uses dedicated ServiceAccount" {
	run yq '.spec.template.spec.serviceAccountName' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager" ]
}

@test "deployment mounts fleet-config ConfigMap" {
	run yq '.spec.template.spec.volumes[0].configMap.name' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-config" ]
}

@test "deployment volume mount path is /etc/fleet" {
	run yq '.spec.template.spec.containers[0].volumeMounts[0].mountPath' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "/etc/fleet" ]
}

@test "deployment volume mount is read-only" {
	run yq '.spec.template.spec.containers[0].volumeMounts[0].readOnly' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "deployment runs as non-root" {
	run yq '.spec.template.spec.securityContext.runAsNonRoot' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "deployment has seccomp RuntimeDefault" {
	run yq '.spec.template.spec.securityContext.seccompProfile.type' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "RuntimeDefault" ]
}

@test "container drops ALL capabilities" {
	run yq '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "ALL" ]
}

@test "container has readOnlyRootFilesystem" {
	run yq '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "container disallows privilege escalation" {
	run yq '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$base/deployment.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "false" ]
}

# --- ServiceAccount ---

@test "ServiceAccount exists in rbac.yaml" {
	run yq 'select(.kind == "ServiceAccount") | .metadata.name' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager" ]
}

# --- Role / RoleBinding ---
#
# These moved OUT of base/rbac.yaml and into the signalloom-infra ResourceSet
# when this directory was put under Flux, and the tests had to move with them.
#
# They are not in the base for two reasons, either one sufficient: the
# signalloom-apps Kustomization carries `targetNamespace`, which would relocate
# a fe-signalloom-agents Role into the tenant namespace and leave fleet-manager
# with no grant where the agents run; and that Kustomization reconciles as the
# namespace-scoped `flux` SA, which lacks `escalate`, so a RoleBinding created
# from there fails the server dry-run's roleRef lookup and aborts the whole set.
#
# Two of these assertions used to pass VACUOUSLY after the move — "no wildcard
# resources" and "no wildcard verbs" both went green against an empty yq result,
# because a rule set that does not exist contains no wildcards. A least-
# privilege guard that passes hardest when the grant is missing entirely is
# worse than no guard, so each test below first asserts the object IS THERE.

# Emits the fleet-manager Role's rule set from the ResourceSet.
fleet_role_rules() {
	yq ea "select(.metadata.name == \"signalloom-infra\")
	       | .spec.resources[]
	       | select(.kind == \"Role\" and .metadata.name == \"fleet-manager-pod-reader\")
	       | .rules[0]" "$resourceset"
}

@test "the fleet-manager Role exists in the signalloom-infra ResourceSet" {
	# Asserted before anything reads it, so a Role that was deleted or renamed
	# reports as missing rather than as trivially compliant.
	run fleet_role_rules
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" != "null" ]]
}

@test "Role grants exactly get, list, patch on pods" {
	run bash -c "$(declare -f fleet_role_rules); resourceset='$resourceset'; fleet_role_rules | yq '.verbs | sort | join(\",\")'"
	[ "$status" -eq 0 ]
	[ "$output" = "get,list,patch" ]
}

@test "Role targets pods resource only" {
	run bash -c "$(declare -f fleet_role_rules); resourceset='$resourceset'; fleet_role_rules | yq '.resources | join(\",\")'"
	[ "$status" -eq 0 ]
	[ "$output" = "pods" ]
}

@test "Role has no wildcard resources" {
	local resources
	resources="$(fleet_role_rules | yq '.resources[]')"
	[ -n "$resources" ]
	local wildcards
	wildcards="$(printf '%s\n' "$resources" | grep -Fx '*' || true)"
	[ -z "$wildcards" ]
}

@test "Role has no wildcard verbs" {
	local verbs
	verbs="$(fleet_role_rules | yq '.verbs[]')"
	[ -n "$verbs" ]
	local wildcards
	wildcards="$(printf '%s\n' "$verbs" | grep -Fx '*' || true)"
	[ -z "$wildcards" ]
}

@test "Role is namespace-scoped to fe-signalloom-agents" {
	run yq ea "select(.metadata.name == \"signalloom-infra\")
	           | .spec.resources[]
	           | select(.kind == \"Role\" and .metadata.name == \"fleet-manager-pod-reader\")
	           | .metadata.namespace" "$resourceset"
	[ "$status" -eq 0 ]
	[ "$output" = "fe-signalloom-agents" ]
}

@test "Role is namespaced, never a ClusterRole" {
	# fleet-manager must not acquire a cluster-wide identity. A ClusterRole of
	# the same name would satisfy every verb assertion above.
	run yq ea "select(.metadata.name == \"signalloom-infra\")
	           | .spec.resources[]
	           | select(.kind == \"ClusterRole\" and (.metadata.name | test(\"fleet-manager\")))
	           | .metadata.name" "$resourceset"
	[ "$status" -eq 0 ]
	[ -z "$output" ] || [ "$output" = "null" ]
}

@test "RoleBinding references the correct Role" {
	run yq ea "select(.metadata.name == \"signalloom-infra\")
	           | .spec.resources[]
	           | select(.kind == \"RoleBinding\" and .metadata.name == \"fleet-manager-pod-reader\")
	           | .roleRef.name" "$resourceset"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager-pod-reader" ]
}

@test "RoleBinding subject is the fleet-manager SA in fe-signalloom" {
	# The namespace half is the point. A RoleBinding naming a ServiceAccount
	# that does not exist is LEGAL and SILENT: it binds nothing, every pod
	# list/patch 403s, and client-go surfaces a 403 as an EMPTY result. The
	# identical mistake against supercred-demo-runner bound
	# system:serviceaccount:inf-bao:supercred-demo-runner and cost a day.
	run yq ea "select(.metadata.name == \"signalloom-infra\")
	           | .spec.resources[]
	           | select(.kind == \"RoleBinding\" and .metadata.name == \"fleet-manager-pod-reader\")
	           | .subjects[0] | .name + \" \" + .namespace" "$resourceset"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager fe-signalloom" ]
}

@test "the base kustomization no longer ships the cross-namespace RBAC" {
	# Belt and braces against a well-meaning restore. Putting the Role back in
	# base/rbac.yaml reintroduces both failures at once and neither is visible:
	# Flux reports Ready either way.
	run yq ea 'select(.kind == "Role" or .kind == "RoleBinding") | .metadata.name' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ -z "$output" ] || [ "$output" = "null" ]
}

# --- ConfigMap ---

@test "ConfigMap fleet-config exists" {
	[ -f "$base/configmap.yaml" ]
	run yq '.metadata.name' "$base/configmap.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-config" ]
}

@test "ConfigMap contains fleet.yaml with agents" {
	run yq '.data["fleet.yaml"]' "$base/configmap.yaml"
	[ "$status" -eq 0 ]
	[[ "$output" == *"agent-cardvault"* ]]
	[[ "$output" == *"agent-monitor"* ]]
}

# --- NetworkPolicy ---

@test "NetworkPolicy exists" {
	[ -f "$base/networkpolicy.yaml" ]
}

@test "NetworkPolicy scopes ingress to signalloom pods" {
	run yq '.spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/part-of"]' "$base/networkpolicy.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "signalloom" ]
}
