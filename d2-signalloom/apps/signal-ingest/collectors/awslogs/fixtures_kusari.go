// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"fmt"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// The Kusari pilot signal corpus: the extra AWS signals the kusari-cloud-signals
// bundle is written against, over and above the three default fixture objects.
//
// # Why these are a SEPARATE set rather than more entries in FixtureFiles
//
// FixtureFiles() is an explicit ordered list, not a walk of the embedded tree,
// and contract_test.go iterates that list to assert per-source label contracts
// and the mode-matrix observation count. The embed directive IS recursive
// (`//go:embed testdata` pulls in testdata/kusari/** as well), so these files
// are readable through FixtureBytes without any change to the directive — but
// adding them to FixtureFiles() would silently move every count the existing
// contract tests assert, and would change what fixture MODE replays on the
// cluster. Neither is in this card's scope.
//
// So the two sets are explicit and disjoint, and KusariFixtureFiles is opt-in:
// the e2e harness and the Kusari contract test name it, the default replay path
// does not.
const (
	KusariFixtureEKS            = "kusari/eks-control-plane.json"
	KusariFixtureConsoleLogin   = "kusari/console-login.json"
	KusariFixtureAssumeRole     = "kusari/cross-account-assume-role.json"
	KusariFixtureS3Exposure     = "kusari/s3-public-exposure.json"
	KusariFixtureGuardDuty      = "kusari/guardduty-tamper.json"
	KusariFixtureIAMBurst       = "kusari/iam-credential-burst.json"
	KusariFixtureVPCRejectBurst = "kusari/vpcflow-reject-burst.log"

	// KusariFixtureEventBridgeEnvelope is a high-severity GuardDuty finding in
	// its real EventBridge shape, projected by ProjectGuardDuty: the positive for
	// guardduty-high-severity. KusariFixtureGuardDutyLowSeverity is the same
	// shape at severity 2, its negative. See
	// TestKusariFixtures_EventBridgeEnvelopeProjectsToAGuardDutyObservation.
	KusariFixtureEventBridgeEnvelope  = "kusari/guardduty-eventbridge-envelope.json"
	KusariFixtureGuardDutyLowSeverity = "kusari/guardduty-eventbridge-low-severity.json"
)

// KusariFixtureFiles returns the Kusari pilot fixture objects in replay order.
//
// Order is the order a policy run sees them when the slice is fed straight
// through; the e2e harness re-sorts by (timestamp, ID) via
// policy.SortObservations before ingesting, because that is what the live
// stream and the replay oracle both do. The order here therefore only has to be
// deterministic, and it is.
func KusariFixtureFiles() []string {
	return []string{
		KusariFixtureEKS,
		KusariFixtureConsoleLogin,
		KusariFixtureAssumeRole,
		KusariFixtureS3Exposure,
		KusariFixtureGuardDuty,
		KusariFixtureIAMBurst,
		KusariFixtureVPCRejectBurst,
		KusariFixtureEventBridgeEnvelope,
		KusariFixtureGuardDutyLowSeverity,
	}
}

// KusariFixtureObservations projects every KusariFixtureFiles object, in order,
// through the production Projector. It takes the same (tenantID, region)
// arguments FixtureObservations does, for the same reason: tenancy and the VPC
// Flow region fallback are collector configuration and never read from a record
// (SLAWS D7).
func KusariFixtureObservations(tenantID, region string) ([]model.Observation, error) {
	p := Projector{TenantID: tenantID, Region: region}

	var out []model.Observation
	for _, name := range KusariFixtureFiles() {
		body, err := FixtureBytes(name)
		if err != nil {
			return nil, err
		}
		obs, err := p.Project(body, FixtureOrigin(name))
		if err != nil {
			return nil, fmt.Errorf("awslogs: projecting kusari fixture %q: %w", name, err)
		}
		out = append(out, obs...)
	}
	return out, nil
}
