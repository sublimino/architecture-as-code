// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// mustFixture reads the same embedded bytes fixture mode replays, so a test can
// never assert against a file the collector would not have seen.
func mustFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := FixtureBytes(name)
	if err != nil {
		t.Fatalf("FixtureBytes(%q): %v", name, err)
	}
	return b
}

func testProjector() Projector {
	return Projector{TenantID: "kusari", Region: "us-east-1"}
}

func derivedID(t *testing.T, ref string) string {
	t.Helper()
	sum := sha256.Sum256([]byte(ref))
	return hex.EncodeToString(sum[:])
}

// --- §2.3 positive contract -------------------------------------------------

func TestProjectCloudTrail_FirstRecordCarriesEveryDocumentedKey(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureCloudTrail), FixtureOrigin(FixtureCloudTrail))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(obs) != 4 {
		t.Fatalf("projected %d observations from cloudtrail.json, want 4", len(obs))
	}

	got := obs[0]
	wantRef := "testdata/cloudtrail.json#0"

	if got.RawEvidenceRef != wantRef {
		t.Errorf("RawEvidenceRef = %q, want %q", got.RawEvidenceRef, wantRef)
	}
	if got.ID != derivedID(t, wantRef) {
		t.Errorf("ID = %q, want sha256 of the evidence ref %q", got.ID, derivedID(t, wantRef))
	}
	if want := time.Date(2026, 10, 2, 9, 14, 31, 0, time.UTC); !got.Timestamp.Equal(want) {
		t.Errorf("Timestamp = %s, want %s (eventTime, never time.Now())", got.Timestamp, want)
	}
	if got.Layer != model.LayerCloudControlPlane {
		t.Errorf("Layer = %q, want %q", got.Layer, model.LayerCloudControlPlane)
	}
	if got.Source != SourceIAM {
		t.Errorf("Source = %q, want %q (eventSource is iam.amazonaws.com)", got.Source, SourceIAM)
	}
	if want := "arn:aws:iam::123456789012:user/kusari-agent"; got.ActorHint != want {
		t.Errorf("ActorHint = %q, want %q (userIdentity.arn)", got.ActorHint, want)
	}

	want := map[string]string{
		LabelTenantID:     "kusari",
		LabelProvider:     "aws",
		LabelAWSAccountID: "123456789012",
		// Same account here: this fixture record is an in-account IAM change, so
		// the acting and receiving accounts agree. The cross-account fixture is
		// where the two diverge (actor_account_test.go).
		LabelActorAccountID: "123456789012",
		LabelAWSRegion:      "us-east-1",
		LabelEventSource:    "iam.amazonaws.com",
		LabelEventName:      "CreatePolicyVersion",
		LabelResourceType:   "AWS::IAM::Policy",
		LabelResourceName:   "arn:aws:iam::123456789012:policy/kusari-agent-policy",
		LabelSourceIP:       "203.0.113.10",
	}
	if !reflect.DeepEqual(got.Labels, want) {
		t.Errorf("Labels mismatch\n got: %v\nwant: %v", got.Labels, want)
	}
	if _, present := got.Labels[LabelErrorCode]; present {
		t.Errorf("error_code present on a successful event: %q", got.Labels[LabelErrorCode])
	}
}

func TestProjectCloudTrail_ErrorCodeAppearsOnlyWhenPresent(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureCloudTrail), FixtureOrigin(FixtureCloudTrail))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}

	// Record 2 is the denied CreateAccessKey.
	denied := obs[2]
	if got := denied.Labels[LabelEventName]; got != "CreateAccessKey" {
		t.Fatalf("obs[2] event_name = %q, want CreateAccessKey", got)
	}
	if got := denied.Labels[LabelErrorCode]; got != "AccessDenied" {
		t.Errorf("obs[2] error_code = %q, want AccessDenied", got)
	}
	// resources[] is empty, so the resource comes from the documented
	// requestParameters name allowlist, not from the raw body.
	if got := denied.Labels[LabelResourceType]; got != "AWS::IAM::User" {
		t.Errorf("obs[2] resource_type = %q, want AWS::IAM::User", got)
	}
	if got := denied.Labels[LabelResourceName]; got != "kusari-build-runner" {
		t.Errorf("obs[2] resource_name = %q, want kusari-build-runner", got)
	}

	for i, o := range obs {
		if i == 2 {
			continue
		}
		if _, present := o.Labels[LabelErrorCode]; present {
			t.Errorf("obs[%d] carries error_code %q but the record has no errorCode", i, o.Labels[LabelErrorCode])
		}
	}
}

func TestProjectCloudTrail_NonIAMEventSourceKeepsCloudTrailSource(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureCloudTrail), FixtureOrigin(FixtureCloudTrail))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}

	s3Event := obs[3]
	if s3Event.Source != SourceCloudTrail {
		t.Errorf("obs[3] Source = %q, want %q (eventSource is s3.amazonaws.com)", s3Event.Source, SourceCloudTrail)
	}
	if got := s3Event.Labels[LabelAWSRegion]; got != "eu-west-2" {
		t.Errorf("obs[3] aws_region = %q, want eu-west-2 (per-record awsRegion, not collector config)", got)
	}
	if got := s3Event.Labels[LabelResourceName]; got != "arn:aws:s3:::kusari-evidence" {
		t.Errorf("obs[3] resource_name = %q", got)
	}
}

func TestProjectIAM_EveryRecordIsSourcedAsIAM(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureIAM), FixtureOrigin(FixtureIAM))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(obs) != 2 {
		t.Fatalf("projected %d observations from iam.json, want 2", len(obs))
	}

	for i, o := range obs {
		if o.Source != SourceIAM {
			t.Errorf("obs[%d] Source = %q, want %q", i, o.Source, SourceIAM)
		}
		if o.Layer != model.LayerCloudControlPlane {
			t.Errorf("obs[%d] Layer = %q, want %q", i, o.Layer, model.LayerCloudControlPlane)
		}
		if got := o.Labels[LabelEventSource]; got != "iam.amazonaws.com" {
			t.Errorf("obs[%d] event_source = %q", i, got)
		}
		if got := o.Labels[LabelAWSAccountID]; got != "210987654321" {
			t.Errorf("obs[%d] aws_account_id = %q, want 210987654321", i, got)
		}
		if want := fmt.Sprintf("testdata/iam.json#%d", i); o.RawEvidenceRef != want {
			t.Errorf("obs[%d] RawEvidenceRef = %q, want %q", i, o.RawEvidenceRef, want)
		}
	}
	if got := obs[1].Labels[LabelErrorCode]; got != "MalformedPolicyDocument" {
		t.Errorf("obs[1] error_code = %q, want MalformedPolicyDocument", got)
	}
}

func TestProjectVPCFlow_CarriesEveryDocumentedKey(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureVPCFlow), FixtureOrigin(FixtureVPCFlow))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(obs) != 3 {
		t.Fatalf("projected %d observations from vpcflow.log, want 3 (the header line is not a record)", len(obs))
	}

	got := obs[0]
	wantRef := "testdata/vpcflow.log#0"
	if got.RawEvidenceRef != wantRef {
		t.Errorf("RawEvidenceRef = %q, want %q", got.RawEvidenceRef, wantRef)
	}
	if got.ID != derivedID(t, wantRef) {
		t.Errorf("ID = %q, want sha256 of %q", got.ID, wantRef)
	}
	if want := time.Unix(1790932800, 0).UTC(); !got.Timestamp.Equal(want) {
		t.Errorf("Timestamp = %s, want %s (flow start)", got.Timestamp, want)
	}
	if got.Layer != model.LayerNetworkEgress {
		t.Errorf("Layer = %q, want %q", got.Layer, model.LayerNetworkEgress)
	}
	if got.Source != SourceVPCFlow {
		t.Errorf("Source = %q, want %q", got.Source, SourceVPCFlow)
	}

	want := map[string]string{
		LabelTenantID:     "kusari",
		LabelProvider:     "aws",
		LabelAWSAccountID: "123456789012",
		LabelAWSRegion:    "us-east-1",
		LabelEventSource:  "vpcflow",
		LabelEventName:    "ACCEPT",
		LabelResourceType: "AWS::EC2::NetworkInterface",
		LabelResourceName: "eni-0abc1234def567890",
		LabelSourceIP:     "10.0.1.5",
		LabelDstIP:        "198.51.100.7",
		LabelDstPort:      "443",
		LabelProtocol:     "6",
		LabelBytes:        "18432",
	}
	if !reflect.DeepEqual(got.Labels, want) {
		t.Errorf("Labels mismatch\n got: %v\nwant: %v", got.Labels, want)
	}
}

func TestProjectVPCFlow_RejectActionIsTheEventName(t *testing.T) {
	obs, err := testProjector().Project(mustFixture(t, FixtureVPCFlow), FixtureOrigin(FixtureVPCFlow))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}

	actions := []string{obs[0].Labels[LabelEventName], obs[1].Labels[LabelEventName], obs[2].Labels[LabelEventName]}
	want := []string{"ACCEPT", "REJECT", "ACCEPT"}
	if !reflect.DeepEqual(actions, want) {
		t.Errorf("event_name sequence = %v, want %v", actions, want)
	}
	if got := obs[1].Labels[LabelDstPort]; got != "9001" {
		t.Errorf("obs[1] dst_port = %q, want 9001", got)
	}
	if got := obs[2].Labels[LabelProtocol]; got != "17" {
		t.Errorf("obs[2] protocol = %q, want 17 (UDP, the IANA number as logged)", got)
	}
}

// TestEveryDocumentedKeyIsAssertedForEveryFixture is the §2.3 completeness gate: each
// projected observation must carry every required key for its source and must carry no
// key that contract_doc.go does not document.
func TestEveryDocumentedKeyIsAssertedForEveryFixture(t *testing.T) {
	for _, name := range FixtureFiles() {
		t.Run(name, func(t *testing.T) {
			obs, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
			if err != nil {
				t.Fatalf("Project: %v", err)
			}
			if len(obs) == 0 {
				t.Fatalf("fixture %s projected 0 observations", name)
			}

			for i, o := range obs {
				required, documented := ContractKeysFor(o.Source)
				if len(required) == 0 {
					t.Fatalf("obs[%d] has undocumented source %q", i, o.Source)
				}
				for _, k := range required {
					if o.Labels[k] == "" {
						t.Errorf("obs[%d] (%s) missing required label %q", i, o.Source, k)
					}
				}
				for k := range o.Labels {
					if !contains(documented, k) {
						t.Errorf("obs[%d] (%s) carries undocumented label %q", i, o.Source, k)
					}
				}
				if err := o.Validate(); err != nil {
					t.Errorf("obs[%d] fails model.Observation.Validate: %v", i, err)
				}
				if n := len([]rune(o.Description)); n >= MaxDescriptionLen {
					t.Errorf("obs[%d] description is %d runes, want under %d: %q", i, n, MaxDescriptionLen, o.Description)
				}
				if strings.ContainsAny(o.Description, "\n\r") {
					t.Errorf("obs[%d] description is not one line: %q", i, o.Description)
				}
			}
		})
	}
}

func TestProjection_IsDeterministicAcrossRuns(t *testing.T) {
	for _, name := range FixtureFiles() {
		first, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
		if err != nil {
			t.Fatalf("%s: Project: %v", name, err)
		}
		second, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
		if err != nil {
			t.Fatalf("%s: Project (second run): %v", name, err)
		}
		if !reflect.DeepEqual(first, second) {
			t.Errorf("%s: two projections of the same bytes differ; the projection is not deterministic", name)
		}
	}
}

func TestProjection_EvidenceRefUsesS3SchemeForLiveOrigins(t *testing.T) {
	origin := Origin{Bucket: "kusari-trail", Key: "AWSLogs/123456789012/CloudTrail/x.json"}
	obs, err := testProjector().Project(mustFixture(t, FixtureCloudTrail), origin)
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	want := "s3://kusari-trail/AWSLogs/123456789012/CloudTrail/x.json#0"
	if obs[0].RawEvidenceRef != want {
		t.Errorf("RawEvidenceRef = %q, want %q", obs[0].RawEvidenceRef, want)
	}
	if obs[0].ID != derivedID(t, want) {
		t.Error("ID is not derived from the live evidence ref")
	}
}

// --- §2.3 negative contract ------------------------------------------------

// TestNegativeContract_PoisonedFixtureLeaksNothing is the required negative test: a
// fixture whose requestParameters and responseElements carry a session token, an
// access key ID and a secret must produce observations in which none of those values,
// and neither raw body container, appears in ANY field or label.
func TestNegativeContract_PoisonedFixtureLeaksNothing(t *testing.T) {
	raw := mustFixture(t, FixturePoisoned)
	obs, err := testProjector().Project(raw, FixtureOrigin(FixturePoisoned))
	if err != nil {
		t.Fatalf("Project: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("poisoned fixture projected 0 observations; the negative test would be vacuous")
	}

	// Every POISON- prefixed value in the fixture is a secret that must not survive
	// projection. Derived from the fixture bytes so adding a new poisoned value to the
	// fixture automatically extends the assertion.
	secrets := poisonedValues(t, string(raw))
	if len(secrets) < 8 {
		t.Fatalf("expected at least 8 poisoned values in the fixture, found %d: %v", len(secrets), secrets)
	}

	for i, o := range obs {
		for _, field := range observationStrings(o) {
			for _, secret := range secrets {
				if strings.Contains(field.value, secret) {
					t.Errorf("obs[%d] field %s leaks poisoned value %q: %q", i, field.name, secret, field.value)
				}
			}
			for _, banned := range ForbiddenSubstrings {
				if strings.Contains(field.value, banned) {
					t.Errorf("obs[%d] field %s carries banned substring %q: %q", i, field.name, banned, field.value)
				}
			}
		}
	}
}

// TestNegativeContract_RawBodyContainersNeverBecomeLabels asserts the structural half
// of the negative contract across every fixture: requestParameters and
// responseElements never appear as a label key, inside a label value, or in the
// description. A projection that stringified either container would pass the positive
// contract and fail here.
func TestNegativeContract_RawBodyContainersNeverBecomeLabels(t *testing.T) {
	for _, name := range FixtureFiles() {
		t.Run(name, func(t *testing.T) {
			obs, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
			if err != nil {
				t.Fatalf("Project: %v", err)
			}
			for i, o := range obs {
				for k, v := range o.Labels {
					for _, banned := range ForbiddenSubstrings {
						if strings.Contains(k, banned) {
							t.Errorf("obs[%d] label key %q contains banned substring %q", i, k, banned)
						}
						if strings.Contains(v, banned) {
							t.Errorf("obs[%d] label %q value contains banned substring %q: %q", i, k, banned, v)
						}
					}
					// A JSON object or array leaking into a label value is a raw body by
					// another name, whatever its key is called.
					if strings.HasPrefix(strings.TrimSpace(v), "{") || strings.HasPrefix(strings.TrimSpace(v), "[") {
						t.Errorf("obs[%d] label %q holds a serialised JSON body: %q", i, k, v)
					}
				}
				for _, banned := range ForbiddenSubstrings {
					if strings.Contains(o.Description, banned) {
						t.Errorf("obs[%d] description contains banned substring %q: %q", i, banned, o.Description)
					}
				}
			}
		})
	}
}

// TestContractDocCoversEveryEmittedKey closes the loop the other way: every key any
// fixture emits must be listed in contract_doc.go, and every key contract_doc.go lists
// as required must actually be emitted by at least one fixture. Documentation that
// drifts from the projection fails here rather than at a customer.
func TestContractDocCoversEveryEmittedKey(t *testing.T) {
	emitted := map[string]map[string]bool{}
	for _, name := range FixtureFiles() {
		obs, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
		if err != nil {
			t.Fatalf("%s: Project: %v", name, err)
		}
		for _, o := range obs {
			if emitted[o.Source] == nil {
				emitted[o.Source] = map[string]bool{}
			}
			for k := range o.Labels {
				emitted[o.Source][k] = true
			}
		}
	}

	for _, src := range []string{SourceCloudTrail, SourceIAM, SourceVPCFlow} {
		required, documented := ContractKeysFor(src)
		if len(documented) == 0 {
			t.Fatalf("source %q has no documented keys", src)
		}
		for _, k := range required {
			if !emitted[src][k] {
				t.Errorf("source %q documents %q as required but no fixture emits it", src, k)
			}
		}
		var undocumented []string
		for k := range emitted[src] {
			if !contains(documented, k) {
				undocumented = append(undocumented, k)
			}
		}
		sort.Strings(undocumented)
		if len(undocumented) > 0 {
			t.Errorf("source %q emits undocumented keys %v", src, undocumented)
		}
	}
}

// --- helpers ---------------------------------------------------------------

type namedField struct {
	name  string
	value string
}

func observationStrings(o model.Observation) []namedField {
	out := []namedField{
		{"ID", o.ID},
		{"Source", o.Source},
		{"ActorHint", o.ActorHint},
		{"RawEvidenceRef", o.RawEvidenceRef},
		{"Description", o.Description},
		{"PrincipalID", o.PrincipalID},
		{"ActorID", o.ActorID},
		{"SessionID", o.SessionID},
		{"ImpersonatedUser", o.ImpersonatedUser},
		{"Layer", string(o.Layer)},
		{"Fidelity", string(o.Fidelity)},
	}
	keys := make([]string, 0, len(o.Labels))
	for k := range o.Labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out = append(out, namedField{"label key " + k, k})
		out = append(out, namedField{"label " + k, o.Labels[k]})
	}
	return out
}

// poisonedValues extracts every POISON-prefixed token from the raw fixture so the
// negative assertion is derived from the fixture rather than duplicated from it.
func poisonedValues(t *testing.T, raw string) []string {
	t.Helper()
	var out []string
	seen := map[string]bool{}
	for _, field := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == '"' || r == ',' || r == '{' || r == '}' || r == '\n' || r == ' ' || r == ':'
	}) {
		if strings.HasPrefix(field, "POISON") && !seen[field] {
			seen[field] = true
			out = append(out, field)
		}
	}
	sort.Strings(out)
	return out
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
