// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

const defaultAttackChainDedupe = 15 * time.Minute

// ChainStage matches a finding by layer and/or an explicit source gate.
// A finding matches when its layer and source satisfy every non-empty gate.
type ChainStage struct {
	Layer   model.Layer
	Sources []string
	Label   string
}

// AttackChain defines an ordered, actor-scoped sequence of stage-1 findings.
type AttackChain struct {
	ID     string
	Name   string
	Reason model.ViolationReason
	Window time.Duration
	Stages []ChainStage
}

// ChainMatch records the distinct findings that completed an attack chain.
type ChainMatch struct {
	ChainID        string
	ActorID        string
	ObservationIDs []string
	FirstAt        time.Time
	LastAt         time.Time
	Confidence     float64
	StunDispatched bool
	StunResponse   *StunFreezeResponse
}

// AttackChainDetector correlates ordered findings and dispatches containment once per window bucket.
type AttackChainDetector struct {
	chains  []AttackChain
	stun    StunDispatchClient
	now     func() time.Time
	mu      sync.Mutex
	handled map[string]time.Time
	dedupe  time.Duration
}

// NewAttackChainDetector creates a detector with the built-in attack chains.
func NewAttackChainDetector(stun StunDispatchClient) *AttackChainDetector {
	return &AttackChainDetector{
		chains:  DefaultAttackChains(),
		stun:    stun,
		now:     time.Now,
		handled: make(map[string]time.Time),
		dedupe:  defaultAttackChainDedupe,
	}
}

// DefaultAttackChains returns the cross-stream chains emitted by the shipped stage-1 finding bundles.
func DefaultAttackChains() []AttackChain {
	return []AttackChain{
		{
			ID:     "exfil",
			Name:   "Exfiltration",
			Reason: model.ViolationReason("exfil_chain"),
			Window: 10 * time.Minute,
			// The CEL environment has no labels map. Each finding's presence proves
			// its labelled event predicate already matched in the stage-1 bundle.
			Stages: []ChainStage{
				{Layer: model.LayerCloudControlPlane, Sources: []string{"gcp-cloud-audit", "iam.amazonaws.com"}, Label: "cloud credential or IAM change"},
				{Layer: model.LayerEndpointHost, Label: "sensitive-file access or Landlock denial"},
				{Layer: model.LayerNetworkEgress, Label: "outbound egress"},
			},
		},
		{
			ID:     "account-takeover",
			Name:   "Account takeover",
			Reason: model.ViolationReason("account_takeover"),
			Window: 15 * time.Minute,
			// The CEL environment has no labels map. Each finding's presence proves
			// its labelled event predicate already matched in the stage-1 bundle.
			Stages: []ChainStage{
				{Layer: model.LayerApplicationSaaS, Sources: []string{"google-workspace.drive-audit", "slack-audit"}, Label: "SaaS login or access anomaly"},
				{Sources: []string{"k8s-apiserver-audit"}, Label: "service-account or token mint"},
				{Layer: model.LayerCloudControlPlane, Sources: []string{"gcp-cloud-audit", "iam.amazonaws.com"}, Label: "cloud API access"},
			},
		},
		{
			ID:     "privilege-cascade",
			Name:   "Privilege cascade",
			Reason: model.ViolationReason("privilege_cascade"),
			Window: 15 * time.Minute,
			// The CEL environment has no labels map. Each finding's presence proves
			// its labelled event predicate already matched in the stage-1 bundle;
			// the two OpenBao stages therefore require two distinct findings.
			Stages: []ChainStage{
				{Sources: []string{"k8s-apiserver-audit"}, Label: "RBAC escalation"},
				{Sources: []string{"openbao-audit"}, Label: "secret read"},
				{Sources: []string{"openbao-audit"}, Label: "OpenBao root-token use"},
			},
		},
	}
}

// Evaluate groups findings by resolved identity, detects every completed chain,
// and dispatches containment once per actor, chain, and first-finding window bucket.
func (d *AttackChainDetector) Evaluate(ctx context.Context, observations []model.Observation) ([]ChainMatch, error) {
	if d == nil {
		return nil, nil
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	groups := groupFindingsByResolvedActor(observations)
	actorIDs := make([]string, 0, len(groups))
	for actorID := range groups {
		actorIDs = append(actorIDs, actorID)
	}
	sort.Strings(actorIDs)

	chains := append([]AttackChain(nil), d.chains...)
	sort.Slice(chains, func(i, j int) bool { return chains[i].ID < chains[j].ID })
	matches := make([]ChainMatch, 0)
	for _, actorID := range actorIDs {
		findings := groups[actorID]
		for _, chain := range chains {
			matched, ok := matchAttackChain(actorID, findings, chain)
			if ok {
				matches = append(matches, matched)
			}
		}
	}
	sortChainMatches(matches)

	now := d.now()
	for key, handledAt := range d.handled {
		if now.Sub(handledAt) > d.dedupe {
			delete(d.handled, key)
		}
	}

	var dispatchErrors []error
	for index := range matches {
		match := &matches[index]
		chain, ok := attackChainByID(chains, match.ChainID)
		if !ok || d.stun == nil {
			continue
		}
		bucket := match.FirstAt.Truncate(chain.Window).UnixNano()
		key := match.ActorID + "|" + match.ChainID + "|" + strconv.FormatInt(bucket, 10)
		if _, handled := d.handled[key]; handled {
			continue
		}
		d.handled[key] = now
		response, err := d.stun.DispatchFreeze(ctx, StunFreezeRequest{
			ActorID:         match.ActorID,
			ViolationReason: chain.Reason,
			Action:          chain.Name + " cross-stream correlation",
		})
		match.StunResponse = cloneStunFreezeResponse(response)
		if err != nil {
			dispatchErrors = append(dispatchErrors, fmt.Errorf("dispatch stun for actor %q chain %q: %w", match.ActorID, match.ChainID, err))
			continue
		}
		match.StunDispatched = true
	}

	return cloneChainMatches(matches), errors.Join(dispatchErrors...)
}

func groupFindingsByResolvedActor(observations []model.Observation) map[string][]model.Observation {
	groups := make(map[string][]model.Observation)
	for _, observation := range observations {
		actorID := observation.ActorID
		if actorID == "" {
			actorID = observation.PrincipalID
		}
		if actorID == "" {
			continue
		}
		groups[actorID] = append(groups[actorID], cloneObservation(observation))
	}
	for actorID := range groups {
		sort.Slice(groups[actorID], func(i, j int) bool {
			if groups[actorID][i].Timestamp.Equal(groups[actorID][j].Timestamp) {
				return groups[actorID][i].ID < groups[actorID][j].ID
			}
			return groups[actorID][i].Timestamp.Before(groups[actorID][j].Timestamp)
		})
	}
	return groups
}

func matchAttackChain(actorID string, findings []model.Observation, chain AttackChain) (ChainMatch, bool) {
	if len(chain.Stages) == 0 || chain.Window <= 0 {
		return ChainMatch{}, false
	}
	for anchorIndex, anchor := range findings {
		if !stageMatches(chain.Stages[0], anchor) {
			continue
		}
		selected := []model.Observation{anchor}
		usedIDs := map[string]struct{}{anchor.ID: {}}
		previousIndex := anchorIndex
		complete := true
		for stageIndex := 1; stageIndex < len(chain.Stages); stageIndex++ {
			found := false
			for candidateIndex := previousIndex + 1; candidateIndex < len(findings); candidateIndex++ {
				candidate := findings[candidateIndex]
				if _, used := usedIDs[candidate.ID]; used || !stageMatches(chain.Stages[stageIndex], candidate) {
					continue
				}
				selected = append(selected, candidate)
				usedIDs[candidate.ID] = struct{}{}
				previousIndex = candidateIndex
				found = true
				break
			}
			if !found {
				complete = false
				break
			}
		}
		if !complete || selected[len(selected)-1].Timestamp.Sub(selected[0].Timestamp) > chain.Window {
			continue
		}

		evidence := make([]model.EvidenceLink, 0, len(selected))
		observationIDs := make([]string, 0, len(selected))
		for index, finding := range selected {
			observationIDs = append(observationIDs, finding.ID)
			evidence = append(evidence, model.EvidenceLink{
				ObservationID: finding.ID,
				Layer:         finding.Layer,
				Fidelity:      finding.Fidelity,
				Contribution:  chain.Stages[index].Label,
				Timestamp:     finding.Timestamp,
			})
		}
		return ChainMatch{
			ChainID:        chain.ID,
			ActorID:        actorID,
			ObservationIDs: observationIDs,
			FirstAt:        selected[0].Timestamp,
			LastAt:         selected[len(selected)-1].Timestamp,
			Confidence:     completedChainConfidence(evidence),
		}, true
	}
	return ChainMatch{}, false
}

func stageMatches(stage ChainStage, observation model.Observation) bool {
	if stage.Layer != "" && observation.Layer != stage.Layer {
		return false
	}
	if len(stage.Sources) == 0 {
		return true
	}
	for _, source := range stage.Sources {
		if observation.Source == source {
			return true
		}
	}
	return false
}

// completedChainConfidence models a completed chain as strong evidence: the
// first stage establishes 0.75 risk, each distinct corroborating stage adds
// 0.08, and the fidelity-derived evidence score contributes up to 0.05.
func completedChainConfidence(evidence []model.EvidenceLink) float64 {
	if len(evidence) == 0 {
		return 0
	}
	derived := model.DeriveConfidence(evidence).Score
	score := 0.75 + (0.08 * float64(len(evidence)-1)) + (0.05 * derived)
	if score > 1 {
		return 1
	}
	return score
}

func attackChainByID(chains []AttackChain, id string) (AttackChain, bool) {
	for _, chain := range chains {
		if chain.ID == id {
			return chain, true
		}
	}
	return AttackChain{}, false
}

func sortChainMatches(matches []ChainMatch) {
	sort.Slice(matches, func(i, j int) bool {
		if matches[i].ActorID != matches[j].ActorID {
			return matches[i].ActorID < matches[j].ActorID
		}
		if matches[i].ChainID != matches[j].ChainID {
			return matches[i].ChainID < matches[j].ChainID
		}
		if !matches[i].FirstAt.Equal(matches[j].FirstAt) {
			return matches[i].FirstAt.Before(matches[j].FirstAt)
		}
		return matches[i].LastAt.Before(matches[j].LastAt)
	})
}

func cloneChainMatches(matches []ChainMatch) []ChainMatch {
	cloned := make([]ChainMatch, len(matches))
	for index, match := range matches {
		cloned[index] = match
		cloned[index].ObservationIDs = append([]string(nil), match.ObservationIDs...)
		cloned[index].StunResponse = cloneStunFreezeResponse(match.StunResponse)
	}
	return cloned
}

func cloneStunFreezeResponse(response *StunFreezeResponse) *StunFreezeResponse {
	if response == nil {
		return nil
	}
	cloned := *response
	cloned.PIDs = append([]int(nil), response.PIDs...)
	return &cloned
}
