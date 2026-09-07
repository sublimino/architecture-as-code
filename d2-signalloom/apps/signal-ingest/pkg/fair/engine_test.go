package fair

import (
	"math"
	"testing"
)

func TestEvaluateDeterminism(t *testing.T) {
	in := Inputs{
		AgentID:        "test-agent",
		TEF:            Triple{Min: 1, Mode: 5, Max: 20},
		Vulnerability:  Triple{Min: 0.1, Mode: 0.3, Max: 0.7},
		PrimaryLoss:    Triple{Min: 1000, Mode: 10000, Max: 100000},
		SecondaryLoss:  Triple{Min: 500, Mode: 5000, Max: 50000},
		Trials:         5000,
		Seed:           1337,
		MagnitudeModel: ModelLognormal,
	}

	a1, err := Evaluate(in)
	if err != nil {
		t.Fatalf("Evaluate failed: %v", err)
	}

	a2, err := Evaluate(in)
	if err != nil {
		t.Fatalf("Evaluate second run failed: %v", err)
	}

	if a1.ALE != a2.ALE || a1.PML != a2.PML || a1.VaR.P95 != a2.VaR.P95 {
		t.Fatalf("Non-deterministic results: a1=%+v, a2=%+v", a1, a2)
	}
}

func TestFixtureSource50AgentsParity(t *testing.T) {
	src := NewFixtureSource(50)
	svc := NewService(src)

	agentIDs := src.AgentIDs()
	if len(agentIDs) < 50 {
		t.Fatalf("expected at least 50 agents in FixtureSource, got %d", len(agentIDs))
	}

	for _, id := range agentIDs {
		ass, err := svc.Assess(id, Options{Trials: 2000, Seed: 42})
		if err != nil {
			t.Errorf("Assess failed for %s: %v", id, err)
			continue
		}
		if math.IsNaN(ass.ALE) || math.IsInf(ass.ALE, 0) || ass.ALE < 0 {
			t.Errorf("Invalid ALE for %s: %g", id, ass.ALE)
		}
		if math.IsNaN(ass.PML) || math.IsInf(ass.PML, 0) || ass.PML < 0 {
			t.Errorf("Invalid PML for %s: %g", id, ass.PML)
		}
	}
}

func TestContainedAgentReducesRisk(t *testing.T) {
	src := NewFixtureSource(50)
	svc := NewService(src)

	// Compare compromised vs compromised-contained
	var compromisedID, containedID string
	for _, id := range src.AgentIDs() {
		tel, _ := src.AgentTelemetry(id)
		if tel.CredentialState == "compromised" && !tel.Contained && compromisedID == "" {
			compromisedID = id
		}
		if tel.CredentialState == "compromised" && tel.Contained && containedID == "" {
			containedID = id
		}
	}

	if compromisedID == "" || containedID == "" {
		t.Skip("both compromised and contained profiles not found")
	}

	assComp, err := svc.Assess(compromisedID, Options{Trials: 5000, Seed: 1234})
	if err != nil {
		t.Fatalf("Assess compromised failed: %v", err)
	}

	assCont, err := svc.Assess(containedID, Options{Trials: 5000, Seed: 1234})
	if err != nil {
		t.Fatalf("Assess contained failed: %v", err)
	}

	if assCont.ALE >= assComp.ALE {
		t.Errorf("expected contained agent ALE (%g) to be lower than uncontained (%g)", assCont.ALE, assComp.ALE)
	}
	if assCont.Vulnerability.Mode >= assComp.Vulnerability.Mode {
		t.Errorf("expected contained agent Vulnerability.Mode (%g) < uncontained (%g)", assCont.Vulnerability.Mode, assComp.Vulnerability.Mode)
	}
}

func TestUnknownAgentReturnsError(t *testing.T) {
	src := NewFixtureSource(12)
	svc := NewService(src)

	_, err := svc.Assess("non-existent-agent", Options{})
	if err != ErrUnknownAgent {
		t.Errorf("expected ErrUnknownAgent, got: %v", err)
	}
}
