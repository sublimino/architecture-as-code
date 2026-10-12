// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the identity_authorization
// corpus — SPIRE SVID issuance (collectors/spirea/testdata) plus SaaS login
// (collectors/workspacesaas/testdata/login) — asserted exactly by
// TestIdentityAuthE2E_FixtureCorpusMatchesTheExpectationTable.
//
// Exact, not "at least": an over-triggering identity rule is noise an operator
// stops reading. Counts are over the identity corpus ONLY; every rule here
// source-gates (spirea on "spire-agent", SaaS on the ".audit" suffix) and
// layer-gates, so the k8saudit, awslogs and application_saas bundles produce
// nothing on it and the two never interact.

const bundleIdentityAuth = "kusari-identity-auth"

// identityRuleExpectations is the stage-1 table, sorted by rule id.
var identityRuleExpectations = []ruleExpectation{
	{
		Bundle: bundleIdentityAuth, Rule: "saas-admin-role-grant", Findings: 1,
		Positive: "login/saas-login.json: mallory grants an admin role and is not a sanctioned grantor",
		Negative: "login/saas-login.json: admin@corp.internal grants an admin role (in vars.saas_privileged_grantors)",
	},
	{
		Bundle: bundleIdentityAuth, Rule: "saas-login-impossible-travel", Findings: 1,
		Positive: "login/saas-login.json: bob's login flagged risk_reason=impossible_travel",
		Negative: "login/saas-login.json: alice's benign login (risk_reason=none)",
	},
	{
		Bundle: bundleIdentityAuth, Rule: "saas-login-mfa-absent", Findings: 3,
		Positive: "login/saas-login.json: dave's three logins with mfa=absent",
		Negative: "login/saas-login.json: alice's login with mfa=present",
	},
	{
		Bundle: bundleIdentityAuth, Rule: "saas-login-new-geo", Findings: 1,
		Positive: "login/saas-login.json: carol logs in from RO, outside vars.known_login_geos",
		Negative: "login/saas-login.json: alice logs in from GB (in vars.known_login_geos)",
	},
	{
		Bundle: bundleIdentityAuth, Rule: "svid-foreign-trust-domain", Findings: 1,
		Positive: "svid-issuance.json: an SVID minted under trust_domain evil.example",
		Negative: "svid-issuance.json: the three SVIDs minted under kusari.dev (in vars.trusted_domains)",
	},
	{
		Bundle: bundleIdentityAuth, Rule: "svid-issued-unexpected-principal", Findings: 2,
		Positive: "svid-issuance.json: SVIDs for sa/rogue-exfil and sa/attacker, outside vars.allowed_spiffe_issuers",
		Negative: "svid-issuance.json: SVIDs for sa/agent-runner and sa/fleet-manager (allow-listed)",
	},
}

// identityWindowExpectations is the stage-2 table.
var identityWindowExpectations = []windowExpectation{
	{
		Bundle: bundleIdentityAuth, Window: "mfa-absent-login-burst",
		OverRule: "saas-login-mfa-absent", Decisions: 1, Count: 3,
		Why: "dave's 3 MFA-absent logins inside 10m cross the threshold of 3; no other actor has an MFA-absent login",
	},
}

// Totals over the identity corpus, cross-checked against the two tables above.
const (
	wantIdentityObservations = 12
	wantIdentityFindings     = 9
	wantIdentityDecisions    = 1
)
