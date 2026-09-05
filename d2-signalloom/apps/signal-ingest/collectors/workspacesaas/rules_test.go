package workspacesaas

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
)

func compileAndEvalCEL(t *testing.T, expr string, a, b model.Observation) bool {
	t.Helper()
	env, err := cel.NewEnv(
		cel.Variable("a", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("b", cel.MapType(cel.StringType, cel.DynType)),
		cel.Function("abs",
			cel.Overload("abs_int", []*cel.Type{cel.IntType}, cel.IntType,
				cel.UnaryBinding(func(val ref.Val) ref.Val {
					v := val.Value().(int64)
					if v < 0 {
						return types.Int(-v)
					}
					return types.Int(v)
				}),
			),
		),
	)
	if err != nil {
		t.Fatalf("cel.NewEnv failed: %v", err)
	}

	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		t.Fatalf("cel.Compile failed: %v", issues.Err())
	}

	prg, err := env.Program(ast)
	if err != nil {
		t.Fatalf("env.Program failed: %v", err)
	}

	aMap := map[string]any{
		"id":         a.ID,
		"timestamp":  a.Timestamp.Unix(),
		"layer":      string(a.Layer),
		"fidelity":   string(a.Fidelity),
		"source":     a.Source,
		"confidence": a.Confidence,
		"actor_hint": a.ActorHint,
	}
	bMap := map[string]any{
		"id":         b.ID,
		"timestamp":  b.Timestamp.Unix(),
		"layer":      string(b.Layer),
		"fidelity":   string(b.Fidelity),
		"source":     b.Source,
		"confidence": b.Confidence,
		"actor_hint": b.ActorHint,
	}

	out, _, err := prg.Eval(map[string]any{"a": aMap, "b": bMap})
	if err != nil {
		t.Fatalf("prg.Eval failed: %v", err)
	}
	return out.Value() == true
}

func findRule(t *testing.T, name string) correlation.Rule {
	t.Helper()
	for _, r := range correlation.DefaultRules() {
		if r.Name == name {
			return r
		}
	}
	t.Fatalf("rule %q not found in DefaultRules()", name)
	return correlation.Rule{}
}

func TestWorkspaceRule_VolumeSpike_Fires(t *testing.T) {
	rule := findRule(t, "workspace_volume_spike")
	now := time.Now().UTC()
	fixtures := DefaultWorkspaceFixtures(now)

	// ws-saas-volume-001 (application_saas) and ws-id-auth-volume-001 (identity_authorization)
	var obsA, obsB model.Observation
	for _, obs := range fixtures {
		if obs.ID == "ws-saas-volume-001" {
			obsA = obs
		}
		if obs.ID == "ws-id-auth-volume-001" {
			obsB = obs
		}
	}

	if obsA.ID == "" || obsB.ID == "" {
		t.Fatal("volume spike fixtures not found")
	}

	// 1. Forward evaluation (a, b)
	if !compileAndEvalCEL(t, rule.CEL, obsA, obsB) {
		t.Errorf("workspace_volume_spike should fire for forward pair (obsA, obsB)")
	}

	// 2. Symmetric reverse evaluation (b, a)
	if !compileAndEvalCEL(t, rule.CEL, obsB, obsA) {
		t.Errorf("workspace_volume_spike should fire for reverse pair (obsB, obsA)")
	}
}

func TestWorkspaceRule_ExternalOAuthGrant_Fires(t *testing.T) {
	rule := findRule(t, "workspace_external_oauth_grant")
	now := time.Now().UTC()
	fixtures := DefaultWorkspaceFixtures(now)

	// ws-saas-oauth-001 (application_saas) and ws-id-auth-oauth-001 (identity_authorization)
	var obsA, obsB model.Observation
	for _, obs := range fixtures {
		if obs.ID == "ws-saas-oauth-001" {
			obsA = obs
		}
		if obs.ID == "ws-id-auth-oauth-001" {
			obsB = obs
		}
	}

	if obsA.ID == "" || obsB.ID == "" {
		t.Fatal("oauth grant fixtures not found")
	}

	// 1. Forward evaluation
	if !compileAndEvalCEL(t, rule.CEL, obsA, obsB) {
		t.Errorf("workspace_external_oauth_grant should fire for forward pair (obsA, obsB)")
	}

	// 2. Symmetric reverse evaluation
	if !compileAndEvalCEL(t, rule.CEL, obsB, obsA) {
		t.Errorf("workspace_external_oauth_grant should fire for reverse pair (obsB, obsA)")
	}
}

func TestWorkspaceRule_SuspiciousLoginEgress_Fires(t *testing.T) {
	rule := findRule(t, "workspace_suspicious_login_egress")
	now := time.Now().UTC()
	fixtures := DefaultWorkspaceFixtures(now)

	// ws-id-auth-login-001 (identity_authorization) and ws-net-egress-login-001 (network_egress)
	var obsA, obsB model.Observation
	for _, obs := range fixtures {
		if obs.ID == "ws-id-auth-login-001" {
			obsA = obs
		}
		if obs.ID == "ws-net-egress-login-001" {
			obsB = obs
		}
	}

	if obsA.ID == "" || obsB.ID == "" {
		t.Fatal("suspicious login fixtures not found")
	}

	// 1. Forward evaluation
	if !compileAndEvalCEL(t, rule.CEL, obsA, obsB) {
		t.Errorf("workspace_suspicious_login_egress should fire for forward pair (obsA, obsB)")
	}

	// 2. Symmetric reverse evaluation
	if !compileAndEvalCEL(t, rule.CEL, obsB, obsA) {
		t.Errorf("workspace_suspicious_login_egress should fire for reverse pair (obsB, obsA)")
	}
}

func TestWorkspaceRules_NegativeMismatchedActorHint_DoesNotFire(t *testing.T) {
	rules := []string{
		"workspace_volume_spike",
		"workspace_external_oauth_grant",
		"workspace_suspicious_login_egress",
	}

	now := time.Now().UTC()

	// Pair with mismatched actor hints
	obsA := model.Observation{
		ID:        "neg-saas-001",
		Timestamp: now,
		Layer:     model.LayerApplicationSaaS,
		ActorHint: "actor-alice@corp.internal",
	}
	obsB := model.Observation{
		ID:        "neg-id-001",
		Timestamp: now.Add(30 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "actor-bob@corp.internal",
	}
	obsC := model.Observation{
		ID:        "neg-net-001",
		Timestamp: now.Add(45 * time.Second),
		Layer:     model.LayerNetworkEgress,
		ActorHint: "actor-charlie@corp.internal",
	}

	for _, ruleName := range rules {
		rule := findRule(t, ruleName)

		if compileAndEvalCEL(t, rule.CEL, obsA, obsB) {
			t.Errorf("rule %q should NOT fire on mismatched actor hints (obsA, obsB)", ruleName)
		}
		if compileAndEvalCEL(t, rule.CEL, obsB, obsC) {
			t.Errorf("rule %q should NOT fire on mismatched actor hints (obsB, obsC)", ruleName)
		}
		if compileAndEvalCEL(t, rule.CEL, obsA, obsC) {
			t.Errorf("rule %q should NOT fire on mismatched actor hints (obsA, obsC)", ruleName)
		}
	}
}

func TestWorkspaceRule_VolumeSpike_TimingBoundary(t *testing.T) {
	rule := findRule(t, "workspace_volume_spike")
	now := time.Now().UTC()

	saasObs := model.Observation{
		ID:        "timing-saas-001",
		Timestamp: now,
		Layer:     model.LayerApplicationSaaS,
		ActorHint: "target-actor@corp.internal",
	}

	// 1. Inside 300s window (delta = 299s) -> MUST FIRE
	insideObs := model.Observation{
		ID:        "timing-id-inside",
		Timestamp: now.Add(299 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "target-actor@corp.internal",
	}
	if !compileAndEvalCEL(t, rule.CEL, saasObs, insideObs) {
		t.Errorf("workspace_volume_spike should fire at delta = 299s (inside 300s window)")
	}

	// 2. Exactly at 300s window (delta = 300s) -> MUST FIRE
	exactObs := model.Observation{
		ID:        "timing-id-exact",
		Timestamp: now.Add(300 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "target-actor@corp.internal",
	}
	if !compileAndEvalCEL(t, rule.CEL, saasObs, exactObs) {
		t.Errorf("workspace_volume_spike should fire at delta = 300s (boundary)")
	}

	// 3. Outside 300s window (delta = 301s) -> MUST NOT FIRE
	outsideObs := model.Observation{
		ID:        "timing-id-outside",
		Timestamp: now.Add(301 * time.Second),
		Layer:     model.LayerIdentityAuth,
		ActorHint: "target-actor@corp.internal",
	}
	if compileAndEvalCEL(t, rule.CEL, saasObs, outsideObs) {
		t.Errorf("workspace_volume_spike must NOT fire at delta = 301s (outside 300s window)")
	}
}

func TestWorkspaceRules_EngineCorrelationEndToEnd(t *testing.T) {
	ctx := context.Background()
	memStore := store.NewMemoryStore()

	now := time.Now().UTC()
	fixtures := DefaultWorkspaceFixtures(now)

	if err := memStore.Append(ctx, fixtures); err != nil {
		t.Fatalf("memStore.Append failed: %v", err)
	}

	engine, err := correlation.NewEngine(memStore)
	if err != nil {
		t.Fatalf("NewEngine failed: %v", err)
	}

	actors, err := engine.Correlate(ctx)
	if err != nil {
		t.Fatalf("Correlate failed: %v", err)
	}

	if len(actors) < 3 {
		t.Fatalf("expected at least 3 correlated actors from workspace fixtures, got %d", len(actors))
	}

	// Verify all three distinct actor hints are represented
	expectedActors := map[string]bool{
		"workspace-analyst-sa@corp.internal":     false,
		"m365-developer-agent@corp.internal":      false,
		"suspicious-agent-operator@corp.internal": false,
	}

	for _, a := range actors {
		for k := range expectedActors {
			if a.PrincipalID == k {
				expectedActors[k] = true
			}
		}
	}

	for k, found := range expectedActors {
		if !found {
			t.Errorf("expected actor %q to be resolved by correlation engine", k)
		}
	}
}
