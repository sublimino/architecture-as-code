#!/usr/bin/env bats
#
# Asserts that the Sovereign Kind deployment target in
# d2-signalloom/apps/docs-signalloom/dev-docs/src/content/docs/reference/architecture-diagrams.md
# covers required architectural concepts and contains zero prohibited terms.

setup() {
	repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	cd "$repo_root"
	doc="d2-signalloom/apps/docs-signalloom/dev-docs/src/content/docs/reference/architecture-diagrams.md"
}

check_prohibited_terms() {
	local file="$1"
	local prohibited=(
		"kagent"
		"purl listener"
		"witness processor"
		"osramp archiver"
		"osramp apps"
		"olly sentinel sre"
		"o11y sentinel sre"
	)
	local term
	for term in "${prohibited[@]}"; do
		if grep -qi -- "$term" "$file"; then
			echo "Found prohibited term: $term" >&2
			return 1
		fi
	done
	return 0
}

assert_sovereign_ingress() {
	local target="$1"
	grep -Ei "zero outbound (wan )?egress" "$target" && \
	grep -Ei "data sovereignty" "$target" && \
	grep -Ei "local control plane" "$target" && \
	grep -Ei "sovereign ingress" "$target" && \
	grep -Ei "unidirectional" "$target" && \
	grep -Ei "(external audit|audit sources)" "$target" && \
	grep -i "CloudTrail" "$target" && \
	grep -Ei "GCP Audit|gcpaudit" "$target" && \
	grep -Ei "K8s Audit|Kubernetes audit" "$target"
}

assert_inbound_receivers() {
	local target="$1"
	grep -i "signal-ingest" "$target" && \
	grep -i "OTLP" "$target" && \
	grep -i "Syslog" "$target" && \
	grep -Ei "Audit Webhook|webhook" "$target" && \
	grep -Ei "normalise|normalization" "$target"
}

assert_core_governance() {
	local target="$1"
	grep -i "Envoy Gateway" "$target" && \
	grep -i "cert-manager" "$target" && \
	grep -i "api-signalloom" "$target" && \
	grep -i "fe-signalloom" "$target" && \
	grep -i "Dashboard" "$target" && \
	grep -i "SPA" "$target" && \
	grep -i "Fleet Manager" "$target" && \
	grep -i "Policy Engine" "$target" && \
	grep -i "CEL" "$target" && \
	grep -i "governance bundles" "$target"
}

assert_landlock_workloads() {
	local target="$1"
	grep -i "fe-signalloom-agents" "$target" && \
	grep -i "Landlock LSM" "$target" && \
	grep -F "#nono" "$target" && \
	grep -i "warden" "$target" && \
	grep -i "eBPF" "$target" && \
	grep -Ei "cgroups? freeze" "$target" && \
	grep -Ei "tc stun" "$target" && \
	grep -i "SPIRE" "$target" && \
	grep -i "SVID" "$target" && \
	grep -i "mTLS" "$target"
}

assert_dual_storage() {
	local target="$1"
	grep -i "PostgreSQL" "$target" && \
	grep -i "audit_events" "$target" && \
	grep -i "tenant policies" "$target" && \
	grep -i "session state" "$target" && \
	grep -i "FrostDB" "$target" && \
	grep -i "columnar store" "$target" && \
	grep -Ei "time-series|timeseries" "$target"
}

assert_cert_manager_pki() {
	local target="$1"
	grep -i "cert-manager" "$target" && \
	grep -i "self-signed" "$target" && \
	grep -Ei "cluster issuer|ClusterIssuer" "$target" && \
	grep -Ei "TLS certificates" "$target"
}

@test "architecture-diagrams.md documents sovereign ingress and zero outbound WAN egress" {
	[ -f "$doc" ]
	run assert_sovereign_ingress "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents inbound receiver protocols" {
	[ -f "$doc" ]
	run assert_inbound_receivers "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents core governance platform and policy engine" {
	[ -f "$doc" ]
	run assert_core_governance "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents governed agent workloads under Landlock LSM" {
	[ -f "$doc" ]
	run assert_landlock_workloads "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents dual storage tiering" {
	[ -f "$doc" ]
	run assert_dual_storage "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents cert-manager PKI foundation" {
	[ -f "$doc" ]
	run assert_cert_manager_pki "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md contains zero prohibited terms" {
	[ -f "$doc" ]
	run check_prohibited_terms "$doc"
	[ "$status" -eq 0 ]
}

@test "self-test: prohibited term check fails on a planted prohibited term" {
	local planted="$BATS_TEST_TMPDIR/planted.md"
	cp "$doc" "$planted"
	echo "Planted defect: kagent is here" >>"$planted"
	run check_prohibited_terms "$planted"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Found prohibited term: kagent"* ]]
}

@test "self-test: required section check fails when egress concept is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped.md"
	sed 's/[Zz]ero outbound [Ww][Aa][Nn] egress/cloud egress enabled/g; s/[Dd]ata sovereignty/shared responsibility/g' "$doc" >"$stripped"
	run assert_sovereign_ingress "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when Landlock or nono is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_landlock.md"
	sed 's/Landlock LSM/unrestricted container/g; s/#nono//g' "$doc" >"$stripped"
	run assert_landlock_workloads "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when storage tiering is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_storage.md"
	sed 's/PostgreSQL/sqlite/g; s/FrostDB/in-memory/g' "$doc" >"$stripped"
	run assert_dual_storage "$stripped"
	[ "$status" -ne 0 ]
}
