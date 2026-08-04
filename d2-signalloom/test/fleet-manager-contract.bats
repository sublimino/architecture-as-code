#!/usr/bin/env bats
#
# Static contract tests for the fleet-manager service.
# No cluster required — validates YAML manifests only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	base="$repo_root/d2-signalloom/apps/fleet-manager/base"

	command -v yq >/dev/null || skip "yq is required"
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

# --- Role ---

@test "Role grants exactly get, list, patch on pods" {
	run yq 'select(.kind == "Role") | .rules[0].verbs | sort | join(",")' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "get,list,patch" ]
}

@test "Role targets pods resource only" {
	run yq 'select(.kind == "Role") | .rules[0].resources[0]' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "pods" ]
}

@test "Role has no wildcard resources" {
	local resources
	resources="$(yq 'select(.kind == "Role") | .rules[0].resources[]' "$base/rbac.yaml")"
	local wildcards
	wildcards="$(printf '%s\n' "$resources" | grep -Fx '*' || true)"
	[ -z "$wildcards" ]
}

@test "Role has no wildcard verbs" {
	local verbs
	verbs="$(yq 'select(.kind == "Role") | .rules[0].verbs[]' "$base/rbac.yaml")"
	local wildcards
	wildcards="$(printf '%s\n' "$verbs" | grep -Fx '*' || true)"
	[ -z "$wildcards" ]
}

@test "Role is namespace-scoped to fe-signalloom-agents" {
	run yq 'select(.kind == "Role") | .metadata.namespace' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fe-signalloom-agents" ]
}

# --- RoleBinding ---

@test "RoleBinding references the correct Role" {
	run yq 'select(.kind == "RoleBinding") | .roleRef.name' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager-pod-reader" ]
}

@test "RoleBinding subject is the fleet-manager SA" {
	run yq 'select(.kind == "RoleBinding") | .subjects[0].name' "$base/rbac.yaml"
	[ "$status" -eq 0 ]
	[ "$output" = "fleet-manager" ]
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
