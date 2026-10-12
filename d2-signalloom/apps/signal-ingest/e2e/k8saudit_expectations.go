// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the k8saudit-kube fixture
// corpus (collectors/k8saudit/testdata), asserted exactly by
// TestK8sAuditE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Exact, not "at least": an over-triggering k8s rule is noise an operator stops
// reading, and a lower bound cannot see it. Counts are over the k8saudit corpus
// ONLY; the awslogs/Kusari corpus is a separate table in expectations.go and the
// two never interact because every rule here source-gates on "k8saudit-kube" and
// every rule there gates on cloud_control_plane / network_egress layers.

const bundleK8sAudit = "kusari-k8s-audit"

// k8sRuleExpectations is the stage-1 table, sorted by rule id.
var k8sRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleK8sAudit, Rule: "anonymous-allowed", Findings: 2,
		Positive: "k8saudit/anonymous.json: system:anonymous list pods and system:unauthenticated get pod, both ALLOWED",
		Negative: "k8saudit/anonymous.json: the same anonymous principal FORBIDDEN (decision forbid)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "csr-create-approve", Findings: 2,
		Positive: "k8saudit/csr.json: a CSR create and an approval-subresource update",
		Negative: "k8saudit/csr.json: a get of the same CSR (a read)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "nodes-proxy", Findings: 1,
		Positive: "k8saudit/node-portforward.json: nodes/proxy to node-1",
		Negative: "k8saudit/node-portforward.json: a plain get of node-1 (no proxy subresource)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "pods-exec-attach", Findings: 5,
		Positive: "k8saudit/exec.json: 3 exec by alice, 1 attach by bob, 1 ephemeralcontainers by carol (all ResponseComplete)",
		Negative: "k8saudit/exec.json: the ResponseStarted exec (wrong stage) and a get pod (no subresource)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "pods-portforward", Findings: 1,
		Positive: "k8saudit/node-portforward.json: pods/portforward to api-7",
		Negative: "k8saudit/node-portforward.json: a plain get of api-7 (no portforward subresource)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "privileged-pod-create", Findings: 2,
		Positive: "k8saudit/pod-create.json: two pod creates by karl (the privileged-surface over-trigger)",
		Negative: "k8saudit/pod-create.json: a get of the same pod (a read, not a create)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "rbac-escalation", Findings: 3,
		Positive: "k8saudit/rbac.json: create clusterrolebindings, create rolebindings, and the impersonate verb",
		Negative: "k8saudit/rbac.json: a create of a configmap, and a get of a clusterrolebinding",
	},
	{
		Bundle: bundleK8sAudit, Rule: "secrets-read-outside-allowlist", Findings: 4,
		Positive: "k8saudit/secrets-read.json: 3 secret gets by mallory and 1 list by eve",
		Negative: "k8saudit/secrets-read.json: a get by the allow-listed secret-reader SA, and a watch by mallory (watch excluded)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "secrets-write", Findings: 2,
		Positive: "k8saudit/secrets-write.json: a secret create and a secret update by frank",
		Negative: "k8saudit/secrets-write.json: a get of a configmap by frank (not a secret write)",
	},
	{
		Bundle: bundleK8sAudit, Rule: "serviceaccount-token-create", Findings: 1,
		Positive: "k8saudit/satoken.json: serviceaccounts/token create by leo (not a system controller)",
		Negative: "k8saudit/satoken.json: the same by the token-cleaner controller, and a plain SA get by leo",
	},
	{
		Bundle: bundleK8sAudit, Rule: "webhookconfig-create", Findings: 2,
		Positive: "k8saudit/webhookconfig.json: a validating and a mutating webhook configuration create",
		Negative: "k8saudit/webhookconfig.json: a list of validating webhook configurations (a read)",
	},
}

// k8sWindowExpectations is the stage-2 table.
var k8sWindowExpectations = []windowExpectation{
	{
		Bundle: bundleK8sAudit, Window: "exec-burst",
		OverRule: "pods-exec-attach", Decisions: 1, Count: 3,
		Why: "alice's 3 execs inside 5m cross the threshold of 3; bob's attach and carol's ephemeralcontainers are other actors and do not join the counter",
	},
	{
		Bundle: bundleK8sAudit, Window: "secret-read-burst",
		OverRule: "secrets-read-outside-allowlist", Decisions: 1, Count: 3,
		Why: "mallory's 3 secret gets inside 5m cross the threshold of 3; eve's single list is a different actor",
	},
}

// Totals over the k8saudit corpus, cross-checked against the two tables above.
const (
	wantK8sObservations = 40
	wantK8sFindings     = 25
	wantK8sDecisions    = 2
)
