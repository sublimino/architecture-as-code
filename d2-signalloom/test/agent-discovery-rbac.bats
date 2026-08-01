#!/usr/bin/env bats
#
# Keeps the proxy's agent-discovery namespace list and its RBAC grants in step.
#
# The failure this prevents: adding a namespace to AGENT_DISCOVERY_NAMESPACES
# without adding the matching Role/RoleBinding. The proxy degrades gracefully on
# a 403 — it logs, keeps the namespaces that do work, and records the failure in
# `namespace_errors` — so the only visible symptom is /agents returning fewer
# agents than the cluster holds. That is the same silent-shortfall shape as a
# `kind load` that exits 0 having transferred nothing.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	# Single canonical Signal Loom tenant ResourceSet, owned by the fleet.
	canonical="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
	server="$repo_root/d2-signalloom/apps/fake-integration-proxy/server.py"
	proxy_sa_namespace="inf-signalloom"
	proxy_sa_name="default"

	command -v yq >/dev/null || skip "yq is required to inspect the ResourceSet"
}

# The namespaces the proxy will actually query.
discovery_namespaces() {
	python3 - "$server" <<-'PY'
		import re, sys
		src = open(sys.argv[1]).read()
		block = re.search(r"DEFAULT_AGENT_DISCOVERY_NAMESPACES\s*=\s*\(([^)]*)\)", src)
		assert block, "DEFAULT_AGENT_DISCOVERY_NAMESPACES not found in server.py"
		print("\n".join(re.findall(r'"([^"]+)"', block.group(1))))
	PY
}

# The value `<< inputs.tenant >>` expands to for the local tenant.
tenant_namespace() {
	python3 - "$repo_root/scripts/signalloom-up.sh" <<-'PY'
		import json, re, sys
		src = open(sys.argv[1]).read()
		raw = re.search(r"DEFAULT_INPUTS='(.*)'", src)
		assert raw, "DEFAULT_INPUTS not found in signalloom-up.sh"
		print(json.loads(raw.group(1))[0]["tenant"])
	PY
}

# ResourceSet templates are authored with the placeholder, not the tenant value.
as_authored() {
	if [ "$1" = "$(tenant_namespace)" ]; then
		printf '<< inputs.tenant >>'
	else
		printf '%s' "$1"
	fi
}

# Roles bound to the proxy's ServiceAccount in a namespace, one per line.
bound_roles() {
	yq eval-all "
		[ .spec.resources[]?
		  | select(.kind == \"RoleBinding\" and .metadata.namespace == \"$1\")
		  | select([.subjects[]? | select(.kind == \"ServiceAccount\"
		      and .name == \"$proxy_sa_name\"
		      and .namespace == \"$proxy_sa_namespace\")] | length > 0)
		  | .roleRef.name ] | .[]" "$canonical"
}

# Count of Roles in a namespace that grant list on pods.
pod_reader_count() {
	yq eval-all "
		[ .spec.resources[]?
		  | select(.kind == \"Role\" and .metadata.namespace == \"$1\" and .metadata.name == \"$2\")
		  | select([.rules[]? | select((.resources[]? == \"pods\")
		      and (.verbs[]? == \"list\"))] | length > 0) ] | length" "$canonical" \
		| awk '{total += $1} END {print total + 0}'
}

@test "the proxy declares at least the two demo namespaces" {
	run discovery_namespaces
	[ "$status" -eq 0 ]
	[[ "$output" == *"fe-signalloom-agents"* ]]
	[[ "$output" == *"fe-signalloom"* ]]
}

@test "every discovery namespace grants the proxy SA a pod-reading Role" {
	local ns authored role found
	while read -r ns; do
		[ -n "$ns" ] || continue
		authored="$(as_authored "$ns")"

		found=0
		while read -r role; do
			[ -n "$role" ] || continue
			if [ "$(pod_reader_count "$authored" "$role")" -gt 0 ]; then
				found=1
			fi
		done < <(bound_roles "$authored")

		[ "$found" -eq 1 ] || {
			echo "no Role granting pods/list is bound to" \
				"$proxy_sa_name.$proxy_sa_namespace in '$authored'"
			echo "(discovery namespace '$ns' — add the grant to $canonical)"
			return 1
		}
	done < <(discovery_namespaces)
}

@test "a discovery namespace with no grant is reported, not tolerated" {
	# Guards the guard: the check above must actually fail for an ungranted namespace.
	local found=0 role
	while read -r role; do
		[ -n "$role" ] || continue
		if [ "$(pod_reader_count "kube-system" "$role")" -gt 0 ]; then
			found=1
		fi
	done < <(bound_roles "kube-system")
	[ "$found" -eq 0 ]
}

@test "the tenant grant stays namespace-scoped and read-only" {
	local authored
	authored="$(as_authored "$(tenant_namespace)")"

	# No cluster-scoped identity for this tenant's pod reader.
	run bash -c "yq eval-all '
		[ .spec.resources[]?
		  | select(.kind == \"ClusterRoleBinding\")
		  | select([.subjects[]? | select(.name == \"$proxy_sa_name\"
		      and .namespace == \"$proxy_sa_namespace\")] | length > 0) ] | length' '$canonical' \
		| awk '{t += \$1} END {print t + 0}'"
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ]

	# The Role grants pods only, and no mutating verb.
	run yq eval-all "
		[ .spec.resources[]?
		  | select(.kind == \"Role\" and .metadata.namespace == \"$authored\"
		      and .metadata.name == \"agent-inventory-reader\")
		  | .rules[]? | .resources[]? ] | .[]" "$canonical"
	[ "$status" -eq 0 ]
	[[ "$output" == *"pods"* ]]
	[[ "$output" != *"secrets"* ]]

	run yq eval-all "
		[ .spec.resources[]?
		  | select(.kind == \"Role\" and .metadata.namespace == \"$authored\"
		      and .metadata.name == \"agent-inventory-reader\")
		  | .rules[]? | .verbs[]? ] | .[]" "$canonical"
	[ "$status" -eq 0 ]
	[[ "$output" != *"create"* ]]
	[[ "$output" != *"delete"* ]]
	[[ "$output" != *"patch"* ]]
	[[ "$output" != *"*"* ]]
}

@test "the RoleBinding ships alongside the Role it references" {
	# A roleRef naming a non-existent Role is accepted by the API server and
	# silently grants nothing, so the pair must live in the same ResourceSet.
	local authored role
	authored="$(as_authored "$(tenant_namespace)")"
	while read -r role; do
		[ -n "$role" ] || continue
		run yq eval-all "
			[ .spec.resources[]?
			  | select(.kind == \"Role\" and .metadata.namespace == \"$authored\"
			      and .metadata.name == \"$role\") ] | length" "$canonical"
		[ "$status" -eq 0 ]
		[[ "$output" == *"1"* ]]
	done < <(bound_roles "$authored")
}
