// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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
	for _, name := range append(FixtureFiles(), KusariFixtureFiles()...) {
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

// TestNegativeContract_ActorAccountIDIsAlwaysTwelveDigits asserts that any emitted
// actor_account_id label is strictly a 12-digit AWS account number, never an ARN,
// never letters, and never a malformed string.
func TestNegativeContract_ActorAccountIDIsAlwaysTwelveDigits(t *testing.T) {
	for _, name := range FixtureFiles() {
		t.Run(name, func(t *testing.T) {
			obs, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
			if err != nil {
				t.Fatalf("Project: %v", err)
			}
			for i, o := range obs {
				if acct, ok := o.Labels[LabelActorAccountID]; ok {
					if len(acct) != 12 {
						t.Errorf("obs[%d] %s = %q: must be exactly 12 digits", i, LabelActorAccountID, acct)
					}
					for _, c := range acct {
						if c < '0' || c > '9' {
							t.Errorf("obs[%d] %s = %q: non-digit character %q", i, LabelActorAccountID, acct, c)
						}
					}
					if strings.Contains(acct, "arn:") || strings.Contains(acct, ":") {
						t.Errorf("obs[%d] %s leaks ARN structure: %q", i, LabelActorAccountID, acct)
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
	for _, name := range append(FixtureFiles(), KusariFixtureFiles()...) {
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

	for _, src := range []string{SourceCloudTrail, SourceIAM, SourceVPCFlow, SourceGuardDuty} {
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

func TestProjection_GzippedObjectInflatesBeforeDispatch(t *testing.T) {
	raw := mustFixture(t, FixtureCloudTrail)

	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	if _, err := gw.Write(raw); err != nil {
		t.Fatalf("gzip write: %v", err)
	}
	if err := gw.Close(); err != nil {
		t.Fatalf("gzip close: %v", err)
	}

	gzippedBytes := buf.Bytes()
	origin := Origin{
		Bucket: "kusari-logs",
		Key:    "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_sample.json.gz",
	}

	obs, err := testProjector().Project(gzippedBytes, origin)
	if err != nil {
		t.Fatalf("Project gzipped CloudTrail: %v", err)
	}
	if len(obs) != 4 {
		t.Fatalf("projected %d observations from gzipped CloudTrail, want 4", len(obs))
	}

	wantPrefix := "s3://kusari-logs/AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_sample.json.gz#"
	for i, o := range obs {
		wantRef := fmt.Sprintf("%s%d", wantPrefix, i)
		if o.RawEvidenceRef != wantRef {
			t.Errorf("obs[%d].RawEvidenceRef = %q, want %q", i, o.RawEvidenceRef, wantRef)
		}
		if o.ID != derivedID(t, wantRef) {
			t.Errorf("obs[%d].ID = %q, want %q", i, o.ID, derivedID(t, wantRef))
		}
	}

	// An invalid gzip stream under a .gz key must fail rather than silently returning nil.
	corruptOrigin := Origin{Bucket: "kusari-logs", Key: "AWSLogs/corrupt.json.gz"}
	if _, err := testProjector().Project([]byte("not-gzip-data"), corruptOrigin); err == nil {
		t.Fatal("Project with corrupt gzip payload returned nil error, want inflation failure")
	}
}

// --- §2.3 GuardDuty (EventBridge envelope) ---------------------------------

func projectGuardDutyFixture(t *testing.T, name string) model.Observation {
	t.Helper()
	obs, err := testProjector().Project(mustFixture(t, name), FixtureOrigin(name))
	if err != nil {
		t.Fatalf("Project(%s): %v", name, err)
	}
	if len(obs) != 1 {
		t.Fatalf("%s projected %d observations, want exactly 1 (one finding per envelope)", name, len(obs))
	}
	return obs[0]
}

func TestProjectGuardDuty_CarriesEveryDocumentedKey(t *testing.T) {
	got := projectGuardDutyFixture(t, KusariFixtureEventBridgeEnvelope)
	wantRef := "testdata/" + KusariFixtureEventBridgeEnvelope + "#0"

	if got.Source != SourceGuardDuty {
		t.Errorf("Source = %q, want %q", got.Source, SourceGuardDuty)
	}
	if got.RawEvidenceRef != wantRef {
		t.Errorf("RawEvidenceRef = %q, want %q", got.RawEvidenceRef, wantRef)
	}
	if got.ID != derivedID(t, wantRef) {
		t.Errorf("ID = %q, want sha256 of the evidence ref %q", got.ID, derivedID(t, wantRef))
	}
	if want := time.Date(2026, 10, 3, 12, 5, 0, 0, time.UTC); !got.Timestamp.Equal(want) {
		t.Errorf("Timestamp = %s, want %s (the envelope time, never time.Now())", got.Timestamp, want)
	}
	if got.Layer != model.LayerCloudControlPlane {
		t.Errorf("Layer = %q, want %q", got.Layer, model.LayerCloudControlPlane)
	}
	if got.Fidelity != model.FidelityStrong {
		t.Errorf("Fidelity = %q, want %q", got.Fidelity, model.FidelityStrong)
	}
	if got.Confidence != 0.9 {
		t.Errorf("Confidence = %v, want 0.9", got.Confidence)
	}
	// The envelope names a userName, not an ARN. Fabricating an ARN from it would
	// make the §2.3 actor row lie and the pseudonym match no real principal.
	if got.ActorHint != "" {
		t.Errorf("ActorHint = %q, want empty (a GuardDuty finding carries no principal ARN)", got.ActorHint)
	}

	want := map[string]string{
		LabelTenantID:     "kusari",
		LabelProvider:     "aws",
		LabelAWSAccountID: "123456789012",
		LabelAWSRegion:    "us-east-1",
		LabelEventSource:  "aws.guardduty",
		LabelEventName:    "UnauthorizedAccess:IAMUser/MaliciousIPCaller.Custom",
		LabelSeverity:     "8",
		LabelResourceType: "AccessKey",
	}
	if !reflect.DeepEqual(got.Labels, want) {
		t.Errorf("Labels mismatch\n got: %v\nwant: %v", got.Labels, want)
	}
	if want := "guardduty UnauthorizedAccess:IAMUser/MaliciousIPCaller.Custom on AccessKey"; got.Description != want {
		t.Errorf("Description = %q, want %q", got.Description, want)
	}

	required, documented := ContractKeysFor(SourceGuardDuty)
	if len(required) == 0 {
		t.Fatalf("ContractKeysFor(%q) documents nothing", SourceGuardDuty)
	}
	for _, k := range required {
		if got.Labels[k] == "" {
			t.Errorf("missing required label %q", k)
		}
	}
	for k := range got.Labels {
		if !contains(documented, k) {
			t.Errorf("undocumented label %q", k)
		}
	}
	if err := got.Validate(); err != nil {
		t.Errorf("fails model.Observation.Validate: %v", err)
	}
}

// The low-severity negative is an EC2 finding whose resource carries an ENI id,
// which is the one resource identifier the projection admits as resource_name.
func TestProjectGuardDuty_LowSeverityInstanceFindingNamesItsENI(t *testing.T) {
	got := projectGuardDutyFixture(t, KusariFixtureGuardDutyLowSeverity)
	if got.Labels[LabelSeverity] != "2" {
		t.Errorf("severity = %q, want \"2\"", got.Labels[LabelSeverity])
	}
	if got.Labels[LabelResourceType] != "Instance" {
		t.Errorf("resource_type = %q, want Instance", got.Labels[LabelResourceType])
	}
	if got.Labels[LabelResourceName] != "eni-0a1b2c3d4e5f60789" {
		t.Errorf("resource_name = %q, want the ENI id eni-0a1b2c3d4e5f60789", got.Labels[LabelResourceName])
	}
	if strings.Contains(got.Description, "eni-") {
		t.Errorf("description repeats the resource name: %q", got.Description)
	}
}

// GuardDuty severity is a float on the wire (7.5, 8.9). The label is the integer
// floor, so one representation answers int(obs.labels.severity) in CEL without
// a parse error and the GuardDuty bands (low < 4, medium < 7, high >= 7) are
// preserved: 7.5 is high, 6.9 is medium.
func TestProjectGuardDuty_SeverityIsTheIntegerFloor(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want string
	}{
		{"7", "7"}, {"7.0", "7"}, {"7.5", "7"}, {"6.9", "6"}, {"8.9", "8"}, {"2", "2"}, {"0.1", "0"},
	} {
		body := []byte(`{"detail-type":"GuardDuty Finding","source":"aws.guardduty","account":"123456789012","time":"2026-10-03T12:05:00Z","region":"us-east-1",` +
			`"detail":{"accountId":"123456789012","region":"us-east-1","type":"Recon:EC2/PortProbeUnprotectedPort","severity":` + tc.raw + `,"resource":{"resourceType":"Instance"}}}`)
		obs, err := testProjector().Project(body, Origin{Key: "gd.json"})
		if err != nil {
			t.Fatalf("severity %s: Project: %v", tc.raw, err)
		}
		if got := obs[0].Labels[LabelSeverity]; got != tc.want {
			t.Errorf("severity %s projected to %q, want %q", tc.raw, got, tc.want)
		}
	}
}

func TestProjectGuardDuty_MissingSeverityOrTypeIsAnError(t *testing.T) {
	for name, detail := range map[string]string{
		"no severity": `{"type":"Recon:EC2/PortProbeUnprotectedPort","resource":{"resourceType":"Instance"}}`,
		"no type":     `{"severity":5,"resource":{"resourceType":"Instance"}}`,
	} {
		body := []byte(`{"detail-type":"GuardDuty Finding","source":"aws.guardduty","account":"123456789012","time":"2026-10-03T12:05:00Z","region":"us-east-1","detail":` + detail + `}`)
		if _, err := testProjector().Project(body, Origin{Key: "gd.json"}); err == nil {
			t.Errorf("%s: projected without error; a finding the rule cannot classify must be a projection_failure", name)
		}
	}
}

// An ENI id is the only resource_name a finding may carry, and only in its own
// shape: anything ARN-like, or anything that is not an eni- id, is dropped rather
// than labelled.
func TestProjectGuardDuty_ResourceNameIsOnlyAnARNFreeENIID(t *testing.T) {
	for _, eni := range []string{"arn:aws:ec2:us-east-1:123456789012:network-interface/eni-0a1b", "i-0123456789abcdef0", "eni-../../x"} {
		body := []byte(`{"detail-type":"GuardDuty Finding","source":"aws.guardduty","account":"123456789012","time":"2026-10-03T12:05:00Z","region":"us-east-1",` +
			`"detail":{"type":"Recon:EC2/PortProbeUnprotectedPort","severity":2,"resource":{"resourceType":"Instance","instanceDetails":{"networkInterfaces":[{"networkInterfaceId":"` + eni + `"}]}}}}`)
		obs, err := testProjector().Project(body, Origin{Key: "gd.json"})
		if err != nil {
			t.Fatalf("Project: %v", err)
		}
		if v, ok := obs[0].Labels[LabelResourceName]; ok {
			t.Errorf("networkInterfaceId %q became resource_name %q", eni, v)
		}
	}
}

// TestNegativeContract_GuardDutyDetailNeverBecomesALabel: the finding's detail
// carries an access key id, a principal userName and a free-text title. None of it
// may reach any field of the observation. The banned values are derived from the
// fixture bytes, so a value added to the fixture extends the assertion.
func TestNegativeContract_GuardDutyDetailNeverBecomesALabel(t *testing.T) {
	raw := mustFixture(t, KusariFixtureEventBridgeEnvelope)
	got := projectGuardDutyFixture(t, KusariFixtureEventBridgeEnvelope)

	var env struct {
		Detail struct {
			Title    string                     `json:"title"`
			Service  map[string]json.RawMessage `json:"service"`
			Resource map[string]json.RawMessage `json:"resource"`
		} `json:"detail"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatalf("decoding fixture: %v", err)
	}
	banned := []string{env.Detail.Title}
	for k, v := range env.Detail.Resource {
		if k == "resourceType" {
			continue
		}
		banned = append(banned, scalarStrings(v, map[string]bool{"userType": true})...)
	}
	var detector string
	_ = json.Unmarshal(env.Detail.Service["detectorId"], &detector)
	banned = append(banned, detector)

	var sawAccessKey bool
	for _, b := range banned {
		if strings.HasPrefix(b, "POISON") {
			sawAccessKey = true
		}
	}
	if !sawAccessKey || len(banned) < 4 {
		t.Fatalf("the fixture no longer carries a POISON access key id and a userName (%v); the negative test would be vacuous", banned)
	}

	for _, field := range observationStrings(got) {
		for _, b := range banned {
			if b != "" && strings.Contains(field.value, b) {
				t.Errorf("field %s leaks detail value %q: %q", field.name, b, field.value)
			}
		}
		for _, f := range ForbiddenSubstrings {
			if strings.Contains(field.value, f) {
				t.Errorf("field %s carries banned substring %q: %q", field.name, f, field.value)
			}
		}
		if v := strings.TrimSpace(field.value); strings.HasPrefix(v, "{") || strings.HasPrefix(v, "[") {
			t.Errorf("field %s holds a serialised JSON body: %q", field.name, field.value)
		}
	}
}

// TestProject_UnrecognisedEnvelopeIsAnErrorNotASilentZero: an object that is
// neither a CloudTrail Records[] file nor a GuardDuty finding must fail projection,
// so the collector stores a projection_failure instead of reporting success with
// zero rows. An empty Records[] file is a real CloudTrail object and stays a zero.
func TestProject_UnrecognisedEnvelopeIsAnErrorNotASilentZero(t *testing.T) {
	for name, body := range map[string]string{
		"empty object":            `{}`,
		"other EventBridge event": `{"version":"0","detail-type":"EC2 Instance State-change Notification","source":"aws.ec2","detail":{"state":"running"}}`,
		"null Records":            `{"Records":null}`,
	} {
		obs, err := testProjector().Project([]byte(body), Origin{Key: "x.json"})
		if !errors.Is(err, ErrUnrecognisedEnvelope) {
			t.Errorf("%s: err = %v (%d observations), want ErrUnrecognisedEnvelope", name, err, len(obs))
		}
	}
	obs, err := testProjector().Project([]byte(`{"Records":[]}`), Origin{Key: "x.json"})
	if err != nil || len(obs) != 0 {
		t.Errorf("an empty CloudTrail Records[] file: got %d observations, err %v; want 0, nil", len(obs), err)
	}
}

// scalarStrings returns every string scalar inside a JSON value, skipping the
// values of the named keys.
func scalarStrings(raw json.RawMessage, skip map[string]bool) []string {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil
	}
	var out []string
	var walk func(any)
	walk = func(x any) {
		switch t := x.(type) {
		case string:
			out = append(out, t)
		case []any:
			for _, e := range t {
				walk(e)
			}
		case map[string]any:
			for k, e := range t {
				if !skip[k] {
					walk(e)
				}
			}
		}
	}
	walk(v)
	return out
}
