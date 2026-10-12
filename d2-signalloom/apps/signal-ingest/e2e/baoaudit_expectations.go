// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the baoaudit fixture corpus
// (collectors/baoaudit/testdata), asserted exactly by
// TestBaoAuditE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Counts are over the baoaudit corpus ONLY; every rule here gates on Source
// "openbao-audit" and LayerIdentityAuth so the corpus cannot cross-fire into the
// awslogs/k8saudit/gcpaudit/landlock bundles.

const bundleOpenBaoAudit = "kusari-openbao-audit"

// baoRuleExpectations is the stage-1 table, sorted by rule id.
var baoRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleOpenBaoAudit, Rule: "policy-or-mount-change", Findings: 2,
		Positive: "baoaudit/policy-mount.json: create sys/policies/acl/escalate and update sys/mounts/newkv by attacker",
		Negative: "baoaudit/policy-mount.json: platform-admin policy create and attacker read of sys/mounts",
	},
	{
		Bundle: bundleOpenBaoAudit, Rule: "root-token-use", Findings: 1,
		Positive: "baoaudit/root-token.json: role:root reads auth/token/lookup-self",
		Negative: "baoaudit/root-token.json: role:app reads cubbyhole/entry",
	},
	{
		Bundle: bundleOpenBaoAudit, Rule: "secret-read", Findings: 3,
		Positive: "baoaudit/secret-read.json: three secret/data/app-N reads by attacker",
		Negative: "baoaudit/secret-read.json: secret-syncer reads secret/data/x and attacker reads cubbyhole/entry",
	},
	{
		Bundle: bundleOpenBaoAudit, Rule: "token-create-broad", Findings: 1,
		Positive: "baoaudit/token-create.json: attacker creates auth/token/create",
		Negative: "baoaudit/token-create.json: token-minter creates auth/token/create and attacker reads auth/token/accessors",
	},
}

// baoWindowExpectations is the stage-2 table.
var baoWindowExpectations = []windowExpectation{
	{
		Bundle: bundleOpenBaoAudit, Window: "secret-read-burst",
		OverRule: "secret-read", Decisions: 1, Count: 3,
		Why: "attacker's 3 secret reads inside 5m cross the threshold of 3; secret-syncer is allow-listed and cubbyhole is another mount",
	},
}

// Totals over the baoaudit corpus, cross-checked against the two tables above.
const (
	wantBaoObservations = 14
	wantBaoFindings     = 7
	wantBaoDecisions    = 1
)
