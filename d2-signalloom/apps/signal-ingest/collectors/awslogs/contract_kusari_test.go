// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// The Kusari pilot fixture corpus, against the SAME §2.3 contract the default
// corpus is held to.
//
// These assertions are deliberately the contract ones rather than per-file
// counts. A per-file count test would go red every time somebody adds a record
// to a fixture, which is the maintenance the Kusari pilot is going to do most
// often; what must not drift is the LABEL CONTRACT, because that is what the
// bundle's rules are written against.
//
// The per-rule expectations -- which fixture fires which rule -- are asserted in
// d2-signalloom/apps/signal-ingest/e2e, through the real policy pipeline. They
// belong there and not here: a label assertion cannot tell you whether a rule
// matched.

const (
	kusariTenant = "kusari"
	kusariRegion = "us-east-1"
)

func kusariObs(t *testing.T) []model.Observation {
	t.Helper()
	obs, err := KusariFixtureObservations(kusariTenant, kusariRegion)
	if err != nil {
		t.Fatalf("KusariFixtureObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("the kusari fixture corpus is empty; every assertion below would be vacuous")
	}
	return obs
}

// Every fixture object must project without error and produce at least one
// observation. A fixture that silently projects to nothing is the failure mode
// the EventBridge envelope demonstrates, and it must not happen by accident to
// a file that IS in the replay set.
func TestKusariFixtures_EveryObjectProjectsSomething(t *testing.T) {
	p := Projector{TenantID: kusariTenant, Region: kusariRegion}
	for _, name := range KusariFixtureFiles() {
		body, err := FixtureBytes(name)
		if err != nil {
			t.Fatalf("FixtureBytes(%s): %v", name, err)
		}
		obs, err := p.Project(body, FixtureOrigin(name))
		if err != nil {
			t.Fatalf("projecting %s: %v", name, err)
		}
		if len(obs) == 0 {
			t.Errorf("%s projected to ZERO observations; a fixture in the replay set that produces nothing is indistinguishable from a quiet account", name)
		}
	}
}

// Every observation satisfies the model's own validity rules and carries the
// documented key set for its source.
func TestKusariFixtures_SatisfyTheLabelContract(t *testing.T) {
	for _, o := range kusariObs(t) {
		if err := o.Validate(); err != nil {
			t.Errorf("observation %s (%s) is not valid: %v", o.ID, o.RawEvidenceRef, err)
		}
		required, documented := ContractKeysFor(o.Source)
		if required == nil {
			t.Fatalf("observation %s has undocumented source %q; a new source must be added to contract_doc.go before it can be emitted", o.ID, o.Source)
		}
		for _, k := range required {
			if _, ok := o.Labels[k]; !ok {
				t.Errorf("observation %s (%s, source %s) is missing required label %q", o.ID, o.RawEvidenceRef, o.Source, k)
			}
		}
		allowed := map[string]bool{}
		for _, k := range documented {
			allowed[k] = true
		}
		for k := range o.Labels {
			if !allowed[k] {
				t.Errorf("observation %s carries label %q, which is not in the §2.3 contract for source %s", o.ID, k, o.Source)
			}
		}
		if o.Labels[LabelTenantID] != kusariTenant {
			t.Errorf("observation %s tenant_id = %q, want %q (tenancy is collector configuration, never the record)", o.ID, o.Labels[LabelTenantID], kusariTenant)
		}
		if o.Labels[LabelProvider] != ProviderAWS {
			t.Errorf("observation %s provider = %q, want %q", o.ID, o.Labels[LabelProvider], ProviderAWS)
		}
	}
}

// The negative contract, over the Kusari corpus. The fixtures carry policy
// documents, assume-role policy documents, access-key parameters and a public
// bucket policy, none of which may reach a label key or value.
func TestKusariFixtures_NegativeContractHolds(t *testing.T) {
	for _, o := range kusariObs(t) {
		for k, v := range o.Labels {
			for _, banned := range ForbiddenSubstrings {
				if strings.Contains(k, banned) || strings.Contains(v, banned) {
					t.Errorf("observation %s label %q=%q carries banned token %q", o.ID, k, v, banned)
				}
			}
		}
		// The fixtures' own payload strings, which exist only inside
		// requestParameters and responseElements and must not survive.
		for _, leak := range []string{
			"assumeRolePolicyDocument", "policyDocument", "PublicAccessBlockConfiguration",
			"\"Principal\":\"*\"", "MFAUsed", "detail-type",
		} {
			if strings.Contains(o.Description, leak) {
				t.Errorf("observation %s description leaks %q: %q", o.ID, leak, o.Description)
			}
			for k, v := range o.Labels {
				if strings.Contains(k, leak) || strings.Contains(v, leak) {
					t.Errorf("observation %s label %q=%q leaks %q", o.ID, k, v, leak)
				}
			}
		}
	}
}

// Derived IDs and evidence refs: the same record projected twice is the same
// observation, which is what makes replay deduplicable.
func TestKusariFixtures_IDsAreDerivedAndUnique(t *testing.T) {
	first := kusariObs(t)
	second := kusariObs(t)
	if len(first) != len(second) {
		t.Fatalf("two projections of the same corpus produced %d and %d observations", len(first), len(second))
	}
	seen := map[string]string{}
	for i := range first {
		if first[i].ID != second[i].ID {
			t.Errorf("observation %d is not deterministic: %s vs %s", i, first[i].ID, second[i].ID)
		}
		if prev, dup := seen[first[i].ID]; dup {
			t.Errorf("observation ID %s is produced by both %s and %s", first[i].ID, prev, first[i].RawEvidenceRef)
		}
		seen[first[i].ID] = first[i].RawEvidenceRef
		if !strings.HasPrefix(first[i].RawEvidenceRef, "testdata/kusari/") {
			t.Errorf("observation %s evidence ref %q is not a kusari fixture path", first[i].ID, first[i].RawEvidenceRef)
		}
	}
}

// The VPC Flow burst fixture: the record index counts DATA lines only, so the
// header and the comment block must not advance it. Getting this wrong would
// make every evidence ref -- and therefore every observation ID -- wrong, and
// the error would be invisible because the IDs would still be unique and stable.
func TestKusariFixtures_VPCFlowIndexSkipsHeaderAndComments(t *testing.T) {
	p := Projector{TenantID: kusariTenant, Region: kusariRegion}
	body, err := FixtureBytes(KusariFixtureVPCRejectBurst)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	obs, err := p.Project(body, FixtureOrigin(KusariFixtureVPCRejectBurst))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if want := "testdata/kusari/vpcflow-reject-burst.log#0"; obs[0].RawEvidenceRef != want {
		t.Errorf("first flow record ref = %q, want %q", obs[0].RawEvidenceRef, want)
	}
	rejects := 0
	for _, o := range obs {
		if o.Layer != model.LayerNetworkEgress {
			t.Errorf("flow observation %s is layer %q, want %q", o.ID, o.Layer, model.LayerNetworkEgress)
		}
		if o.ActorHint != "" {
			t.Errorf("flow observation %s has actor_hint %q; flow records name no principal (§2.3)", o.ID, o.ActorHint)
		}
		if o.Labels[LabelEventName] == "REJECT" {
			rejects++
		}
	}
	// 20 from one source address plus 3 from another: the window threshold and
	// the key-dimension negative.
	if rejects != 23 {
		t.Errorf("the burst fixture holds %d REJECT records, want 23 (20 + 3 from a second source)", rejects)
	}
}

// A GuardDuty finding in its real EventBridge envelope projects to NOTHING, with
// no error.
//
// This is the failure mode worth pinning rather than fixing here: the envelope
// is valid JSON with no Records[] array, so ProjectCloudTrail decodes it
// successfully and returns an empty slice. A collector pointed at a bucket of
// EventBridge events would therefore report success and ingest zero rows, which
// reads exactly like an account in which nothing happened.
//
// The envelope is deliberately absent from KusariFixtureFiles, so it never
// reaches a rule and never contributes to the e2e totals. The follow-up is named
// in the fixture header: GuardDuty findings need an EventBridge-shaped
// projection path with its own §2.3 rows, or a forwarder that re-shapes them
// before they reach the bucket.
func TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing(t *testing.T) {
	for _, name := range KusariFixtureFiles() {
		if name == KusariFixtureEventBridgeEnvelope {
			t.Fatalf("%s is in the replay set; it projects to nothing and would silently contribute no findings", name)
		}
	}

	p := Projector{TenantID: kusariTenant, Region: kusariRegion}
	body, err := FixtureBytes(KusariFixtureEventBridgeEnvelope)
	if err != nil {
		t.Fatalf("FixtureBytes: %v", err)
	}
	obs, err := p.Project(body, FixtureOrigin(KusariFixtureEventBridgeEnvelope))
	if err != nil {
		t.Fatalf("the EventBridge envelope errored rather than projecting empty: %v; if the projection learned to reject it, that is an improvement -- update this test to assert the error", err)
	}
	if len(obs) != 0 {
		t.Fatalf("the EventBridge envelope projected %d observations; if a projection path was added, move the fixture into KusariFixtureFiles and give it a rule", len(obs))
	}
	// And the gap is real rather than a typo in the fixture: the finding the
	// envelope describes is in the bytes, and none of it reaches an observation.
	if !strings.Contains(string(body), "GuardDuty Finding") {
		t.Error("the EventBridge fixture no longer describes a GuardDuty finding; the gap this test documents has moved")
	}
}
