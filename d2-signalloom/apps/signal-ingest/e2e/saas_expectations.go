// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the application_saas corpus
// (collectors/workspacesaas/testdata/app), asserted exactly by
// TestApplicationSaaSE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Exact, not "at least". Counts are over the application_saas corpus ONLY; every
// rule here source-gates on the ".audit" suffix and layer-gates on
// application_saas, so the k8saudit, awslogs and identity_authorization bundles
// (including the SaaS LOGIN surface, same collector and source suffix) produce
// nothing on it.

const bundleAppSaaS = "kusari-application-saas"

// saasRuleExpectations is the stage-1 table, sorted by rule id.
var saasRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleAppSaaS, Rule: "saas-admin-console-change", Findings: 1,
		Positive: "app/saas-app.json: grace performs an admin setting_change",
		Negative: "app/saas-app.json: grace's view_settings (a read, not a change)",
	},
	{
		Bundle: bundleAppSaaS, Rule: "saas-external-sensitive-share", Findings: 1,
		Positive: "app/saas-app.json: erin external-shares a confidential document",
		Negative: "app/saas-app.json: erin's internal_share of the same confidential document",
	},
	{
		Bundle: bundleAppSaaS, Rule: "saas-mass-file-download", Findings: 3,
		Positive: "app/saas-app.json: analyst's three downloads with item_count >= 100",
		Negative: "app/saas-app.json: analyst's small download with item_count 50 (below threshold)",
	},
	{
		Bundle: bundleAppSaaS, Rule: "saas-oauth-app-grant", Findings: 1,
		Positive: "app/saas-app.json: frank consents to an app with Mail.ReadWrite/Files.ReadWrite.All",
		Negative: "app/saas-app.json: frank consents to a read-only app (User.Read, Calendars.Read)",
	},
}

// saasWindowExpectations is the stage-2 table.
var saasWindowExpectations = []windowExpectation{
	{
		Bundle: bundleAppSaaS, Window: "mass-download-burst",
		OverRule: "saas-mass-file-download", Decisions: 1, Count: 3,
		Why: "analyst's 3 bulk downloads inside 10m cross the threshold of 3; the small download does not fire the rule and does not join the counter",
	},
}

// Totals over the application_saas corpus, cross-checked against the two tables.
const (
	wantSaaSObservations = 10
	wantSaaSFindings     = 6
	wantSaaSDecisions    = 1
)
