package collectors

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestSeedAll_ProducesObservations(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("SeedAll should produce observations")
	}
}

func TestSeedAll_CoversAllInScopeLayers(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	layers := make(map[model.Layer]bool)
	for _, o := range obs {
		layers[o.Layer] = true
	}
	for _, l := range model.InScopeLayers() {
		if !layers[l] {
			t.Errorf("missing layer in fixtures: %s", l)
		}
	}
}

func TestFixtures_HaveValidFields(t *testing.T) {
	obs := SeedAll(time.Now().UTC())
	for _, o := range obs {
		if o.ID == "" {
			t.Error("observation missing ID")
		}
		if o.Timestamp.IsZero() {
			t.Errorf("observation %s has zero timestamp", o.ID)
		}
		if !o.Layer.IsValid() {
			t.Errorf("observation %s has invalid layer: %s", o.ID, o.Layer)
		}
		if o.Source == "" {
			t.Errorf("observation %s missing source", o.ID)
		}
		if o.Description == "" {
			t.Errorf("observation %s missing description", o.ID)
		}
	}
}

func TestScheduledJobFixtures_NoActorHint(t *testing.T) {
	obs := ScheduledJobFixtures(time.Now().UTC())
	for _, o := range obs {
		if o.ActorHint != "" {
			t.Errorf("scheduled job fixture %s should have empty actor_hint, got %q", o.ID, o.ActorHint)
		}
	}
}

func TestNetworkEgressFixtures_NonEmpty(t *testing.T) {
	obs := NetworkEgressFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("network egress fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerNetworkEgress {
			t.Errorf("wrong layer: want %s, got %s", model.LayerNetworkEgress, o.Layer)
		}
	}
}

func TestIdentityAuthFixtures_NonEmpty(t *testing.T) {
	obs := IdentityAuthFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("identity auth fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerIdentityAuth {
			t.Errorf("wrong layer: want %s, got %s", model.LayerIdentityAuth, o.Layer)
		}
	}
}

func TestApplicationSaaSFixtures_NonEmpty(t *testing.T) {
	obs := ApplicationSaaSFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("application SaaS fixtures should not be empty")
	}
}

func TestEndpointHostFixtures_NonEmpty(t *testing.T) {
	obs := EndpointHostFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("endpoint host fixtures should not be empty")
	}
}

func TestBehaviouralFixtures_NonEmpty(t *testing.T) {
	obs := BehaviouralFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("behavioural fixtures should not be empty")
	}
}
func TestGCPAuditFixtures_NonEmpty(t *testing.T) {
	obs := GCPAuditFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("gcp audit fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerCloudControlPlane {
			t.Errorf("wrong layer: want %s, got %s", model.LayerCloudControlPlane, o.Layer)
		}
	}
}

func TestWorkspaceSaaSFixtures_Validation(t *testing.T) {
	obs := WorkspaceSaaSFixtures(time.Now().UTC())
	if len(obs) < 6 {
		t.Fatalf("expected at least 6 workspace fixtures (3 pairs), got %d", len(obs))
	}
	for _, o := range obs {
		if err := o.Validate(); err != nil {
			t.Errorf("fixture %s failed validation: %v", o.ID, err)
		}
		if o.ActorHint == "" {
			t.Errorf("fixture %s must have non-empty actor_hint for workspace correlation", o.ID)
		}
	}
}

func TestBaoAuditFixtures_NonEmpty(t *testing.T) {
	obs := BaoAuditFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("baoaudit fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerIdentityAuth {
			t.Errorf("wrong layer: want %s, got %s", model.LayerIdentityAuth, o.Layer)
		}
		if o.PrincipalID == "" {
			t.Errorf("fixture %s missing PrincipalID", o.ID)
		}
		if o.Labels["sa_principal"] == "" || o.Labels["spiffe_id"] == "" {
			t.Errorf("fixture %s missing SA->SPIFFE join labels: %+v", o.ID, o.Labels)
		}
	}
}

func TestKAgentFixtures_NonEmpty(t *testing.T) {
	obs := KAgentFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("kagent fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerIdentityAuth {
			t.Errorf("wrong layer: want %s, got %s", model.LayerIdentityAuth, o.Layer)
		}
		if o.Labels["framework"] != "kagent" {
			t.Errorf("expected framework label 'kagent', got %s", o.Labels["framework"])
		}
		if o.Labels["tool_name"] == "" {
			t.Errorf("expected non-empty tool_name in fixture")
		}
	}
}

func TestSPIREIssuanceFixtures_NonEmpty(t *testing.T) {
	obs := SPIREIssuanceFixtures(time.Now().UTC())
	if len(obs) == 0 {
		t.Fatal("spirea fixtures should not be empty")
	}
	for _, o := range obs {
		if o.Layer != model.LayerIdentityAuth {
			t.Errorf("wrong layer: want %s, got %s", model.LayerIdentityAuth, o.Layer)
		}
		if o.PrincipalID == "" {
			t.Errorf("fixture %s missing PrincipalID", o.ID)
		}
		if o.Labels["sa_principal"] == "" || o.Labels["spiffe_id"] == "" {
			t.Errorf("fixture %s missing SA->SPIFFE join labels: %+v", o.ID, o.Labels)
		}
	}
}

func TestCollectorFalsificationTwinFixtures_ValidityAndIntegrity(t *testing.T) {
	baseTime := time.Now().UTC()

	// GCPAudit Twins
	gcpAccept := GCPAuditAcceptTwinLogEntry(baseTime)
	if gcpAccept == nil || gcpAccept.InsertID == "" || gcpAccept.ProtoPayload == nil {
		t.Errorf("invalid GCPAuditAcceptTwinLogEntry")
	}
	if len(GCPAuditAcceptTwinPayload(baseTime)) == 0 {
		t.Errorf("empty GCPAuditAcceptTwinPayload")
	}
	if len(GCPAuditRejectTwinPayload()) == 0 {
		t.Errorf("empty GCPAuditRejectTwinPayload")
	}

	// BaoAudit Twins
	baoAccept := BaoAuditAcceptTwinEvent(baseTime)
	if baoAccept == nil || baoAccept.Request == nil || baoAccept.Auth == nil {
		t.Errorf("invalid BaoAuditAcceptTwinEvent")
	}
	if len(BaoAuditAcceptTwinPayload(baseTime)) == 0 {
		t.Errorf("empty BaoAuditAcceptTwinPayload")
	}
	if len(BaoAuditRejectTwinPayload()) == 0 {
		t.Errorf("empty BaoAuditRejectTwinPayload")
	}

	// SPIREA Twins
	spireAccept := SPIREIssuanceAcceptTwinEvent(baseTime)
	if spireAccept == nil || spireAccept.SPIFFEID == "" {
		t.Errorf("invalid SPIREIssuanceAcceptTwinEvent")
	}
	spireReject := SPIREIssuanceRejectTwinEvent(baseTime)
	if spireReject == nil || spireReject.SPIFFEID != "" {
		t.Errorf("SPIREIssuanceRejectTwinEvent must have empty SPIFFEID")
	}

	// NetEBPF Twins
	netAccept := NetEBPFAcceptTwinEvent(baseTime)
	if netAccept == nil || netAccept.DstIP == "" || netAccept.BytesSent == 0 {
		t.Errorf("invalid NetEBPFAcceptTwinEvent")
	}
	if NetEBPFRejectTwinEvent() != nil {
		t.Errorf("NetEBPFRejectTwinEvent must be nil")
	}
	netUnder := NetEBPFUnderReportTwinEvent(baseTime)
	if netUnder == nil || netUnder.SeqNum <= 1 {
		t.Errorf("NetEBPFUnderReportTwinEvent must contain sequence jump")
	}

	// K8sAudit Twins
	k8sAccept := K8sAuditAcceptTwinEventList(baseTime)
	if k8sAccept == nil || len(k8sAccept.Items) == 0 {
		t.Errorf("invalid K8sAuditAcceptTwinEventList")
	}
	if len(K8sAuditAcceptTwinPayload(baseTime)) == 0 {
		t.Errorf("empty K8sAuditAcceptTwinPayload")
	}
	if len(K8sAuditRejectTwinPayload()) == 0 {
		t.Errorf("empty K8sAuditRejectTwinPayload")
	}

	// KAgent Twins
	kagentAccept := KAgentAcceptTwinSpan(baseTime)
	if kagentAccept.SpanID == "" || len(kagentAccept.Attributes) == 0 {
		t.Errorf("invalid KAgentAcceptTwinSpan")
	}
	kagentReject := KAgentRejectTwinSpan()
	if kagentReject.SpanID != "" {
		t.Errorf("KAgentRejectTwinSpan must have empty SpanID")
	}

	// WorkspaceSaaS Twins
	wsAccept := WorkspaceSaaSAcceptTwinObservation(baseTime)
	if err := wsAccept.Validate(); err != nil {
		t.Errorf("WorkspaceSaaSAcceptTwinObservation failed validation: %v", err)
	}
	wsReject := WorkspaceSaaSRejectTwinObservation()
	if err := wsReject.Validate(); err == nil {
		t.Errorf("WorkspaceSaaSRejectTwinObservation must fail validation")
	}

	// Fixture Twins
	fixAccept := FixtureAcceptTwinObservations(baseTime)
	if len(fixAccept) == 0 {
		t.Errorf("empty FixtureAcceptTwinObservations")
	}
	fixReject := FixtureRejectTwinObservations()
	if len(fixReject) == 0 || fixReject[0].ID != "" {
		t.Errorf("invalid FixtureRejectTwinObservations")
	}
}

