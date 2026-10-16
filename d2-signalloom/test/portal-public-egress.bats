#!/usr/bin/env bats
#
# Pins the exact shape of security exemption SA-TODO-001: the portal pod
# (Deployment fe-signalloom, container discovery-portal) may open TCP 443 to
# PUBLIC addresses so that the live AI provider connectors (Anthropic, OpenAI)
# can reach their APIs.
#
# The exemption is a principal decision of 2026-10-16, recorded with its exit
# criterion in docs/signalloom/security-architecture-todos.md. It is temporary.
# The intended replacement is an L7 egress proxy, a service mesh egress
# gateway, or an eBPF/Cilium FQDN policy.
#
# A temporary grant that nothing pins grows. Each test below fails on one way
# the grant could widen without anyone arguing for it:
#
#   - the selector widens past the portal pod (the bao-spire proof Jobs carry
#     the same bao.controlplane.io/consumer label, so that label alone is
#     already too wide)
#   - the port list widens past TCP 443
#   - an except entry is dropped, so 0.0.0.0/0 starts to include cluster or
#     private addresses
#   - a second policy grants public egress to some other workload
#   - the manifest and the register disagree on the exemption id
#
# Offline: renders the local overlay with kubectl kustomize. No cluster.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	overlay="${PORTAL_EGRESS_OVERLAY:-$repo_root/d2-signalloom/apps/fe-signalloom/local}"
	register="${PORTAL_EGRESS_REGISTER:-$repo_root/docs/signalloom/security-architecture-todos.md}"
	base_policy="$repo_root/d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml"
	exemption="allow-portal-public-https-egress"
	command -v kubectl >/dev/null || skip "kubectl is required to render the overlay"
	command -v jq >/dev/null || skip "jq is required"
	command -v yq >/dev/null || skip "yq is required"
}

render_json() {
	kubectl kustomize "$overlay" | yq -o=json -I=0 'select(. != null)' | jq -s '.'
}

exemption_json() {
	render_json | jq --arg n "$exemption" '[ .[] | select(.kind == "NetworkPolicy" and .metadata.name == $n) ]'
}

# Every range that 0.0.0.0/0 must exclude. RFC 1918, CGNAT (also the Tailscale
# range), link-local (cloud metadata at 169.254.169.254), loopback, and the
# kind pod and service CIDRs. The last two sit inside 10.0.0.0/8 already. They
# are listed on their own so that a later edit which narrows 10.0.0.0/8 cannot
# silently re-open the cluster ranges.
REQUIRED_EXCEPT='["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","169.254.0.0/16","127.0.0.0/8","10.244.0.0/16","10.96.0.0/12"]'

@test "exactly one exemption policy renders, egress only" {
	run exemption_json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'length == 1'
	echo "$output" | jq -e '.[0].spec.policyTypes == ["Egress"]'
	echo "$output" | jq -e '(.[0].spec.ingress // []) | length == 0'
}

@test "the exemption selects the portal Deployment and no other workload" {
	run render_json
	[ "$status" -eq 0 ]

	# The selector is an exact pair. A matchExpressions entry or a dropped
	# label would change which pods it selects.
	echo "$output" | jq -e --arg n "$exemption" '
		.[] | select(.kind == "NetworkPolicy" and .metadata.name == $n)
		| .spec.podSelector == {"matchLabels": {
			"app.kubernetes.io/name": "fe-signalloom",
			"bao.controlplane.io/consumer": "fe-signalloom"}}'

	# Evaluate the selector against every pod template that the overlay
	# renders, Jobs included. The bao-spire proof Jobs share the consumer
	# label, so this is the check that catches a selector of that label alone.
	selected="$(echo "$output" | jq -r --arg n "$exemption" '
		def pod_labels:
			if .kind == "Pod" then (.metadata.labels // {})
			elif .kind == "CronJob" then (.spec.jobTemplate.spec.template.metadata.labels // {})
			else (.spec.template.metadata.labels // {}) end;
		([ .[] | select(.kind == "NetworkPolicy" and .metadata.name == $n) ][0].spec.podSelector) as $sel
		| ($sel.matchLabels // {}) as $ml
		| [ .[]
			| select(.kind | IN("Deployment","StatefulSet","DaemonSet","Job","CronJob","Pod","ReplicaSet"))
			| pod_labels as $l
			| select(($sel.matchExpressions // []) | length == 0)
			| select(($ml | length) == 0 or all($ml | to_entries[]; $l[.key] == .value))
			| "\(.kind)/\(.metadata.name)" ]
		| .[]')"
	echo "selected: $selected" >&2
	[ "$selected" = "Deployment/fe-signalloom" ]
}

@test "the exemption grants TCP 443 only" {
	run exemption_json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.[0].spec.egress | length == 1'
	echo "$output" | jq -e '.[0].spec.egress[0].ports == [{"protocol": "TCP", "port": 443}]'
}

@test "the exemption peer is one ipBlock 0.0.0.0/0 and nothing in-cluster" {
	run exemption_json
	[ "$status" -eq 0 ]
	# One peer, an ipBlock. A namespaceSelector or podSelector peer here would
	# add an in-cluster path under the cover of the exemption.
	echo "$output" | jq -e '.[0].spec.egress[0].to | length == 1'
	echo "$output" | jq -e '.[0].spec.egress[0].to[0] | keys == ["ipBlock"]'
	echo "$output" | jq -e '.[0].spec.egress[0].to[0].ipBlock.cidr == "0.0.0.0/0"'
}

@test "the exemption excludes every private, cluster, and metadata range" {
	run exemption_json
	[ "$status" -eq 0 ]
	missing="$(echo "$output" | jq -r --argjson req "$REQUIRED_EXCEPT" '
		(.[0].spec.egress[0].to[0].ipBlock.except // []) as $have
		| $req - $have | .[]')"
	if [ -n "$missing" ]; then
		echo "except list is missing: $missing" >&2
		false
	fi
}

@test "no other policy in fe-signalloom grants public egress" {
	run render_json
	[ "$status" -eq 0 ]

	# Every ipBlock outside the exemption must sit inside a private or cluster
	# range, with no except list (an except implies a wider parent block).
	# The containment test is done on the first octets, which is exact for the
	# four parent ranges used here.
	wide="$(echo "$output" | jq -r --arg n "$exemption" '
		def octets: split("/")[0] | split(".") | map(tonumber);
		def prefix: split("/")[1] | tonumber;
		def private:
			(octets) as $o | (prefix) as $p
			| ($o[0] == 10 and $p >= 8)
			  or ($o[0] == 172 and $o[1] >= 16 and $o[1] <= 31 and $p >= 12)
			  or ($o[0] == 192 and $o[1] == 168 and $p >= 16)
			  or ($o[0] == 100 and $o[1] >= 64 and $o[1] <= 127 and $p >= 10);
		.[] | select(.kind == "NetworkPolicy" and .metadata.name != $n)
		| .metadata.name as $pol
		| (.spec.egress // [])[] | (.to // [])[] | select(has("ipBlock")) | .ipBlock
		| select((.cidr | test(":")) or ((.cidr | private) | not) or ((.except // []) | length > 0))
		| "\($pol): \(.cidr)"')"
	if [ -n "$wide" ]; then
		echo "public ipBlock outside $exemption:" >&2
		echo "$wide" >&2
		false
	fi
}

@test "the set of policies with an unbounded egress rule does not grow" {
	run render_json
	[ "$status" -eq 0 ]

	# An egress rule with no `to` allows every destination on its ports.
	# Two policies already have one, on TCP 443 and 6443, to reach the
	# kube-apiserver: allow-netassert-runner-egress (the netassert-run Job) and
	# allow-supercred-demo-runner-egress. Both predate SA-TODO-001, so both
	# pods could already reach public 443. The register records them as
	# SA-TODO-002. This test stops a third one from appearing.
	unbounded="$(echo "$output" | jq -r '
		.[] | select(.kind == "NetworkPolicy")
		| select([ (.spec.egress // [])[] | select(has("to") | not) ] | length > 0)
		| .metadata.name' | sort | tr '\n' ' ')"
	echo "unbounded: $unbounded" >&2
	[ "$unbounded" = "allow-netassert-runner-egress allow-supercred-demo-runner-egress " ]
}

@test "the manifest annotations record the exemption, decision, and replacement" {
	run exemption_json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.[0].metadata.annotations["security.signalloom.ai/exemption-id"] == "SA-TODO-001"'
	echo "$output" | jq -e '.[0].metadata.annotations["security.signalloom.ai/decision-date"] == "2026-10-16"'
	echo "$output" | jq -e '.[0].metadata.annotations["security.signalloom.ai/register"] == "docs/signalloom/security-architecture-todos.md"'
	echo "$output" | jq -e '.[0].metadata.annotations["security.signalloom.ai/reason"] | test("AI provider")'
	echo "$output" | jq -e '.[0].metadata.annotations["security.signalloom.ai/replacement"] | (test("L7") and test("mesh") and test("Cilium"))'
}

@test "the register entry exists and matches the manifest id" {
	[ -f "$register" ]
	id="$(exemption_json | jq -r '.[0].metadata.annotations["security.signalloom.ai/exemption-id"]')"
	[ "$id" = "SA-TODO-001" ]
	# One heading for the id, and the policy name and the three candidate
	# replacements named in the entry.
	[ "$(grep -c "^## $id" "$register")" -eq 1 ]
	grep -q "$exemption" "$register"
	grep -qi 'L7 egress proxy' "$register"
	grep -qi 'service mesh' "$register"
	grep -qi 'Cilium' "$register"
	grep -qi 'exit criterion' "$register"
	# The pre-existing unbounded rules are recorded too.
	[ "$(grep -c '^## SA-TODO-002' "$register")" -eq 1 ]
}

@test "allow-portal-dependencies no longer claims that public 443 is denied" {
	# That comment was true before SA-TODO-001 and is false after it. A
	# reader who trusts it would miss the exemption.
	[ -s "$base_policy" ]
	run grep -cF 'public egress on 443 remains denied' "$base_policy"
	[ "$output" = "0" ]
	# And the corrected comment names the exemption instead.
	grep -qF 'allow-portal-public-https-egress exemption (SA-TODO-001)' "$base_policy"
}
