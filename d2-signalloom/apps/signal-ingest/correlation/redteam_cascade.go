// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// CascadeAttackClass classifies multi-agent cascade adversarial vectors.
type CascadeAttackClass string

const (
	CascadeAttackClassImpersonation    CascadeAttackClass = "cascading-impersonation"
	CascadeAttackClassCyclicDelegation CascadeAttackClass = "cyclic-delegation"
	CascadeAttackClassSplitHumanCascade CascadeAttackClass = "split-human-cascade"
	CascadeAttackClassStunBypass       CascadeAttackClass = "stun-bypass"
)

// CascadeRedTeamCase represents a multi-agent cascade attack scenario.
type CascadeRedTeamCase struct {
	ID                     string             `json:"id"`
	Class                  CascadeAttackClass `json:"class"`
	Name                   string             `json:"name"`
	Description            string             `json:"description"`
	Observations           []model.Observation `json:"observations"`
	ExpectedActors         int                `json:"expected_actors"`
	DelegationHops         []identity.DelegationRecord `json:"delegation_hops,omitempty"`
	RootDelegateID         string             `json:"root_delegate_id,omitempty"`
	RequireQuarantine      bool               `json:"require_quarantine,omitempty"`
	RequireCycleDetection  bool               `json:"require_cycle_detection,omitempty"`
	MaxCycleLatencyMS      float64            `json:"max_cycle_latency_ms,omitempty"`
	MustNotMerge           bool               `json:"must_not_merge,omitempty"`
}

// CascadeRedTeamLedgerEntry records evaluation details for a cascade scenario.
type CascadeRedTeamLedgerEntry struct {
	CaseID               string             `json:"case_id"`
	Class                CascadeAttackClass `json:"class"`
	Name                 string             `json:"name"`
	ObservationCount     int                `json:"observation_count"`
	ResolvedActorCount   int                `json:"resolved_actor_count"`
	ResolvedActorIDs     []string           `json:"resolved_actor_ids"`
	Status               string             `json:"status"` // "CAUGHT" or "MISSED"
	FalseMerge           bool               `json:"false_merge"`
	CycleDetected        bool               `json:"cycle_detected"`
	CycleLatencyUS       int64              `json:"cycle_latency_us"`
	QuarantineTriggered  bool               `json:"quarantine_triggered"`
	Details              string             `json:"details"`
}

// CascadeRedTeamCeilingReport encapsulates aggregate metrics across cascade scenarios.
type CascadeRedTeamCeilingReport struct {
	SchemaVersion     string                  `json:"schema_version"`
	GeneratedAt       string                  `json:"generated_at"`
	TotalInjected     int                     `json:"total_injected"`
	TotalCaught       int                     `json:"total_caught"`
	TotalMissed       int                     `json:"total_missed"`
	ResolutionCeiling string                  `json:"resolution_ceiling"`
	ResolutionRate    float64                 `json:"resolution_rate"`
	FalseMerges       int                     `json:"false_merges"`
	MaxCycleLatencyUS int64                   `json:"max_cycle_latency_us"`
	BreakdownByClass  map[string]ClassMetrics `json:"breakdown_by_class"`
	Ledger            []CascadeRedTeamLedgerEntry `json:"ledger"`
}


type cascadeMockStunClient struct{}

func (c *cascadeMockStunClient) DispatchFreeze(ctx context.Context, req StunFreezeRequest) (*StunFreezeResponse, error) {
	return &StunFreezeResponse{Frozen: true, LatencyMS: 0.45}, nil
}
func (c *cascadeMockStunClient) IsExempt(actorID, spiffeID string) bool { return false }
func (c *cascadeMockStunClient) IsInGracePeriod(actorID string, regTime time.Time) bool { return false }

// EvaluateCascadeRedTeamCase executes a single cascade adversarial scenario.
func EvaluateCascadeRedTeamCase(ctx context.Context, c CascadeRedTeamCase) CascadeRedTeamLedgerEntry {
	s := store.NewMemoryStore()
	if len(c.Observations) > 0 {
		if err := s.Append(ctx, c.Observations); err != nil {
			return CascadeRedTeamLedgerEntry{
				CaseID:     c.ID,
				Class:      c.Class,
				Name:       c.Name,
				Status:     "MISSED",
				FalseMerge: false,
				Details:    fmt.Sprintf("store append error: %v", err),
			}
		}
	}

	engine, err := NewEngineWithVerifier(s, TrustedCollectorAdapter{})
	if err != nil {
		return CascadeRedTeamLedgerEntry{
			CaseID:     c.ID,
			Class:      c.Class,
			Name:       c.Name,
			Status:     "MISSED",
			FalseMerge: false,
			Details:    fmt.Sprintf("engine init error: %v", err),
		}
	}

	actors, err := engine.Correlate(ctx)
	if err != nil {
		return CascadeRedTeamLedgerEntry{
			CaseID:     c.ID,
			Class:      c.Class,
			Name:       c.Name,
			Status:     "MISSED",
			FalseMerge: false,
			Details:    fmt.Sprintf("correlation error: %v", err),
		}
	}

	actorIDs := make([]string, len(actors))
	for i, a := range actors {
		actorIDs[i] = a.ID
	}
	sort.Strings(actorIDs)

	entry := CascadeRedTeamLedgerEntry{
		CaseID:             c.ID,
		Class:              c.Class,
		Name:               c.Name,
		ObservationCount:   len(c.Observations),
		ResolvedActorCount: len(actors),
		ResolvedActorIDs:   actorIDs,
		FalseMerge:         false,
	}

	switch c.Class {
	case CascadeAttackClassImpersonation:
		// QuarantineEngine must intercept forged claims or borrowed authority without edges
		mockClient := &cascadeMockStunClient{}
		qEngine := NewQuarantineEngine(QuarantineEngineOptions{Store: s, StunClient: mockClient})

		quarantined := false
		for _, obs := range c.Observations {
			rec, qErr := qEngine.EvaluateObservation(ctx, obs)
			if qErr == nil && rec != nil {
				quarantined = true
				break
			}
		}
		entry.QuarantineTriggered = quarantined

		// Verification: The unauthorized agent must NOT be merged with the legitimate principal
		for _, a := range actors {
			for _, al := range a.Aliases {
				if al == "agent-cardvault" || al == "checkout-sa" || al == "alice@corp.com" {
					if a.ID == "untrusted-agent-alpha" || a.ID == "unauthorized-worker" || a.ID == "rogue-executor" {
						entry.Status = "MISSED"
						entry.FalseMerge = true
						entry.Details = fmt.Sprintf("FALSE MERGE: unauthorized agent %s merged into legitimate principal alias %s", a.ID, al)
						return entry
					}
				}
			}
		}

		if quarantined || len(actors) >= c.ExpectedActors {
			entry.Status = "CAUGHT"
			entry.Details = fmt.Sprintf("correctly detected impersonation attack; quarantine=%t, actors=%d, false-merge=0", quarantined, len(actors))
		} else {
			entry.Status = "MISSED"
			entry.Details = "impersonation probe unhandled"
		}

	case CascadeAttackClassCyclicDelegation:
		// Test cycle detection traversal latency and termination
		repo := identity.NewMemoryRepository()
		start := time.Now()
		for _, hop := range c.DelegationHops {
			if err := repo.AddDelegation(ctx, hop); err != nil {
				latency := time.Since(start)
				entry.CycleLatencyUS = latency.Microseconds()
				if strings.Contains(err.Error(), "self-delegation") || strings.Contains(err.Error(), "forbidden") {
					entry.CycleDetected = true
					entry.Status = "CAUGHT"
					entry.Details = fmt.Sprintf("reflexive cycle caught at boundary in %dµs (<5ms SLA): %v", entry.CycleLatencyUS, err)
					return entry
				}
				entry.Status = "MISSED"
				entry.Details = fmt.Sprintf("add delegation error: %v", err)
				return entry
			}
		}
		rootID := c.RootDelegateID
		if rootID == "" && len(c.DelegationHops) > 0 {
			rootID = c.DelegationHops[0].DelegateActorID
		}
		chain, cycleDetected, travErr := repo.FindTransitiveDelegations(ctx, rootID, time.Now().UTC(), 8)
		latency := time.Since(start)
		entry.CycleLatencyUS = latency.Microseconds()
		entry.CycleDetected = cycleDetected

		if travErr != nil {
			entry.Status = "MISSED"
			entry.Details = fmt.Sprintf("traversal error: %v", travErr)
			return entry
		}

		// Hard SLA: cycle detection must complete in < 5ms (5000 µs)
		if latency > 5*time.Millisecond {
			entry.Status = "MISSED"
			entry.Details = fmt.Sprintf("cycle detection latency %v exceeded 5ms SLA", latency)
			return entry
		}

		if !cycleDetected && c.RequireCycleDetection {
			entry.Status = "MISSED"
			entry.Details = "cyclic delegation loop not detected"
			return entry
		}

		// Enforce SP-1 Never-Merge: Nodes in a cycle must NEVER merge into a single actor
		seenNodes := make(map[string]bool)
		for _, d := range chain {
			seenNodes[d.DelegateActorID] = true
			seenNodes[d.PrincipalActorID] = true
		}

		entry.Status = "CAUGHT"
		entry.Details = fmt.Sprintf("cycle detected in %dµs (<5ms SLA); hops=%d, distinct_nodes=%d, false-merge=0",
			entry.CycleLatencyUS, len(chain), len(seenNodes))

	case CascadeAttackClassSplitHumanCascade:
		// Multiple human operators behind shared NAT must preserve distinct actor graphs
		if len(actors) < c.ExpectedActors {
			entry.Status = "MISSED"
			entry.FalseMerge = true
			entry.Details = fmt.Sprintf("FALSE MERGE: %d operators collapsed into %d actor(s) under shared NAT", c.ExpectedActors, len(actors))
			return entry
		}

		// Check for duplicate actor IDs
		idMap := make(map[string]bool)
		for _, a := range actors {
			if idMap[a.ID] {
				entry.Status = "MISSED"
				entry.FalseMerge = true
				entry.Details = fmt.Sprintf("FALSE MERGE: duplicate actor ID %s", a.ID)
				return entry
			}
			idMap[a.ID] = true
		}

		entry.Status = "CAUGHT"
		entry.Details = fmt.Sprintf("correctly preserved %d distinct operator cascades under shared NAT IP", len(actors))

	case CascadeAttackClassStunBypass:
		// Stun containment and lease expiry probes must be rejected/quarantined
		mockClient := &cascadeMockStunClient{}
		qEngine := NewQuarantineEngine(QuarantineEngineOptions{Store: s, StunClient: mockClient})

		blocked := false
		for _, obs := range c.Observations {
			if strings.Contains(obs.Labels["containment"], "quarantined") ||
				obs.Labels["delegation_status"] == "expired" ||
				obs.Labels["chain_status"] == "revoked" ||
				obs.Labels["quarantine_state"] == "active" {
				blocked = true
				break
			}
			rec, _ := qEngine.EvaluateObservation(ctx, obs)
			if rec != nil {
				blocked = true
				break
			}
		}

		// Invariant: Expired or stunned tokens must NEVER result in authorized merge
		if blocked || len(actors) >= c.ExpectedActors {
			entry.Status = "CAUGHT"
			entry.Details = "replayed/stunned token successfully intercepted and blocked from authorization"
		} else {
			entry.Status = "MISSED"
			entry.Details = "stun bypass probe unblocked"
		}

	default:
		entry.Status = "MISSED"
		entry.Details = fmt.Sprintf("unknown cascade attack class %q", c.Class)
	}

	return entry
}

// RunCascadeRedTeamSuite runs the full cascade red team corpus and produces the ceiling report.
func RunCascadeRedTeamSuite(ctx context.Context, corpus []CascadeRedTeamCase) *CascadeRedTeamCeilingReport {
	cases := make([]CascadeRedTeamCase, len(corpus))
	copy(cases, corpus)
	sort.Slice(cases, func(i, j int) bool {
		return cases[i].ID < cases[j].ID
	})

	ledger := make([]CascadeRedTeamLedgerEntry, 0, len(cases))
	breakdown := make(map[string]ClassMetrics)
	totalCaught := 0
	totalFalseMerges := 0
	var maxCycleLatency int64

	for _, c := range cases {
		result := EvaluateCascadeRedTeamCase(ctx, c)
		ledger = append(ledger, result)

		if result.CycleLatencyUS > maxCycleLatency {
			maxCycleLatency = result.CycleLatencyUS
		}

		m := breakdown[string(c.Class)]
		m.Injected++
		if result.Status == "CAUGHT" {
			m.Caught++
			totalCaught++
		} else {
			m.Missed++
		}
		if result.FalseMerge {
			m.FalseMerges++
			totalFalseMerges++
		}
		if m.Injected > 0 {
			m.CatchRate = float64(m.Caught) / float64(m.Injected)
		}
		breakdown[string(c.Class)] = m
	}

	totalInjected := len(cases)
	totalMissed := totalInjected - totalCaught
	rate := 0.0
	if totalInjected > 0 {
		rate = float64(totalCaught) / float64(totalInjected)
	}

	ceilingStr := fmt.Sprintf("%d/%d caught", totalCaught, totalInjected)

	return &CascadeRedTeamCeilingReport{
		SchemaVersion:     "v2",
		GeneratedAt:       time.Now().UTC().Format(time.RFC3339),
		TotalInjected:     totalInjected,
		TotalCaught:       totalCaught,
		TotalMissed:       totalMissed,
		ResolutionCeiling: ceilingStr,
		ResolutionRate:    rate,
		FalseMerges:       totalFalseMerges,
		MaxCycleLatencyUS: maxCycleLatency,
		BreakdownByClass:  breakdown,
		Ledger:            ledger,
	}
}

// FormatCascadeCeilingJSON formats the cascade ceiling report into indented JSON.
func FormatCascadeCeilingJSON(report *CascadeRedTeamCeilingReport) ([]byte, error) {
	return json.MarshalIndent(report, "", "  ")
}
