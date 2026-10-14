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

assert_azure_architecture() {
	local target="$1"
	grep -i "Azure Front Door" "$target" && \
	grep -Ei "global routing" "$target" && \
	grep -i "Azure WAF" "$target" && \
	grep -i "Azure DNS" "$target" && \
	grep -Ei "Application Gateway|Application Gateways" "$target" && \
	grep -i "Dashboard" "$target" && \
	grep -i "FastAPI Core" "$target" && \
	grep -i "api-signalloom" "$target" && \
	grep -i "Fleet Manager" "$target" && \
	grep -i "AKS" "$target" && \
	grep -i "OpenBao" "$target" && \
	grep -i "Azure Key Vault" "$target" && \
	grep -i "HSM" "$target" && \
	grep -Ei "auto-unseal|unseal" "$target" && \
	grep -i "SPIRE" "$target" && \
	grep -i "mTLS" "$target" && \
	grep -Ei "mTLS mesh" "$target" && \
	grep -i "warden" "$target" && \
	grep -i "eBPF" "$target" && \
	grep -Ei "cgroups? freeze" "$target" && \
	grep -Ei "tc stun" "$target" && \
	grep -i "KubeSec AFM" "$target" && \
	grep -Ei "formal RBAC|RBAC analysis" "$target" && \
	grep -i "Azure Event Hubs" "$target" && \
	grep -i "Activity Logs" "$target" && \
	grep -Ei "Diagnostic (streams|logs)" "$target" && \
	grep -i "signal-ingest" "$target" && \
	grep -Ei "collectors?" "$target" && \
	grep -i "Azure OpenAI" "$target" && \
	grep -i "CPAI" "$target" && \
	grep -Ei "Azure Database for PostgreSQL Flexible Server|PostgreSQL Flexible Server" "$target" && \
	grep -i "audit trail" "$target" && \
	grep -i "tenant policies" "$target" && \
	grep -Ei "Azure Blob Storage" "$target" && \
	grep -Ei "Data Lake" "$target" && \
	grep -i "FrostDB" "$target"
}

assert_aws_architecture() {
	local target="$1"
	grep -i "CloudFront" "$target" && \
	grep -Ei "edge CDN" "$target" && \
	grep -i "AWS WAF" "$target" && \
	grep -i "Route 53" "$target" && \
	grep -Ei "Application Load Balancer|Application Load Balancers" "$target" && \
	grep -i "Dashboard" "$target" && \
	grep -i "FastAPI Core" "$target" && \
	grep -i "Fleet Manager" "$target" && \
	grep -i "EKS" "$target" && \
	grep -i "Bottlerocket" "$target" && \
	grep -i "Nitro Enclaves" "$target" && \
	grep -i "OpenBao" "$target" && \
	grep -i "AWS KMS" "$target" && \
	grep -i "CMK" "$target" && \
	grep -Ei "auto-unseal|unseal" "$target" && \
	grep -i "SPIRE" "$target" && \
	grep -i "mTLS" "$target" && \
	grep -Ei "mTLS mesh" "$target" && \
	grep -i "warden" "$target" && \
	grep -i "eBPF" "$target" && \
	grep -Ei "cgroups? freeze" "$target" && \
	grep -Ei "tc stun" "$target" && \
	grep -i "KubeSec AFM" "$target" && \
	grep -Ei "formal RBAC|RBAC analysis" "$target" && \
	grep -i "Amazon SQS" "$target" && \
	grep -i "CloudTrail" "$target" && \
	grep -i "GuardDuty" "$target" && \
	grep -i "EventBridge" "$target" && \
	grep -i "signal-ingest" "$target" && \
	grep -i "Amazon Bedrock" "$target" && \
	grep -i "CPAI" "$target" && \
	grep -i "Amazon Aurora PostgreSQL" "$target" && \
	grep -i "audit events" "$target" && \
	grep -i "tenant state" "$target" && \
	grep -i "Amazon S3" "$target" && \
	grep -i "Glacier Vault" "$target" && \
	grep -Ei "WORM evidence|WORM" "$target" && \
	grep -i "FrostDB" "$target"
}

assert_gcp_architecture() {
	local target="$1"
	grep -i "Cloud CDN" "$target" && \
	grep -i "Cloud Armor" "$target" && \
	grep -i "Cloud DNS" "$target" && \
	grep -Ei "Global External HTTPS Load Balancer|Global External HTTPS Load Balancers" "$target" && \
	grep -Ei "per region|across regional" "$target" && \
	grep -i "Dashboard" "$target" && \
	grep -i "FastAPI Core" "$target" && \
	grep -i "Fleet Manager" "$target" && \
	grep -i "GKE" "$target" && \
	grep -i "Container-Optimized OS" "$target" && \
	grep -i "gVisor" "$target" && \
	grep -i "OpenBao" "$target" && \
	grep -i "Cloud KMS" "$target" && \
	grep -Ei "auto-unseal|unseal" "$target" && \
	grep -i "SPIRE" "$target" && \
	grep -i "mTLS" "$target" && \
	grep -Ei "mTLS mesh" "$target" && \
	grep -i "warden" "$target" && \
	grep -i "eBPF" "$target" && \
	grep -Ei "cgroups? freeze" "$target" && \
	grep -Ei "tc stun" "$target" && \
	grep -i "KubeSec AFM" "$target" && \
	grep -Ei "formal RBAC|RBAC analysis" "$target" && \
	grep -i "Cloud Pub/Sub" "$target" && \
	grep -i "Cloud Audit Logs" "$target" && \
	grep -i "Security Command Center" "$target" && \
	grep -i "signal-ingest" "$target" && \
	grep -i "Vertex AI" "$target" && \
	grep -i "CPAI" "$target" && \
	grep -i "Cloud SQL for PostgreSQL" "$target" && \
	grep -i "audit events" "$target" && \
	grep -Ei "Cloud Storage Dual-Region|Dual-Region bucket" "$target" && \
	grep -i "FrostDB" "$target"
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

@test "architecture-diagrams.md documents Microsoft Azure AKS roadmap architecture" {
	[ -f "$doc" ]
	run assert_azure_architecture "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents Amazon Web Services EKS roadmap architecture" {
	[ -f "$doc" ]
	run assert_aws_architecture "$doc"
	[ "$status" -eq 0 ]
}

@test "architecture-diagrams.md documents Google Cloud Platform GKE roadmap architecture" {
	[ -f "$doc" ]
	run assert_gcp_architecture "$doc"
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

@test "self-test: required section check fails when Azure roadmap is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_azure.md"
	sed 's/Azure Front Door/Front Door/g; s/OpenBao/Consul/g' "$doc" >"$stripped"
	run assert_azure_architecture "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when AWS roadmap is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_aws.md"
	sed 's/Bottlerocket/Amazon Linux/g; s/Bedrock/Anthropic/g' "$doc" >"$stripped"
	run assert_aws_architecture "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when GCP roadmap is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_gcp.md"
	sed 's/Cloud Armor/WAF/g; s/gVisor/runc/g' "$doc" >"$stripped"
	run assert_gcp_architecture "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when Azure mTLS mesh or Key Vault HSM is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_azure_mesh.md"
	sed 's/mTLS mesh/plain network/g; s/HSM/software/g' "$doc" >"$stripped"
	run assert_azure_architecture "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when AWS edge CDN or SQS is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_aws_cdn.md"
	sed 's/edge CDN/origin server/g; s/Amazon SQS/Kafka/g' "$doc" >"$stripped"
	run assert_aws_architecture "$stripped"
	[ "$status" -ne 0 ]
}

@test "self-test: required section check fails when GCP gVisor or Pub/Sub is missing" {
	local stripped="$BATS_TEST_TMPDIR/stripped_gcp_gvisor.md"
	sed 's/gVisor/containerd/g; s/Cloud Pub\/Sub/RabbitMQ/g' "$doc" >"$stripped"
	run assert_gcp_architecture "$stripped"
	[ "$status" -ne 0 ]
}
