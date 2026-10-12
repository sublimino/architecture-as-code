// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the netebpf network-egress
// fixture corpus (collectors/netebpf/testdata), asserted exactly by
// TestNetEgressE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Exact, not "at least": an over-triggering egress rule is noise an operator
// stops reading, and a lower bound cannot see it. Counts are over the netebpf
// corpus ONLY; every rule here source-gates on "sentinel.ebpf.socket_trace", so
// nothing from the awslogs VPC Flow stream (which shares the network_egress
// layer) can join, and nothing here fires on a VPC Flow record.

const bundleNetEgress = "kusari-network-egress"

// netEgressRuleExpectations is the stage-1 table, sorted by rule id.
var netEgressRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleNetEgress, Rule: "direct-ip-egress", Findings: 3,
		Positive: "netebpf/direct-ip-egress.json: 3 network_connect flows by agent-worker-sa to bare IPs with no resolved DNS name (qname bucket none)",
		Negative: "netebpf/direct-ip-egress.json: a connect with a resolved low-entropy name (api.internal.svc), so a name WAS resolved",
	},
	{
		Bundle: bundleNetEgress, Rule: "dns-tunnel", Findings: 2,
		Positive: "netebpf/dns-tunnel.json: 2 flows whose leftmost DNS label is high-entropy (qname bucket high)",
		Negative: "netebpf/dns-tunnel.json: a flow to a normal low-entropy name (api.example.com)",
	},
	{
		Bundle: bundleNetEgress, Rule: "off-cluster-resolver", Findings: 2,
		Positive: "netebpf/off-cluster-resolver.json: 2 DNS queries (dst_port 53) to 8.8.8.8 and 1.1.1.1, outside the cluster resolver set",
		Negative: "netebpf/off-cluster-resolver.json: a DNS query to the in-cluster resolver 10.96.0.10",
	},
	{
		Bundle: bundleNetEgress, Rule: "unexpected-destination", Findings: 2,
		Positive: "netebpf/unexpected-destination.json: 2 network_connect flows to 198.51.100.10/11, outside the expected-destination set",
		Negative: "netebpf/unexpected-destination.json: a connect to the expected destination 10.96.0.10",
	},
}

// netEgressWindowExpectations is the stage-2 table.
var netEgressWindowExpectations = []windowExpectation{
	{
		Bundle: bundleNetEgress, Window: "direct-ip-egress-burst",
		OverRule: "direct-ip-egress", Decisions: 1, Count: 3,
		Why: "agent-worker-sa's 3 direct-IP connects inside 5m cross the threshold of 3; the service_account key is the dimension under test",
	},
}

// Totals over the netebpf corpus, cross-checked against the two tables above.
const (
	wantNetEgressObservations = 13
	wantNetEgressFindings     = 9
	wantNetEgressDecisions    = 1
)
