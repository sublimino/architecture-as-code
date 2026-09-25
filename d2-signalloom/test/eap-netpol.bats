#!/usr/bin/env bats
# ==============================================================================
# d2-signalloom/test/eap-netpol.bats
# Static verification suite for EAP tenant workload identity, CSI volume projection,
# PSS restricted labels, and inf-bao NetworkPolicy connectivity rules.
# ==============================================================================

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	d2="$repo_root/d2-signalloom"
	src="$d2/apps/fe-signalloom/src"
}

render_py() {
	local py_code="$1"
	(
		cd "$src" && \
		UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache \
		uv run --python 3.12 --with-requirements requirements.txt \
		python -c "$py_code"
	)
}

@test "1. CSIDriver manifest declares Ephemeral mode and DaemonSet namespace is inf-bao" {
	local csidriver="$d2/deploy/spiffe-csi/csidriver.yaml"
	local daemonset="$d2/deploy/spiffe-csi/daemonset.yaml"

	[ -f "$csidriver" ]
	[ -f "$daemonset" ]

	# CSIDriver declares Ephemeral mode
	run grep -E -- '-[[:space:]]*Ephemeral' "$csidriver"
	[ "$status" -eq 0 ]

	# CSIDriver has podInfoOnMount: true and attachRequired: false
	run grep -E 'podInfoOnMount:[[:space:]]*true' "$csidriver"
	[ "$status" -eq 0 ]
	run grep -E 'attachRequired:[[:space:]]*false' "$csidriver"
	[ "$status" -eq 0 ]

	# DaemonSet is deployed in namespace inf-bao
	run grep -E 'namespace:[[:space:]]*inf-bao' "$daemonset"
	[ "$status" -eq 0 ]

	# DaemonSet mounts SPIRE agent sockets
	run grep -E 'path:[[:space:]]*/run/spire/sockets' "$daemonset"
	[ "$status" -eq 0 ]
}

@test "2. Rendered tenant pod spec has exactly one csi volume and zero hostPath volumes" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; print(json.dumps(t.generate_tenant_pod_manifest("6f82ad81")))')"

	# Exactly one volume with driver csi.spiffe.io
	local vol_count
	vol_count="$(echo "$json" | jq '.spec.volumes | length')"
	[ "$vol_count" -eq 1 ]

	local csi_driver
	csi_driver="$(echo "$json" | jq -r '.spec.volumes[0].csi.driver')"
	[ "$csi_driver" = "csi.spiffe.io" ]

	local csi_ro
	csi_ro="$(echo "$json" | jq -r '.spec.volumes[0].csi.readOnly')"
	[ "$csi_ro" = "true" ]

	# Zero hostPath volumes
	local hostpath_count
	hostpath_count="$(echo "$json" | jq '[.spec.volumes[] | select(.hostPath != null)] | length')"
	[ "$hostpath_count" -eq 0 ]

	# SPIFFE_ENDPOINT_SOCKET env var is projected
	local sock_env
	sock_env="$(echo "$json" | jq -r '.spec.containers[0].env[] | select(.name == "SPIFFE_ENDPOINT_SOCKET") | .value')"
	[ "$sock_env" = "unix:///spiffe-workload-api/spire-agent.sock" ]

	# Volume mount is readOnly at /spiffe-workload-api
	local mount_path
	mount_path="$(echo "$json" | jq -r '.spec.containers[0].volumeMounts[] | select(.name == "spiffe-workload-api") | .mountPath')"
	[ "$mount_path" = "/spiffe-workload-api" ]
}

@test "2b. Mutation: pod spec with injected hostPath fails zero-hostPath check" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; pod = t.generate_tenant_pod_manifest("6f82ad81"); pod["spec"]["volumes"].append({"name": "bad-hostpath", "hostPath": {"path": "/run/spire"}}); print(json.dumps(pod))')"

	# Injected hostPath must be detected
	local hostpath_count
	hostpath_count="$(echo "$json" | jq '[.spec.volumes[] | select(.hostPath != null)] | length')"
	[ "$hostpath_count" -gt 0 ]
}

@test "3. Tenant namespace manifest carries enforce, warn, and audit all equal to restricted" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; print(json.dumps(t.generate_namespace_manifest("kurasi", "6f82ad81")))')"

	local enforce
	enforce="$(echo "$json" | jq -r '.metadata.labels["pod-security.kubernetes.io/enforce"]')"
	[ "$enforce" = "restricted" ]

	local warn
	warn="$(echo "$json" | jq -r '.metadata.labels["pod-security.kubernetes.io/warn"]')"
	[ "$warn" = "restricted" ]

	local audit
	audit="$(echo "$json" | jq -r '.metadata.labels["pod-security.kubernetes.io/audit"]')"
	[ "$audit" = "restricted" ]

	local version
	version="$(echo "$json" | jq -r '.metadata.labels["pod-security.kubernetes.io/enforce-version"]')"
	[ "$version" = "latest" ]
}

@test "4. Every egress rule targets inf-bao or kube-system and no rule names inf-spire" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; print(json.dumps(t.generate_network_policy_manifest("6f82ad81")))')"

	# Check no rule targets inf-spire
	run grep -q "inf-spire" <<< "$json"
	[ "$status" -ne 0 ]

	# Collect all target namespaces
	local target_namespaces
	target_namespaces="$(echo "$json" | jq -r '.spec.egress[].to[]?.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' | sort -u)"

	while IFS= read -r ns; do
		if [ -n "$ns" ]; then
			[[ "$ns" == "inf-bao" || "$ns" == "kube-system" ]]
		fi
	done <<< "$target_namespaces"
}

@test "4b. Egress port list equals named constants OPENBAO_PORT and SPIRE_SERVER_PORT" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; print(json.dumps(t.generate_network_policy_manifest("6f82ad81")))')"

	local inf_bao_ports
	inf_bao_ports="$(echo "$json" | jq -r '.spec.egress[] | select(.to[]?.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "inf-bao") | .ports[].port' | sort -n)"

	# inf-bao egress ports must be 8081 (SPIRE_SERVER_PORT) and 8200 (OPENBAO_PORT)
	echo "$inf_bao_ports" | grep -q "8081"
	echo "$inf_bao_ports" | grep -q "8200"

	local count
	count="$(echo "$inf_bao_ports" | wc -l)"
	[ "$count" -eq 2 ]
}

@test "5. OpenBao ingress policy in inf-bao selects tenant namespace on OPENBAO_PORT" {
	local json
	json="$(render_py 'import json, tenant_isolation as t; print(json.dumps(t.generate_openbao_ingress_policy("6f82ad81")))')"

	local ns
	ns="$(echo "$json" | jq -r '.metadata.namespace')"
	[ "$ns" = "inf-bao" ]

	local pod_sel
	pod_sel="$(echo "$json" | jq -r '.spec.podSelector.matchLabels["app.kubernetes.io/name"]')"
	[ "$pod_sel" = "openbao" ]

	local from_ns
	from_ns="$(echo "$json" | jq -r '.spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]')"
	[ "$from_ns" = "eap-6f82ad81" ]

	local port
	port="$(echo "$json" | jq -r '.spec.ingress[0].ports[0].port')"
	[ "$port" -eq 8200 ]
}
