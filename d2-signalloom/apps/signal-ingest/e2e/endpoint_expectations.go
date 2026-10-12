// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the sentinel eBPF
// endpoint_host fixture corpus (collectors/ebpf/endpoint_testdata), asserted
// exactly by TestEndpointE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Exact, not "at least": an over-triggering endpoint rule is noise an operator
// stops reading. Counts are over the sentinel eBPF corpus ONLY; every rule here
// source-gates on "sentinel.ebpf.syscall_trace", so nothing from the agent-nono
// Landlock stream (which shares the endpoint_host layer) can join, and nothing
// here fires on a Landlock record.

const bundleEndpoint = "kusari-endpoint-runtime"

// endpointRuleExpectations is the stage-1 table, sorted by rule id.
var endpointRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleEndpoint, Rule: "capability-or-ptrace", Findings: 2,
		Positive: "ebpf/capability-ptrace.json: a ptrace kprobe (__x64_sys_ptrace) and a cap_capable kprobe by agent-debug-sa",
		Negative: "ebpf/capability-ptrace.json: a benign __x64_sys_read kprobe (not in the sensitive-syscall set)",
	},
	{
		Bundle: bundleEndpoint, Rule: "sensitive-file-open", Findings: 3,
		Positive: "ebpf/sensitive-file-open.json: agent-snoop-sa opens /etc/shadow, /etc/passwd and the SA token",
		Negative: "ebpf/sensitive-file-open.json: the same SA opens /tmp/scratch.log (not a sensitive file)",
	},
	{
		Bundle: bundleEndpoint, Rule: "unexpected-execve", Findings: 2,
		Positive: "ebpf/unexpected-execve.json: agent-rogue-sa execs /usr/bin/nc and /bin/sh (not in allowed_exec_actors)",
		Negative: "ebpf/unexpected-execve.json: agent-trusted-sa execs /usr/bin/agent (allow-listed actor)",
	},
}

// endpointWindowExpectations is the stage-2 table.
var endpointWindowExpectations = []windowExpectation{
	{
		Bundle: bundleEndpoint, Window: "sensitive-file-open-burst",
		OverRule: "sensitive-file-open", Decisions: 1, Count: 3,
		Why: "agent-snoop-sa's 3 sensitive-file opens inside 5m cross the threshold of 3; the actor key is the dimension under test",
	},
}

// Totals over the sentinel eBPF corpus, cross-checked against the two tables above.
const (
	wantEndpointObservations = 10
	wantEndpointFindings     = 7
	wantEndpointDecisions    = 1
)
