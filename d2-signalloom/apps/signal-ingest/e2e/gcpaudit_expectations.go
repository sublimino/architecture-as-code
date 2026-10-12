// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule expectation table for the GCP Cloud Audit admin-activity fixture
// corpus (collectors/gcpaudit/testdata), asserted exactly by
// TestGcpAuditE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Counts are over the gcpaudit corpus only. Every rule in the bundle source- and
// layer-gates on the GCP projection, so awslogs, k8saudit, and landlock bundles
// must stay quiet when this corpus runs through the full shipped bundle tree.

const bundleGcpAdmin = "kusari-gcp-admin"

// gcpRuleExpectations is the stage-1 table.
var gcpRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleGcpAdmin, Rule: "iam-policy-binding-change", Findings: 2,
		Positive: "gcpaudit/iam-setiampolicy.json: two SetIamPolicy calls by attackers outside iam_admins",
		Negative: "gcpaudit/iam-setiampolicy.json: SetIamPolicy by iam-admin and GetIamPolicy by attacker",
	},
	{
		Bundle: bundleGcpAdmin, Rule: "service-account-key-create", Findings: 1,
		Positive: "gcpaudit/sa-key-create.json: CreateServiceAccountKey by attacker outside sa_key_minters",
		Negative: "gcpaudit/sa-key-create.json: CreateServiceAccountKey by sa-key-bot and CreateServiceAccount by attacker",
	},
	{
		Bundle: bundleGcpAdmin, Rule: "bucket-iam-made-public", Findings: 2,
		Positive: "gcpaudit/bucket-iam-public.json: two storage.setIamPermissions calls by attackers outside storage_admins",
		Negative: "gcpaudit/bucket-iam-public.json: storage.setIamPermissions by storage-admin",
	},
	{
		Bundle: bundleGcpAdmin, Rule: "logging-sink-delete", Findings: 1,
		Positive: "gcpaudit/logging-sink-delete.json: DeleteSink by attacker outside logging_admins",
		Negative: "gcpaudit/logging-sink-delete.json: DeleteSink by logging-admin and CreateSink by attacker",
	},
}

// gcpWindowExpectations is deliberately empty: no GCP burst window is in scope.
var gcpWindowExpectations = []windowExpectation{}

const (
	wantGcpObservations = 13
	wantGcpFindings     = 6
	wantGcpDecisions    = 0
)
