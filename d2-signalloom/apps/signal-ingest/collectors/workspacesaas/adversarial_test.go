package workspacesaas

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// --- 1. Malformed and Edge-Case Timestamp Tests ---

func TestNormalisedSaaSEvent_MalformedTimestamps(t *testing.T) {
	// Zero timestamp must fail validation
	zeroEvt := NormalisedSaaSEvent{
		EventID:   "evt-ts-zero",
		Provider:  ProviderGoogleWorkspace,
		Timestamp: time.Time{},
		EventType: EventVolumeSpike,
		ActorHint: "user@corp.internal",
	}
	if err := zeroEvt.Validate(); err == nil {
		t.Fatal("expected error on zero timestamp, got nil")
	}
	if _, err := zeroEvt.ToObservation(); err == nil {
		t.Fatal("expected ToObservation to fail on zero timestamp, got nil")
	}

	// Extreme past timestamp (pre-epoch) is structurally non-zero but fails timing window
	preEpochTime := time.Date(1969, 12, 31, 23, 59, 59, 0, time.UTC)
	preEpochEvt := NormalisedSaaSEvent{
		EventID:   "evt-ts-pre-epoch",
		Provider:  ProviderGoogleWorkspace,
		Timestamp: preEpochTime,
		EventType: EventVolumeSpike,
		ActorHint: "user@corp.internal",
	}
	if err := preEpochEvt.Validate(); err != nil {
		t.Fatalf("pre-epoch timestamp failed validation unexpectedly: %v", err)
	}
	obs, err := preEpochEvt.ToObservation()
	if err != nil {
		t.Fatalf("ToObservation failed on pre-epoch event: %v", err)
	}
	if obs.Timestamp.Unix() >= 0 {
		t.Errorf("expected negative unix timestamp for pre-epoch, got %d", obs.Timestamp.Unix())
	}

	// Extreme future timestamp (year 2099)
	futureTime := time.Date(2099, 1, 1, 0, 0, 0, 0, time.UTC)
	futureEvt := NormalisedSaaSEvent{
		EventID:   "evt-ts-future",
		Provider:  ProviderMicrosoft365,
		Timestamp: futureTime,
		EventType: EventVolumeSpike,
		ActorHint: "user@corp.internal",
	}
	if err := futureEvt.Validate(); err != nil {
		t.Fatalf("future timestamp failed validation unexpectedly: %v", err)
	}
	if _, err := futureEvt.ToObservation(); err != nil {
		t.Fatalf("ToObservation failed on future event: %v", err)
	}
}

// --- 2. Empty, Malformed, and Adversarial Actor ID / Hint Tests ---

func TestNormalisedSaaSEvent_ActorHintEdgeCases(t *testing.T) {
	now := time.Now().UTC()

	// Empty actor hint must be rejected by Validate() and ToObservation()
	emptyActorEvt := NormalisedSaaSEvent{
		EventID:   "evt-actor-empty",
		Provider:  ProviderGoogleWorkspace,
		Timestamp: now,
		EventType: EventVolumeSpike,
		ActorHint: "",
	}
	if err := emptyActorEvt.Validate(); err == nil {
		t.Fatal("expected error on empty ActorHint, got nil")
	}
	if _, err := emptyActorEvt.ToObservation(); err == nil {
		t.Fatal("expected ToObservation to fail on empty ActorHint, got nil")
	}

	// Adversarial input test cases: SQL injection, XSS tags, path traversal, control chars
	adversarialHints := []struct {
		name string
		hint string
	}{
		{"sql_injection", "' OR '1'='1' -- "},
		{"xss_script", "<script>alert('xss')</script>"},
		{"path_traversal", "../../etc/shadow"},
		{"control_characters", "user\r\nRole: Admin"},
		{"unicode_homoglyph", "\u0430dmin@corp.internal"}, // Cyrillic 'а'
		{"long_actor_id", "actor-super-long-" + string(make([]byte, 100))},
	}

	for _, tc := range adversarialHints {
		t.Run(tc.name, func(t *testing.T) {
			evt := NormalisedSaaSEvent{
				EventID:   "evt-adv-" + tc.name,
				Provider:  ProviderGoogleWorkspace,
				Timestamp: now,
				EventType: EventVolumeSpike,
				ActorHint: tc.hint,
			}
			if err := evt.Validate(); err != nil {
				t.Fatalf("Validate failed on adversarial hint %q: %v", tc.hint, err)
			}
			obs, err := evt.ToObservation()
			if err != nil {
				t.Fatalf("ToObservation failed on adversarial hint %q: %v", tc.hint, err)
			}
			if obs.ActorHint != tc.hint {
				t.Errorf("ActorHint corrupted: expected %q, got %q", tc.hint, obs.ActorHint)
			}
		})
	}
}

func TestWorkspaceRules_EmptyActorHint_NeverCorrelates(t *testing.T) {
	// Security invariant: even if an observation somehow had an empty actor_hint,
	// CEL workspace rules must guard against matching two empty strings.
	now := time.Now().UTC()
	obsA := model.Observation{
		ID:        "saas-empty-actor-a",
		Timestamp: now,
		Layer:     model.LayerApplicationSaaS,
		ActorHint: "",
	}
	obsB := model.Observation{
		ID:        "id-empty-actor-b",
		Timestamp: now.Add(10 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "",
	}

	ruleNames := []string{
		"workspace_volume_spike",
		"workspace_external_oauth_grant",
		"workspace_suspicious_login_egress",
	}

	for _, name := range ruleNames {
		rule := findRule(t, name)
		if compileAndEvalCEL(t, rule.CEL, obsA, obsB) {
			t.Errorf("rule %q must NEVER correlate empty actor hints", name)
		}
		if compileAndEvalCEL(t, rule.CEL, obsB, obsA) {
			t.Errorf("rule %q must NEVER correlate empty actor hints (reverse)", name)
		}
	}
}

// --- 3. Out-of-Order Event Ingestion Tests ---

func TestWorkspaceRules_OutOfOrderIngestion(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()

	// Event A: SaaS volume spike at T0
	obsSaaS := model.Observation{
		ID:             "ws-saas-ooo-001",
		Timestamp:      now,
		Layer:          model.LayerApplicationSaaS,
		Fidelity:       model.FidelitySuggestive,
		Source:         "google_workspace.audit",
		Confidence:     0.7,
		ActorHint:      "ooo-operator@corp.internal",
		RawEvidenceRef: "google_workspace://audit/volume/ws-saas-ooo-001",
		Labels: map[string]string{
			"provider":     "google_workspace",
			"event_type":   "workspace_volume_spike",
			"volume_bytes": "524288000",
		},
		Description: "workspace volume spike",
	}

	// Event B: Identity Auth event at T0 + 45s (within 300s window)
	obsAuth := model.Observation{
		ID:             "ws-id-ooo-001",
		Timestamp:      now.Add(45 * time.Second),
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityStrong,
		Source:         "idp.audit",
		Confidence:     0.9,
		ActorHint:      "ooo-operator@corp.internal",
		RawEvidenceRef: "idp://audit/auth/ws-id-ooo-001",
		Labels: map[string]string{
			"auth_mechanism": "mfa_push",
		},
		Description: "idp auth event",
	}

	// 1. Forward Ingestion Order: Ingest SaaS first, then Auth
	storeForward := store.NewMemoryStore()
	if err := storeForward.Append(ctx, []model.Observation{obsSaaS, obsAuth}); err != nil {
		t.Fatalf("storeForward.Append failed: %v", err)
	}
	engineForward, err := correlation.NewEngine(storeForward)
	if err != nil {
		t.Fatalf("NewEngine forward failed: %v", err)
	}
	actorsForward, err := engineForward.Correlate(ctx)
	if err != nil {
		t.Fatalf("Correlate forward failed: %v", err)
	}

	// 2. Reverse / Out-of-Order Ingestion: Ingest Auth first, then SaaS
	storeReverse := store.NewMemoryStore()
	if err := storeReverse.Append(ctx, []model.Observation{obsAuth, obsSaaS}); err != nil {
		t.Fatalf("storeReverse.Append failed: %v", err)
	}
	engineReverse, err := correlation.NewEngine(storeReverse)
	if err != nil {
		t.Fatalf("NewEngine reverse failed: %v", err)
	}
	actorsReverse, err := engineReverse.Correlate(ctx)
	if err != nil {
		t.Fatalf("Correlate reverse failed: %v", err)
	}

	// Verification: Both ingestion orders must resolve the actor identically
	if len(actorsForward) == 0 {
		t.Fatal("forward ingestion produced no correlated actors")
	}
	if len(actorsReverse) == 0 {
		t.Fatal("reverse ingestion produced no correlated actors")
	}
	if actorsForward[0].PrincipalID != "ooo-operator@corp.internal" {
		t.Errorf("expected principal ooo-operator@corp.internal, got %s", actorsForward[0].PrincipalID)
	}
	if actorsReverse[0].PrincipalID != "ooo-operator@corp.internal" {
		t.Errorf("expected principal ooo-operator@corp.internal in reverse order, got %s", actorsReverse[0].PrincipalID)
	}

	// 3. Negative Time Delta (Event B occurred BEFORE Event A)
	obsSaaSLater := obsSaaS
	obsSaaSLater.Timestamp = now.Add(120 * time.Second)
	obsAuthEarlier := obsAuth
	obsAuthEarlier.Timestamp = now

	rule := findRule(t, "workspace_volume_spike")
	// abs(T_saas - T_auth) = 120s <= 300s -> must fire symmetrically
	if !compileAndEvalCEL(t, rule.CEL, obsSaaSLater, obsAuthEarlier) {
		t.Errorf("workspace_volume_spike should fire when SaaS event is later than Auth event")
	}
	if !compileAndEvalCEL(t, rule.CEL, obsAuthEarlier, obsSaaSLater) {
		t.Errorf("workspace_volume_spike should fire when Auth event is earlier than SaaS event")
	}
}

// --- 4. Conflicting Signals Tests ---

func TestWorkspaceRules_ConflictingSignals(t *testing.T) {
	now := time.Now().UTC()

	// 1. Conflicting actors at the exact same timestamp
	obsAlice := model.Observation{
		ID:        "saas-alice",
		Timestamp: now,
		Layer:     model.LayerApplicationSaaS,
		ActorHint: "alice@corp.internal",
	}
	obsBob := model.Observation{
		ID:        "id-bob",
		Timestamp: now,
		Layer:     model.LayerIdentityAuth,
		ActorHint: "bob@corp.internal",
	}
	ruleVolume := findRule(t, "workspace_volume_spike")
	if compileAndEvalCEL(t, ruleVolume.CEL, obsAlice, obsBob) {
		t.Error("conflicting actors must NOT correlate")
	}

	// 2. Conflicting layers: Two SaaS events alone must NOT fire cross-layer rules
	obsSaaS2 := model.Observation{
		ID:        "saas-alice-2",
		Timestamp: now.Add(10 * time.Second),
		Layer:     model.LayerApplicationSaaS,
		ActorHint: "alice@corp.internal",
	}
	if compileAndEvalCEL(t, ruleVolume.CEL, obsAlice, obsSaaS2) {
		t.Error("two application_saas events alone must NOT fire workspace_volume_spike")
	}

	ruleOAuth := findRule(t, "workspace_external_oauth_grant")
	if compileAndEvalCEL(t, ruleOAuth.CEL, obsAlice, obsSaaS2) {
		t.Error("two application_saas events alone must NOT fire workspace_external_oauth_grant")
	}

	// 3. Conflicting timing signals: SaaS at T0, Auth at T0 + 301s (past 5m window)
	obsAuthExpired := model.Observation{
		ID:        "id-alice-expired",
		Timestamp: now.Add(301 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "alice@corp.internal",
	}
	if compileAndEvalCEL(t, ruleVolume.CEL, obsAlice, obsAuthExpired) {
		t.Error("signal past 300s window must NOT fire workspace_volume_spike")
	}

	// 4. Conflicting timing signals negative: SaaS at T0, Auth at T0 - 301s
	obsAuthPastExpired := model.Observation{
		ID:        "id-alice-past-expired",
		Timestamp: now.Add(-301 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "alice@corp.internal",
	}
	if compileAndEvalCEL(t, ruleVolume.CEL, obsAlice, obsAuthPastExpired) {
		t.Error("signal before -300s window must NOT fire workspace_volume_spike")
	}
}

// --- 5. Adversarial Payloads & Microsoft 365 Adapter Contract Tests ---

// Mock Microsoft 365 Management Activity API adapter
type mockMicrosoft365Adapter struct{}

func (m *mockMicrosoft365Adapter) Provider() ProviderType {
	return ProviderMicrosoft365
}

func (m *mockMicrosoft365Adapter) Convert(ctx context.Context, raw []byte) (*NormalisedSaaSEvent, error) {
	var m365Record struct {
		CreationTime time.Time `json:"CreationTime"`
		Id           string    `json:"Id"`
		Operation    string    `json:"Operation"`
		Workload     string    `json:"Workload"`
		UserId       string    `json:"UserId"`
		ClientIP     string    `json:"ClientIP"`
		ExtendedProperties []struct {
			Name  string `json:"Name"`
			Value string `json:"Value"`
		} `json:"ExtendedProperties"`
	}

	if err := json.Unmarshal(raw, &m365Record); err != nil {
		return nil, fmt.Errorf("malformed m365 record: %w", err)
	}
	if m365Record.Id == "" {
		return nil, errors.New("missing Id in m365 record")
	}
	if m365Record.UserId == "" {
		return nil, errors.New("missing UserId in m365 record")
	}
	if m365Record.CreationTime.IsZero() {
		return nil, errors.New("missing CreationTime in m365 record")
	}

	var evtType SaaSEventType
	switch m365Record.Operation {
	case "ConsentToApplication", "Add app role assignment to service principal":
		evtType = EventExternalOAuthGrant
	case "UserLoggedInAnomalous":
		evtType = EventSuspiciousLogin
	default:
		evtType = EventVolumeSpike
	}

	evt := &NormalisedSaaSEvent{
		EventID:   m365Record.Id,
		Provider:  ProviderMicrosoft365,
		Timestamp: m365Record.CreationTime,
		EventType: evtType,
		ActorHint: m365Record.UserId,
		Action:    m365Record.Operation,
		ClientIP:  m365Record.ClientIP,
	}

	for _, prop := range m365Record.ExtendedProperties {
		if prop.Name == "app_id" {
			evt.OAuthAppID = prop.Value
		}
	}

	return evt, nil
}

func TestSaaSAdapter_M365AndAdversarialPayloads(t *testing.T) {
	adapter := &mockMicrosoft365Adapter{}
	ctx := context.Background()

	// 1. Valid M365 OAuth consent payload
	validM365 := []byte(`{
		"CreationTime": "2026-09-10T12:00:00Z",
		"Id": "m365-audit-7788",
		"Operation": "ConsentToApplication",
		"Workload": "AzureActiveDirectory",
		"UserId": "admin-agent@corp.internal",
		"ClientIP": "198.51.100.22",
		"ExtendedProperties": [
			{"Name": "app_id", "Value": "app-guid-5555"}
		]
	}`)

	norm, err := adapter.Convert(ctx, validM365)
	if err != nil {
		t.Fatalf("Convert valid M365 failed: %v", err)
	}
	if norm.EventType != EventExternalOAuthGrant {
		t.Errorf("expected EventExternalOAuthGrant, got %s", norm.EventType)
	}
	if norm.OAuthAppID != "app-guid-5555" {
		t.Errorf("expected OAuthAppID app-guid-5555, got %s", norm.OAuthAppID)
	}
	obs, err := norm.ToObservation()
	if err != nil {
		t.Fatalf("ToObservation failed: %v", err)
	}
	if obs.Fidelity != model.FidelityStrong {
		t.Errorf("expected FidelityStrong for OAuth grant, got %s", obs.Fidelity)
	}

	// 2. Adversarial payload tests
	adversarialPayloads := []struct {
		name    string
		payload []byte
	}{
		{"truncated_json", []byte(`{"CreationTime": "2026-09-10T12:00:00Z", "Id": "123`)},
		{"empty_json", []byte(`{}`)},
		{"json_array", []byte(`[]`)},
		{"missing_user_id", []byte(`{"CreationTime": "2026-09-10T12:00:00Z", "Id": "123"}`)},
		{"missing_id", []byte(`{"CreationTime": "2026-09-10T12:00:00Z", "UserId": "u@c.i"}`)},
		{"malformed_date", []byte(`{"CreationTime": "not-a-date", "Id": "123", "UserId": "u@c.i"}`)},
		{"binary_garbage", []byte{0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF}},
	}

	for _, tc := range adversarialPayloads {
		t.Run(tc.name, func(t *testing.T) {
			_, err := adapter.Convert(ctx, tc.payload)
			if err == nil {
				t.Fatalf("expected Convert to fail on %s, but succeeded", tc.name)
			}
		})
	}
}

// --- 6. Collector Fault Injection and Lifecycle Tests ---

type faultInjectionSink struct {
	fail bool
	err  error
}

func (f *faultInjectionSink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if f.fail {
		return f.err
	}
	return nil
}

func TestCollector_FaultInjectionAndLifecycle(t *testing.T) {
	ctx := context.Background()

	// 1. Sink ingestion failure propagates properly
	sinkErr := errors.New("simulated storage failure: disk quota exceeded")
	faultSink := &faultInjectionSink{fail: true, err: sinkErr}

	col := NewCollector(ModeFixture, faultSink)
	err := col.Start(ctx)
	if err == nil {
		t.Fatal("expected Start to fail when sink fails, got nil")
	}
	if !errors.Is(err, sinkErr) {
		t.Fatalf("expected error wrapping sinkErr, got: %v", err)
	}

	// 2. Custom fixtures option WithFixtureObservations
	customSink := &mockSink{}
	customFixtures := []model.Observation{
		{
			ID:             "custom-obs-001",
			Timestamp:      time.Now().UTC(),
			Layer:          model.LayerApplicationSaaS,
			Fidelity:       model.FidelitySuggestive,
			Source:         "custom.audit",
			Confidence:     0.8,
			ActorHint:      "custom-agent@corp.internal",
			RawEvidenceRef: "custom://audit/001",
			Description:    "custom observation",
		},
	}
	colCustom := NewCollector(ModeFixture, customSink, WithFixtureObservations(customFixtures))
	if err := colCustom.Start(ctx); err != nil {
		t.Fatalf("Start with custom fixtures failed: %v", err)
	}
	if customSink.count() != 1 {
		t.Fatalf("expected 1 custom observation ingested, got %d", customSink.count())
	}
	if customSink.observations[0].ID != "custom-obs-001" {
		t.Errorf("expected ID custom-obs-001, got %s", customSink.observations[0].ID)
	}

	// 3. Idempotent Stop and Close calls
	colCustom.Stop()
	colCustom.Stop()
	colCustom.Close()

	// 4. WithAdapter option configuration
	mockAdap := &mockMicrosoft365Adapter{}
	colWithAdap := NewCollector(ModeOff, nil, WithAdapter(mockAdap))
	if colWithAdap.adapter == nil || colWithAdap.adapter.Provider() != ProviderMicrosoft365 {
		t.Errorf("expected adapter provider Microsoft365, got %v", colWithAdap.adapter)
	}
}
