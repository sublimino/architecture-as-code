// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"os"
	"path/filepath"
	"testing"
)

// actorAccountOf is the unit under test: the assuming principal's account,
// recovered from userIdentity.arn at PROJECTION time.
//
// Why it has to exist at all. `cross-account-assume-role` used to recover this
// account by calling obs.actor.startsWith("arn:aws:iam::"+account+":") inside
// CEL. That read the actor as STRUCTURE, and once obs.actor became a keyed
// pseudonym (SLAWS replay parity) the structure was gone: both startsWith calls
// evaluate false, both negations evaluate true, and the same-account negative
// fixture starts firing. Recovering the account here instead puts it in a label
// that survives the segment, so the rule compares two labels and live and replay
// agree. An account number is not personal data and the recipient account was
// already projected under exactly this reasoning.
func TestActorAccountOf(t *testing.T) {
	for _, tc := range []struct {
		name, arn, want string
	}{
		{"iam user", "arn:aws:iam::999988887777:user/partner-integration", "999988887777"},
		{"iam role", "arn:aws:iam::555544443333:role/kusari-ci-deploy", "555544443333"},
		{"account root", "arn:aws:iam::123456789012:root", "123456789012"},
		{"sts assumed role", "arn:aws:sts::123456789012:assumed-role/kusari-ci/build-10001", "123456789012"},
		{"sts federated user", "arn:aws:sts::210987654321:federated-user/alice", "210987654321"},
		// A service principal names no account. An empty answer is the honest one:
		// defaulting to the recipient account would make every service-principal
		// call read as same-account, which is the silent-false direction.
		{"service principal", "", ""},
		{"non-arn", "AIDAEXAMPLE", ""},
		// Partition-independent: aws-cn and aws-us-gov keep the account in field 4.
		{"china partition", "arn:aws-cn:iam::123456789012:user/x", "123456789012"},
		// S3 ARNs have an EMPTY account field by design. An empty field must not be
		// mistaken for a parse failure, nor a parse failure for an empty field --
		// both yield "", and both are correctly "no account named".
		{"empty account field", "arn:aws:s3:::my-bucket", ""},
		// Five components, not six. The last field sits in the account POSITION
		// but the ARN is truncated, so reading it as an account would be reading a
		// malformed string as structure -- the mistake this whole label exists to
		// stop the rule making.
		{"too few fields", "arn:aws:iam::123456789012", ""},
		// Strict twelve-digit AWS account ID bound (§2.3 contract).
		{"eleven digits", "arn:aws:iam::12345678901:user/x", ""},
		{"thirteen digits", "arn:aws:iam::1234567890123:user/x", ""},
		{"non-digits in account", "arn:aws:iam::12345678901a:user/x", ""},
		{"all letters in account", "arn:aws:iam::abcdefghijkl:user/x", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := actorAccountOf(tc.arn); got != tc.want {
				t.Errorf("actorAccountOf(%q) = %q, want %q", tc.arn, got, tc.want)
			}
		})
	}
}

// The projection stamps the label, and stamps it only when an account is named.
func TestProjectCloudTrail_StampsActorAccountID(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("testdata", "kusari", "cross-account-assume-role.json"))
	if err != nil {
		t.Fatalf("reading the fixture: %v", err)
	}
	obs, err := Projector{TenantID: "kusari", Region: "us-east-1"}.
		ProjectCloudTrail(body, Origin{Bucket: "b", Key: "cross-account-assume-role.json"})
	if err != nil {
		t.Fatalf("ProjectCloudTrail: %v", err)
	}
	if len(obs) != 4 {
		t.Fatalf("the fixture projected %d observations, want 4; this test's record indices are wrong", len(obs))
	}

	// Record order is fixture order. The third is the same-account role chain --
	// the negative fixture whose silence is the whole point of the label.
	want := []string{"999988887777", "999988887777", "123456789012", "555544443333"}
	for i, w := range want {
		if got := obs[i].Labels[LabelActorAccountID]; got != w {
			t.Errorf("observation %d: %s = %q, want %q", i, LabelActorAccountID, got, w)
		}
	}
	if obs[2].Labels[LabelActorAccountID] != obs[2].Labels[LabelAWSAccountID] {
		t.Errorf("the same-account role chain must have actor_account_id == aws_account_id, got %q vs %q",
			obs[2].Labels[LabelActorAccountID], obs[2].Labels[LabelAWSAccountID])
	}
	for _, i := range []int{0, 1, 3} {
		if obs[i].Labels[LabelActorAccountID] == obs[i].Labels[LabelAWSAccountID] {
			t.Errorf("observation %d must be cross-account", i)
		}
	}
}

// A record with no userIdentity.arn carries no actor_account_id key at all,
// rather than an empty-string value. An empty value would make
// has(obs.labels.actor_account_id) true and the != comparison fire against every
// recipient account -- a rule that detects the absence of an actor.
func TestProjectCloudTrail_OmitsActorAccountIDWhenUnknown(t *testing.T) {
	body := []byte(`{"Records":[{"eventTime":"2026-03-01T00:00:00Z","eventSource":"s3.amazonaws.com",` +
		`"eventName":"PutBucketPolicy","awsRegion":"us-east-1","recipientAccountId":"123456789012",` +
		`"sourceIPAddress":"203.0.113.1"}]}`)
	obs, err := Projector{TenantID: "kusari", Region: "us-east-1"}.
		ProjectCloudTrail(body, Origin{Bucket: "b", Key: "x.json"})
	if err != nil {
		t.Fatalf("ProjectCloudTrail: %v", err)
	}
	if _, present := obs[0].Labels[LabelActorAccountID]; present {
		t.Errorf("%s is present on a record with no userIdentity.arn: %q",
			LabelActorAccountID, obs[0].Labels[LabelActorAccountID])
	}
}
