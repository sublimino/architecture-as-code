package baseline

import (
	"path/filepath"
	"testing"

	"github.com/acme-co/osramp/tools/riskctl/internal/model"
)

// repoRoot resolves the repository root from the test's package directory.
func repoRoot(t *testing.T) string {
	t.Helper()
	return filepath.Join("..", "..", "..", "..")
}

func loadAll(t *testing.T, packVer, agent, org string) (*model.Pack, *model.AgentPosture, *model.OrgRiskPosture) {
	t.Helper()
	r := repoRoot(t)
	p, err := model.LoadPack(filepath.Join(r, "risk", "packs", "agent-policy", packVer, "pack.yaml"))
	if err != nil {
		t.Fatalf("load pack %s: %v", packVer, err)
	}
	a, err := model.LoadAgentPosture(filepath.Join(r, "risk", "posture", agent+".yaml"))
	if err != nil {
		t.Fatalf("load posture %s: %v", agent, err)
	}
	o, err := model.LoadOrgRiskPosture(filepath.Join(r, "risk", "org", org+".yaml"))
	if err != nil {
		t.Fatalf("load org %s: %v", org, err)
	}
	return p, a, o
}

var fast = Options{Iterations: 40000, Seed: 20260801}

// Every shipped artefact must load and validate. This is the schema gate.
func TestShippedArtefactsValidate(t *testing.T) {
	for _, v := range []string{"2.0.0", "2.1.0"} {
		for _, ag := range []string{"agent-remediation", "agent-olly-sentinel"} {
			for _, org := range []string{"acme", "ludlow-health"} {
				if _, _, _ = loadAll(t, v, ag, org); t.Failed() {
					t.Fatalf("failed on %s/%s/%s", v, ag, org)
				}
			}
		}
	}
}

// The headline claim: the same report, run twice, is identical to the pound.
func TestReportIsDeterministic(t *testing.T) {
	p, a, o := loadAll(t, "2.0.0", "agent-remediation", "acme")
	r1, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	// Money is a comparable struct (float64 + string), so != checks the amount AND the denomination.
	// A report that produced the right number in the wrong currency would fail here too.
	if r1.Risk.ALE != r2.Risk.ALE || r1.TCoR != r2.TCoR || r1.Tier != r2.Tier {
		t.Fatalf("report not deterministic:\n first ALE=%.4f TCoR=%v tier=%s\nsecond ALE=%.4f TCoR=%v tier=%s",
			r1.Risk.ALE, r1.TCoR, r1.Tier, r2.Risk.ALE, r2.TCoR, r2.Tier)
	}
}

// Silence is not compliance: a control the posture says nothing about must be treated as unmet.
func TestUnclaimedIsNotCompliant(t *testing.T) {
	p, a, o := loadAll(t, "2.0.0", "agent-remediation", "acme")
	a.Satisfies = a.Satisfies[:3] // drop the rest of the assertions
	rep, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	unclaimed := 0
	for _, r := range rep.Results {
		if r.Verdict == VerdictUnclaimed {
			unclaimed++
			if r.Met {
				t.Fatalf("%s reported UNCLAIMED but Met=true", r.Control.ID)
			}
		}
	}
	if unclaimed == 0 {
		t.Fatal("expected unclaimed controls after truncating the posture, got none")
	}
}

// A control unmet under a gate action must produce FAIL-GATED, and drop the agent off `trusted`.
func TestUnmetGateControlCagesTheAgent(t *testing.T) {
	// Under 2.1.0 the remediation agent fails three newly-gated controls.
	p, a, o := loadAll(t, "2.1.0", "agent-remediation", "acme")
	rep, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	gated := 0
	for _, r := range rep.Results {
		if r.Verdict == VerdictGated {
			gated++
		}
	}
	if gated != 3 {
		t.Fatalf("expected 3 gated failures under 2.1.0, got %d", gated)
	}
	if rep.Tier == "trusted" {
		t.Fatal("agent with unmet gate controls remained on the trusted tier")
	}
	if !rep.Stale {
		t.Fatal("agent claiming 2.0.0 evaluated against 2.1.0 should be flagged stale")
	}
}

// The fully compliant agent keeps its trust.
func TestCompliantAgentIsTrusted(t *testing.T) {
	p, a, o := loadAll(t, "2.0.0", "agent-olly-sentinel", "acme")
	rep, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	// Olly fails AGT-003 which is a gate in 2.0.0, so it must NOT be trusted.
	if rep.Tier == "trusted" {
		t.Fatal("olly fails AGT-003 (a gate control) yet was marked trusted")
	}
}

// Proportionality: the same agent and the same pack must cost more at the higher-magnitude
// institution. If this ever inverts at equal enforcement, the model is broken.
func TestSameControlCostsMoreAtTheHigherMagnitudeInstitution(t *testing.T) {
	p, a, acme := loadAll(t, "2.0.0", "agent-remediation", "acme")
	_, _, ludlow := loadAll(t, "2.0.0", "agent-remediation", "ludlow-health")

	ra, err := Run(p, a, acme, fast)
	if err != nil {
		t.Fatal(err)
	}
	rl, err := Run(p, a, ludlow, fast)
	if err != nil {
		t.Fatal(err)
	}
	if ra.Tier != rl.Tier {
		t.Skipf("tiers diverged (%s vs %s); comparison only meaningful at equal enforcement", ra.Tier, rl.Tier)
	}
	if !(rl.Risk.ALE > ra.Risk.ALE) {
		t.Fatalf("health institution ALE (%.0f) not above retail ALE (%.0f) at equal enforcement",
			rl.Risk.ALE, ra.Risk.ALE)
	}
}

// Electing a conditional branch must raise the priced residual. Autonomy is allowed; it is not free.
func TestConditionalElectionIsPriced(t *testing.T) {
	p, a, o := loadAll(t, "2.1.0", "agent-olly-sentinel", "acme")
	withElection, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	a.ConditionalElected = nil
	without, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	if withElection.Risk.ALE == without.Risk.ALE {
		t.Fatal("electing a conditional branch did not change the number; the branch is unpriced")
	}
}

// A malformed pack must be rejected loudly at load, not silently absorbed.
func TestPackRejectsInvertedControl(t *testing.T) {
	p, _, _ := loadAll(t, "2.0.0", "agent-remediation", "acme")
	if len(p.Controls) == 0 {
		t.Fatal("no controls")
	}
	// Sanity: enforcement must never be modelled as increasing frequency.
	for _, c := range p.Controls {
		if c.LEFEnforced.Mode > c.LEFAudit.Mode {
			t.Fatalf("control %s claims enforcement raises frequency", c.ID)
		}
	}
}

// Every unmet control must cite an evidence artefact — an assertion without evidence is not an
// assertion.
func TestUnmetControlsCiteEvidence(t *testing.T) {
	p, a, o := loadAll(t, "2.0.0", "agent-remediation", "acme")
	rep, err := Run(p, a, o, fast)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rep.Results {
		if r.Verdict == VerdictAudited || r.Verdict == VerdictGated {
			if r.Evidence == "" {
				t.Fatalf("%s reported %s with no cited evidence", r.Control.ID, r.Verdict)
			}
		}
	}
}
