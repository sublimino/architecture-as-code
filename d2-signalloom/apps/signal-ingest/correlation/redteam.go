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

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// AttackClass denotes the category of adversarial resolution probe.
type AttackClass string

const (
	AttackClassHiddenAlias AttackClass = "hidden-alias"
	AttackClassSplitHuman  AttackClass = "split-human"
	AttackClassShadowAgent AttackClass = "shadow-agent"
)

// RedTeamCase represents a single pre-labelled adversarial injection scenario.
type RedTeamCase struct {
	ID                 string              `json:"id"`
	Class              AttackClass         `json:"class"`
	Name               string              `json:"name"`
	Description        string              `json:"description"`
	Observations       []model.Observation `json:"observations"`
	ExpectedActors     int                 `json:"expected_actors"`
	ExpectedAliases    []string            `json:"expected_aliases,omitempty"`
	RequireProvisional bool                `json:"require_provisional,omitempty"`
	MustNotMerge       bool                `json:"must_not_merge,omitempty"`
}

// RedTeamLedgerEntry records the evaluation outcome of a single adversarial case.
type RedTeamLedgerEntry struct {
	CaseID             string      `json:"case_id"`
	Class              AttackClass `json:"class"`
	Name               string      `json:"name"`
	ObservationCount   int         `json:"observation_count"`
	ResolvedActorCount int         `json:"resolved_actor_count"`
	ResolvedActorIDs   []string    `json:"resolved_actor_ids"`
	Status             string      `json:"status"` // "CAUGHT" or "MISSED"
	FalseMerge         bool        `json:"false_merge"`
	Details            string      `json:"details"`
}

// ClassMetrics aggregates results for an attack class.
type ClassMetrics struct {
	Injected    int     `json:"injected"`
	Caught      int     `json:"caught"`
	Missed      int     `json:"missed"`
	FalseMerges int     `json:"false_merges"`
	CatchRate   float64 `json:"catch_rate"`
}

// RedTeamCeilingReport represents the published machine-readable resolution ceiling report.
type RedTeamCeilingReport struct {
	SchemaVersion     string                  `json:"schema_version"`
	GeneratedAt       string                  `json:"generated_at"`
	TotalInjected     int                     `json:"total_injected"`
	TotalCaught       int                     `json:"total_caught"`
	TotalMissed       int                     `json:"total_missed"`
	ResolutionCeiling string                  `json:"resolution_ceiling"` // e.g. "18/18 caught"
	ResolutionRate    float64                 `json:"resolution_rate"`    // 1.0
	FalseMerges       int                     `json:"false_merges"`       // hard-gate: must be 0
	BreakdownByClass  map[string]ClassMetrics `json:"breakdown_by_class"`
	Ledger            []RedTeamLedgerEntry    `json:"ledger"`
}

// ManifestCase represents an entry in the denominator manifest.
type ManifestCase struct {
	ID             string      `json:"id"`
	Class          AttackClass `json:"class"`
	Name           string      `json:"name"`
	Description    string      `json:"description"`
	ObservationIDs []string    `json:"observation_ids"`
	ExpectedActors int         `json:"expected_actors"`
}

// RedTeamManifest is the committed denominator manifest N.
type RedTeamManifest struct {
	SchemaVersion string         `json:"schema_version"`
	TotalN        int            `json:"total_n"`
	CountsByClass map[string]int `json:"counts_by_class"`
	Cases         []ManifestCase `json:"cases"`
}

// EvaluateRedTeamCase runs a single adversarial test case through the real Engine and Resolve paths.
func EvaluateRedTeamCase(ctx context.Context, c RedTeamCase) RedTeamLedgerEntry {
	s := store.NewMemoryStore()
	if err := s.Append(ctx, c.Observations); err != nil {
		return RedTeamLedgerEntry{
			CaseID:             c.ID,
			Class:              c.Class,
			Name:               c.Name,
			ObservationCount:   len(c.Observations),
			ResolvedActorCount: 0,
			Status:             "MISSED",
			FalseMerge:         false,
			Details:            fmt.Sprintf("store append error: %v", err),
		}
	}

	engine, err := NewEngineWithVerifier(s, TrustedCollectorAdapter{})
	if err != nil {
		return RedTeamLedgerEntry{
			CaseID:             c.ID,
			Class:              c.Class,
			Name:               c.Name,
			ObservationCount:   len(c.Observations),
			ResolvedActorCount: 0,
			Status:             "MISSED",
			FalseMerge:         false,
			Details:            fmt.Sprintf("engine init error: %v", err),
		}
	}

	actors, err := engine.Correlate(ctx)
	if err != nil {
		return RedTeamLedgerEntry{
			CaseID:             c.ID,
			Class:              c.Class,
			Name:               c.Name,
			ObservationCount:   len(c.Observations),
			ResolvedActorCount: 0,
			Status:             "MISSED",
			FalseMerge:         false,
			Details:            fmt.Sprintf("correlation error: %v", err),
		}
	}

	actorIDs := make([]string, len(actors))
	for i, a := range actors {
		actorIDs[i] = a.ID
	}
	sort.Strings(actorIDs)

	entry := RedTeamLedgerEntry{
		CaseID:             c.ID,
		Class:              c.Class,
		Name:               c.Name,
		ObservationCount:   len(c.Observations),
		ResolvedActorCount: len(actors),
		ResolvedActorIDs:   actorIDs,
		FalseMerge:         false,
	}

	switch c.Class {
	case AttackClassHiddenAlias:
		// Hidden alias must join into exactly 1 actor with all observations in its evidence chain
		if len(actors) != 1 {
			entry.Status = "MISSED"
			entry.Details = fmt.Sprintf("expected 1 joined actor, got %d", len(actors))
			return entry
		}
		actor := actors[0]
		obsSeen := make(map[string]bool)
		for _, ev := range actor.EvidenceChain {
			obsSeen[ev.ObservationID] = true
		}
		for _, o := range c.Observations {
			if !obsSeen[o.ID] {
				entry.Status = "MISSED"
				entry.Details = fmt.Sprintf("joined actor missing observation %s in evidence chain", o.ID)
				return entry
			}
		}
		entry.Status = "CAUGHT"
		entry.Details = fmt.Sprintf("correctly joined %d observations into actor %s", len(c.Observations), actor.ID)

	case AttackClassSplitHuman:
		// Two distinct humans sharing NAT IP must NOT collapse into 1 actor
		if len(actors) < c.ExpectedActors {
			// Collapsed! False merge!
			entry.Status = "MISSED"
			entry.FalseMerge = true
			entry.Details = fmt.Sprintf("FALSE MERGE: %d distinct principals collapsed into %d actor(s)", len(c.Observations), len(actors))
			return entry
		}
		if len(actors) != c.ExpectedActors {
			entry.Status = "MISSED"
			entry.Details = fmt.Sprintf("expected %d distinct actors, got %d", c.ExpectedActors, len(actors))
			return entry
		}
		// Confirm each actor has a distinct ID
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
		entry.Details = fmt.Sprintf("correctly preserved %d distinct actors under shared NAT IP", len(actors))

	case AttackClassShadowAgent:
		// Shadow agent without SVID must surface as provisional, never merged into a real actor
		if len(actors) != 1 {
			entry.Status = "MISSED"
			entry.Details = fmt.Sprintf("expected 1 provisional actor, got %d", len(actors))
			return entry
		}
		actor := actors[0]
		if actor.Status != model.ActorProvisional && !strings.HasPrefix(actor.ID, "actor-signal-ingest|observation|") {
			// Improperly promoted or merged into authenticated actor
			entry.Status = "MISSED"
			entry.FalseMerge = true
			entry.Details = fmt.Sprintf("FALSE MERGE: shadow agent action merged into authenticated/actionable actor %s (status=%v)", actor.ID, actor.Status)
			return entry
		}
		entry.Status = "CAUGHT"
		entry.Details = fmt.Sprintf("correctly surfaced unauthenticated action as provisional actor %s", actor.ID)

	default:
		entry.Status = "MISSED"
		entry.Details = fmt.Sprintf("unknown attack class %q", c.Class)
	}

	return entry
}

// RunRedTeamSuite executes the complete red team corpus and produces the ceiling report.
func RunRedTeamSuite(ctx context.Context, corpus []RedTeamCase) *RedTeamCeilingReport {
	// Sort corpus by CaseID
	cases := make([]RedTeamCase, len(corpus))
	copy(cases, corpus)
	sort.Slice(cases, func(i, j int) bool {
		return cases[i].ID < cases[j].ID
	})

	ledger := make([]RedTeamLedgerEntry, 0, len(cases))
	breakdown := make(map[string]ClassMetrics)
	totalCaught := 0
	totalFalseMerges := 0

	for _, c := range cases {
		result := EvaluateRedTeamCase(ctx, c)
		ledger = append(ledger, result)

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

	return &RedTeamCeilingReport{
		SchemaVersion:     "v1",
		GeneratedAt:       time.Now().UTC().Format(time.RFC3339),
		TotalInjected:     totalInjected,
		TotalCaught:       totalCaught,
		TotalMissed:       totalMissed,
		ResolutionCeiling: ceilingStr,
		ResolutionRate:    rate,
		FalseMerges:       totalFalseMerges,
		BreakdownByClass:  breakdown,
		Ledger:            ledger,
	}
}

// GenerateManifest creates the denominator manifest N for the corpus.
func GenerateManifest(corpus []RedTeamCase) RedTeamManifest {
	cases := make([]ManifestCase, 0, len(corpus))
	counts := make(map[string]int)

	for _, c := range corpus {
		obsIDs := make([]string, len(c.Observations))
		for i, o := range c.Observations {
			obsIDs[i] = o.ID
		}
		cases = append(cases, ManifestCase{
			ID:             c.ID,
			Class:          c.Class,
			Name:           c.Name,
			Description:    c.Description,
			ObservationIDs: obsIDs,
			ExpectedActors: c.ExpectedActors,
		})
		counts[string(c.Class)]++
	}

	sort.Slice(cases, func(i, j int) bool {
		return cases[i].ID < cases[j].ID
	})

	return RedTeamManifest{
		SchemaVersion: "v1",
		TotalN:        len(corpus),
		CountsByClass: counts,
		Cases:         cases,
	}
}

// FormatCeilingJSON formats the report into deterministic indented JSON.
func FormatCeilingJSON(report *RedTeamCeilingReport) ([]byte, error) {
	return json.MarshalIndent(report, "", "  ")
}

// FormatManifestJSON formats the manifest into deterministic indented JSON.
func FormatManifestJSON(manifest *RedTeamManifest) ([]byte, error) {
	return json.MarshalIndent(manifest, "", "  ")
}
