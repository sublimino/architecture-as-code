// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

// The per-rule and per-window expectation table for the Kusari fixture corpus.
//
// This is the readable half of the suite: it is what somebody adding a signal
// edits, and it is what `make test-kusari-e2e` prints as a summary table. The
// test asserts the table exactly — an extra finding is as much a failure as a
// missing one, because an over-triggering rule is how a detection control
// becomes noise nobody reads.
//
// Counts are over KusariFixtureObservations ONLY. The default awslogs corpus
// (testdata/cloudtrail.json and friends) is deliberately excluded: it belongs to
// the projection card, its totals are asserted in policy/e2e_fixture_test.go,
// and coupling this table to it would make a fixture edit over there break a
// test over here for no gain.
//
// Both bundles the tenant ships are loaded, because the boot loader loads the
// whole tree and the pilot runs both. They overlap on the IAM path by design
// (cloud-signals.yaml says so), and the overlap is visible here as the same
// event counted under two rule ids.

// ruleExpectation is one row of the table.
type ruleExpectation struct {
	// Bundle and Rule identify the rule.
	Bundle, Rule string
	// Findings is the exact number of findings the corpus must produce.
	Findings int
	// Positive names the fixture object whose record fires the rule, and
	// Negative the fixture record that must NOT fire it. Both are free text and
	// exist to be read in the summary table; the NEGATIVE is also mechanically
	// checked, by TestKusariE2E_EveryRuleHasANegative, which asserts the
	// fixture object that carries the negative projects MORE observations than
	// the rule produced findings for it.
	Positive, Negative string
}

// windowExpectation is one stage-2 row.
type windowExpectation struct {
	Bundle, Window, OverRule string
	// Decisions is the exact number of decisions the corpus must produce.
	Decisions int
	// Count is the evidence count on the single decision, when Decisions is 1.
	Count int
	// Why records what the window is claiming, for the summary table.
	Why string
}

const (
	bundleIAMChange    = "kusari-iam-change"
	bundleCloudSignals = "kusari-cloud-signals"
)

// ruleExpectations is the stage-1 table. Keep it sorted by (bundle, rule) so the
// printed summary is stable and a diff of this file reads as one row changing.
var ruleExpectations = []ruleExpectation{
	{
		Bundle: bundleCloudSignals, Rule: "console-login-outside-allowlist", Findings: 1,
		Positive: "kusari/console-login.json: the account root signs in (no MFA, which the rule cannot see)",
		Negative: "kusari/console-login.json: kusari-operator, who is in vars.console_login_actors",
	},
	{
		Bundle: bundleCloudSignals, Rule: "cross-account-assume-role", Findings: 2,
		Positive: "kusari/cross-account-assume-role.json: partner-integration in account 999988887777, twice",
		Negative: "kusari/cross-account-assume-role.json: a same-account role chain, and an allowlisted partner CI role",
	},
	{
		Bundle: bundleCloudSignals, Rule: "eks-access-entry-created", Findings: 2,
		Positive: "kusari/eks-control-plane.json: CreateAccessEntry and AssociateAccessPolicy by kusari-agent",
		Negative: "kusari/eks-control-plane.json: DescribeCluster (a read)",
	},
	{
		Bundle: bundleCloudSignals, Rule: "eks-cluster-config-changed", Findings: 1,
		Positive: "kusari/eks-control-plane.json: UpdateClusterConfig turning the public endpoint on",
		Negative: "kusari/eks-control-plane.json: the same API by break-glass, who is in vars.eks_cluster_admin_actors",
	},
	{
		Bundle: bundleCloudSignals, Rule: "guardduty-detection-tampered", Findings: 3,
		Positive: "kusari/guardduty-tamper.json: CreateFilter, ArchiveFindings, UpdateDetector",
		Negative: "kusari/guardduty-tamper.json: GetDetector (a read)",
	},
	{
		Bundle: bundleCloudSignals, Rule: "iam-credential-or-policy-change", Findings: 3,
		Positive: "kusari/iam-credential-burst.json: CreateAccessKey, AttachUserPolicy, CreateLoginProfile by kusari-builder",
		Negative: "kusari/iam-credential-burst.json: CreateAccessKey by break-glass",
	},
	{
		Bundle: bundleCloudSignals, Rule: "s3-bucket-exposure-changed", Findings: 2,
		Positive: "kusari/s3-public-exposure.json: PutBucketPolicy and PutBucketPublicAccessBlock",
		Negative: "kusari/s3-public-exposure.json: GetBucketPolicy (a read)",
	},
	{
		Bundle: bundleCloudSignals, Rule: "vpc-egress-rejected", Findings: 23,
		Positive: "kusari/vpcflow-reject-burst.log: 20 REJECTs from 10.0.9.9 plus 3 from 10.0.8.8",
		Negative: "kusari/vpcflow-reject-burst.log: two ACCEPT flows",
	},
	{
		// The narrow IAM bundle sees the burst fixture too. It covers a smaller
		// set of event names than cloud-signals does, which is why the counts
		// differ: AttachUserPolicy only.
		Bundle: bundleIAMChange, Rule: "access-key-created", Findings: 1,
		Positive: "kusari/iam-credential-burst.json: CreateAccessKey by kusari-builder",
		Negative: "kusari/iam-credential-burst.json: CreateAccessKey by break-glass",
	},
	{
		Bundle: bundleIAMChange, Rule: "iam-priv-change", Findings: 1,
		Positive: "kusari/iam-credential-burst.json: AttachUserPolicy by kusari-builder",
		Negative: "kusari/iam-credential-burst.json: CreateLoginProfile, which this narrower bundle does not list",
	},
	{
		Bundle: bundleIAMChange, Rule: "vpc-reject", Findings: 23,
		Positive: "kusari/vpcflow-reject-burst.log: the same 23 REJECTs",
		Negative: "kusari/vpcflow-reject-burst.log: two ACCEPT flows",
	},
}

// windowExpectations is the stage-2 table.
var windowExpectations = []windowExpectation{
	{
		Bundle: bundleCloudSignals, Window: "cross-account-assume-role-burst-30m",
		OverRule: "cross-account-assume-role", Decisions: 1, Count: 2,
		Why: "two cross-account assumptions by one foreign principal inside 30m",
	},
	{
		Bundle: bundleCloudSignals, Window: "iam-change-burst-10m",
		OverRule: "iam-credential-or-policy-change", Decisions: 1, Count: 3,
		Why: "three credential/policy changes by kusari-builder inside 10m",
	},
	{
		Bundle: bundleCloudSignals, Window: "vpc-reject-burst-5m",
		OverRule: "vpc-egress-rejected", Decisions: 1, Count: 20,
		Why: "20 REJECTs from 10.0.9.9 inside 5m; 10.0.8.8's three do not join the counter, which is the key dimension under test",
	},
	{
		// The narrow bundle's window is over ITS rule, which the Kusari corpus
		// reaches exactly once. Zero is the expectation and it is worth stating:
		// a window that fires on one finding would be a threshold defect, and
		// only an explicit zero can catch it.
		Bundle: bundleIAMChange, Window: "iam-change-burst",
		OverRule: "iam-priv-change", Decisions: 0,
		Why: "one iam-priv-change finding is below the threshold of three",
	},
}

// Totals over the Kusari fixture corpus, asserted as a cross-check on the two
// tables above: a row added to a table and not to the totals, or the reverse, is
// red. Bookkeeping that agrees with itself is the point.
const (
	wantKusariObservations = 47
	wantKusariFindings     = 62
	wantKusariDecisions    = 3
)
