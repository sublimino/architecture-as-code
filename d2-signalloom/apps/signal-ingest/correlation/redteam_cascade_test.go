// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestCascadeRedTeam_FullCorpus(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)

	corpus := BuildCascadeAdversarialCorpus(baseTime)
	if len(corpus) != 24 {
		t.Fatalf("expected 24 canonical cascade red team cases, got %d", len(corpus))
	}

	report := RunCascadeRedTeamSuite(ctx, corpus)

	t.Logf("Cascade Red Team Suite Evaluation: %s (resolution rate: %.2f%%)",
		report.ResolutionCeiling, report.ResolutionRate*100)
	t.Logf("Max cycle detection latency: %dµs (< 5000µs SLA)", report.MaxCycleLatencyUS)

	// Release Gate 1: Zero False-Merge release invariant
	if report.FalseMerges != 0 {
		t.Fatalf("RELEASE GATE FAILED: expected false_merges == 0, got %d", report.FalseMerges)
	}

	// Release Gate 2: 100% catch rate across all 24 cascade scenarios
	if report.TotalCaught != 24 {
		t.Fatalf("RELEASE GATE FAILED: expected 24/24 caught, got %d (missed: %d)",
			report.TotalCaught, report.TotalMissed)
	}

	if report.ResolutionRate != 1.0 {
		t.Fatalf("RELEASE GATE FAILED: expected resolution_rate == 1.0, got %.4f", report.ResolutionRate)
	}

	// Release Gate 3: Cycle detection latency SLA (< 5ms)
	if report.MaxCycleLatencyUS > 5000 {
		t.Fatalf("RELEASE GATE FAILED: max cycle detection latency %dµs exceeded 5000µs SLA", report.MaxCycleLatencyUS)
	}

	// Verify ledger entries
	for _, entry := range report.Ledger {
		if entry.Status != "CAUGHT" {
			t.Errorf("case %s (%s) was MISSED: %s", entry.CaseID, entry.Class, entry.Details)
		}
		if entry.FalseMerge {
			t.Errorf("case %s caused FALSE MERGE: %s", entry.CaseID, entry.Details)
		}
	}

	// Write / update published ceiling artifact
	data, err := FormatCascadeCeilingJSON(report)
	if err != nil {
		t.Fatalf("failed to format ceiling json: %v", err)
	}

	ceilingPath := filepath.Join(".", "redteam_cascade_ceiling.json")
	if err := os.WriteFile(ceilingPath, data, 0644); err != nil {
		t.Fatalf("failed to write ceiling artifact: %v", err)
	}
}

func TestCascadeRedTeam_CascadingImpersonation(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	corpus := BuildCascadeAdversarialCorpus(baseTime)

	for _, c := range corpus {
		if c.Class != CascadeAttackClassImpersonation {
			continue
		}
		entry := EvaluateCascadeRedTeamCase(ctx, c)
		if entry.Status != "CAUGHT" {
			t.Errorf("impersonation case %s failed: %s", c.ID, entry.Details)
		}
		if entry.FalseMerge {
			t.Errorf("impersonation case %s caused FALSE MERGE: %s", c.ID, entry.Details)
		}
		if !entry.QuarantineTriggered {
			t.Errorf("impersonation case %s did not trigger quarantine", c.ID)
		}
	}
}

func TestCascadeRedTeam_CyclicDelegation_Sub5ms(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	corpus := BuildCascadeAdversarialCorpus(baseTime)

	for _, c := range corpus {
		if c.Class != CascadeAttackClassCyclicDelegation {
			continue
		}
		entry := EvaluateCascadeRedTeamCase(ctx, c)
		if entry.Status != "CAUGHT" {
			t.Errorf("cyclic delegation case %s failed: %s", c.ID, entry.Details)
		}
		if !entry.CycleDetected {
			t.Errorf("cyclic delegation case %s did not detect cycle", c.ID)
		}
		if entry.CycleLatencyUS > 5000 {
			t.Errorf("cyclic delegation case %s latency %dµs exceeded 5ms SLA", c.ID, entry.CycleLatencyUS)
		}
		if entry.FalseMerge {
			t.Errorf("cyclic delegation case %s caused FALSE MERGE", c.ID)
		}
		t.Logf("case %s cycle latency: %dµs (< 5000µs)", c.ID, entry.CycleLatencyUS)
	}
}

func TestCascadeRedTeam_SplitHumanCascade_Separation(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	corpus := BuildCascadeAdversarialCorpus(baseTime)

	for _, c := range corpus {
		if c.Class != CascadeAttackClassSplitHumanCascade {
			continue
		}
		entry := EvaluateCascadeRedTeamCase(ctx, c)
		if entry.Status != "CAUGHT" {
			t.Errorf("split human cascade case %s failed: %s", c.ID, entry.Details)
		}
		if entry.FalseMerge {
			t.Errorf("split human cascade case %s caused FALSE MERGE: %s", c.ID, entry.Details)
		}
		if entry.ResolvedActorCount != c.ExpectedActors {
			t.Errorf("split human cascade case %s: expected %d actors, got %d",
				c.ID, c.ExpectedActors, entry.ResolvedActorCount)
		}
	}
}

func TestCascadeRedTeam_StunBypass_Rejection(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	corpus := BuildCascadeAdversarialCorpus(baseTime)

	for _, c := range corpus {
		if c.Class != CascadeAttackClassStunBypass {
			continue
		}
		entry := EvaluateCascadeRedTeamCase(ctx, c)
		if entry.Status != "CAUGHT" {
			t.Errorf("stun bypass case %s failed: %s", c.ID, entry.Details)
		}
		if entry.FalseMerge {
			t.Errorf("stun bypass case %s caused FALSE MERGE", c.ID)
		}
	}
}

func TestCascadeRedTeam_CeilingReport_ArtifactMatches(t *testing.T) {
	ctx := context.Background()
	baseTime := time.Date(2026, 9, 10, 10, 0, 0, 0, time.UTC)
	corpus := BuildCascadeAdversarialCorpus(baseTime)
	report := RunCascadeRedTeamSuite(ctx, corpus)

	ceilingPath := filepath.Join(".", "redteam_cascade_ceiling.json")
	data, err := os.ReadFile(ceilingPath)
	if err != nil {
		t.Fatalf("failed to read ceiling artifact: %v", err)
	}

	var committed CascadeRedTeamCeilingReport
	if err := json.Unmarshal(data, &committed); err != nil {
		t.Fatalf("failed to unmarshal committed ceiling: %v", err)
	}

	if committed.TotalInjected != report.TotalInjected {
		t.Errorf("ceiling total_injected mismatch: committed=%d, evaluated=%d",
			committed.TotalInjected, report.TotalInjected)
	}
	if committed.TotalCaught != report.TotalCaught {
		t.Errorf("ceiling total_caught mismatch: committed=%d, evaluated=%d",
			committed.TotalCaught, report.TotalCaught)
	}
	if committed.FalseMerges != 0 {
		t.Errorf("committed ceiling contains non-zero false_merges: %d", committed.FalseMerges)
	}
}

// TestCascadeAdversarial provides the canonical named entry point for adversarial cascade tests.
func TestCascadeAdversarial(t *testing.T) {
	TestCascadeRedTeam_FullCorpus(t)
}

// TestAdversarialCascade provides the named entry point referenced in card acceptance criteria.
func TestAdversarialCascade(t *testing.T) {
	TestCascadeRedTeam_FullCorpus(t)
}


// BuildCascadeAdversarialCorpus constructs the canonical 24-case cascade red team corpus.
func BuildCascadeAdversarialCorpus(baseTime time.Time) []CascadeRedTeamCase {
	ciObs := collectors.AdversarialCascadeImpersonationFixtures(baseTime)
	cdObs := collectors.AdversarialCyclicDelegationFixtures(baseTime)
	shcObs := collectors.AdversarialSplitHumanCascadeFixtures(baseTime)
	sbpObs := collectors.AdversarialStunBypassFixtures(baseTime)

	var corpus []CascadeRedTeamCase

	// 1. Cascading Impersonation (6 cases)
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-01",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Unauthorized Intermediate Hop Impersonation",
		Description:       "Unauthorized agent claims intermediate borrowed authority for agent-cardvault without signed delegation edge",
		Observations:      []model.Observation{ciObs[0]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-02",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Two-Tier Service Account Spoofing",
		Description:       "Worker claims payments checkout-sa principal via spoofed header under incomplete chain",
		Observations:      []model.Observation{ciObs[1]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-03",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Cascading Intermediate Delegation Hop Forgery",
		Description:       "Cascading hop with untrusted intermediate delegation claim attempting unauthorized routing alteration",
		Observations:      []model.Observation{ciObs[2]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-04",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Privileged Container Action Without Cosign Signature",
		Description:       "Privileged network filter manipulation from unverified container image lacking Cosign signature",
		Observations:      []model.Observation{ciObs[3]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-05",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Delegation Depth Ceiling Tampering",
		Description:       "Deep delegation chain claiming depth 9, exceeding security ceiling of 7",
		Observations:      []model.Observation{ciObs[4]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                "ADV-CI-06",
		Class:             CascadeAttackClassImpersonation,
		Name:              "Shadow Identity Cluster-Admin Impersonation",
		Description:       "Shadow identity claiming cluster-admin impersonation without authenticated SVID",
		Observations:      []model.Observation{ciObs[5]},
		ExpectedActors:    1,
		RequireQuarantine: true,
	})

	// 2. Cyclic Delegation (6 cases)
	now := baseTime
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-01",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "Direct 2-Hop Cyclic Delegation Loop",
		Description:           "Direct recursive loop between agent-cycle-a and agent-cycle-b",
		Observations:          []model.Observation{cdObs[0], cdObs[1]},
		RootDelegateID:        "agent-cycle-a",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 1, DelegateActorID: "agent-cycle-a", PrincipalActorID: "agent-cycle-b", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 2, DelegateActorID: "agent-cycle-b", PrincipalActorID: "agent-cycle-a", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-02",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "Triangular 3-Hop Cyclic Delegation Loop",
		Description:           "Triangular loop traversing loop-x -> loop-y -> loop-z -> loop-x",
		Observations:          []model.Observation{cdObs[2], cdObs[3], cdObs[4]},
		RootDelegateID:        "agent-loop-x",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 10, DelegateActorID: "agent-loop-x", PrincipalActorID: "agent-loop-y", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 11, DelegateActorID: "agent-loop-y", PrincipalActorID: "agent-loop-z", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 12, DelegateActorID: "agent-loop-z", PrincipalActorID: "agent-loop-x", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-03",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "Reflexive Self-Delegation Loop",
		Description:           "Single agent self-referential reflexive delegation loop",
		Observations:          []model.Observation{cdObs[5]},
		RootDelegateID:        "agent-self-ref",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 20, DelegateActorID: "agent-self-ref", PrincipalActorID: "agent-self-ref", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-04",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "Nested Sub-Agent Orchestration Loop",
		Description:           "Multi-agent orchestrator tree sub1 -> sub2 -> sub1 recursion loop",
		Observations:          []model.Observation{cdObs[6], cdObs[7]},
		RootDelegateID:        "agent-orch-sub1",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 30, DelegateActorID: "agent-orch-sub1", PrincipalActorID: "agent-orch-sub2", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 31, DelegateActorID: "agent-orch-sub2", PrincipalActorID: "agent-orch-sub1", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-05",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "Cross-Layer SPIFFE and ServiceAccount Cycle",
		Description:           "Cross-layer cycle between SPIFFE workload ID and K8s ServiceAccount",
		Observations:          []model.Observation{cdObs[8], cdObs[9]},
		RootDelegateID:        "spiffe://cluster.local/ns/prod/sa/agent-spiffe-a",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 40, DelegateActorID: "spiffe://cluster.local/ns/prod/sa/agent-spiffe-a", PrincipalActorID: "system:serviceaccount:prod:agent-k8s-b", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 41, DelegateActorID: "system:serviceaccount:prod:agent-k8s-b", PrincipalActorID: "spiffe://cluster.local/ns/prod/sa/agent-spiffe-a", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:                    "ADV-CD-06",
		Class:                 CascadeAttackClassCyclicDelegation,
		Name:                  "4-Hop Deep Circular Exhaustion Loop",
		Description:           "Multi-hop circular chain hop1 -> hop2 -> hop3 -> hop4 -> hop1",
		Observations:          []model.Observation{cdObs[10]},
		RootDelegateID:        "agent-stack-hop1",
		RequireCycleDetection: true,
		MaxCycleLatencyMS:     5.0,
		DelegationHops: []identity.DelegationRecord{
			{ID: 50, DelegateActorID: "agent-stack-hop1", PrincipalActorID: "agent-stack-hop2", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 51, DelegateActorID: "agent-stack-hop2", PrincipalActorID: "agent-stack-hop3", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 52, DelegateActorID: "agent-stack-hop3", PrincipalActorID: "agent-stack-hop4", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
			{ID: 53, DelegateActorID: "agent-stack-hop4", PrincipalActorID: "agent-stack-hop1", ValidFrom: now.Add(-1 * time.Hour), CreatedAt: now},
		},
	})

	// 3. NAT Split-Human Cascade (6 cases)
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-01",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "Corporate Egress NAT Dual-Operator Separation",
		Description:    "Two distinct operators dev-lead and sre-oncall dispatching separate agent swarms behind shared NAT 198.51.100.42",
		Observations:   []model.Observation{shcObs[0], shcObs[1]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-02",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "Multi-Region Egress NAT Overlapping Deployer Roles",
		Description:    "Distinct operators Carol and Dave operating overlapping deployer roles behind shared firewall IP 203.0.113.10",
		Observations:   []model.Observation{shcObs[2], shcObs[3]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-03",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "Cloud Console Shared NAT Autonomous Triage",
		Description:    "Admin-US and Admin-EU cloud console sessions under shared proxy NAT 198.51.100.77",
		Observations:   []model.Observation{shcObs[4], shcObs[5]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-04",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "Telemetry Egress Proxy Aggregated Developer Workflows",
		Description:    "Engineer-1 and Engineer-2 workstation sessions behind proxy IP 192.0.2.88",
		Observations:   []model.Observation{shcObs[6], shcObs[7]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-05",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "SaaS API Gateway Shared NAT External OAuth Clients",
		Description:    "Distinct external OAuth clients Alpha and Beta exchanging tokens behind gateway IP 203.0.113.99",
		Observations:   []model.Observation{shcObs[8], shcObs[9]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SHC-06",
		Class:          CascadeAttackClassSplitHumanCascade,
		Name:           "Multi-Tenant CI/CD Runner Node Parallel Pipelines",
		Description:    "Independent CI runner jobs for Repo A and Repo B executing concurrently on shared node IP 198.51.100.200",
		Observations:   []model.Observation{shcObs[10], shcObs[11]},
		ExpectedActors: 2,
		MustNotMerge:   true,
	})

	// 4. Stun Bypass Probes (6 cases)
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-01",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Expired Delegation Lease Replay Probe",
		Description:    "Replay probe using expired delegation lease with valid_to in the past",
		Observations:   []model.Observation{sbpObs[0]},
		ExpectedActors: 1,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-02",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Stunned Agent Immediate Egress Probe",
		Description:    "Quarantined agent attempting immediate network egress following stun freeze trigger",
		Observations:   []model.Observation{sbpObs[1]},
		ExpectedActors: 1,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-03",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Downstream Delegatee Action on Revoked Chain",
		Description:    "Downstream leaf agent invoking privileged action after upstream principal delegation severed",
		Observations:   []model.Observation{sbpObs[2]},
		ExpectedActors: 1,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-04",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Stunned Agent Alias Resurrection Probe",
		Description:    "Contained agent attempting secondary alias reuse under newly provisioned SVID",
		Observations:   []model.Observation{sbpObs[3]},
		ExpectedActors: 1,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-05",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Temporal Spoofing Backdated Query Probe",
		Description:    "Backdated timestamp query probe attempting historical reflection of revoked authority",
		Observations:   []model.Observation{sbpObs[4]},
		ExpectedActors: 1,
	})
	corpus = append(corpus, CascadeRedTeamCase{
		ID:             "ADV-SBP-06",
		Class:          CascadeAttackClassStunBypass,
		Name:           "Rapid Delegation Reissue Probe Without Unfreeze",
		Description:    "Attempted delegation re-issuance for quarantined actor prior to operator unfreeze",
		Observations:   []model.Observation{sbpObs[5]},
		ExpectedActors: 1,
	})

	return corpus
}

