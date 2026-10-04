// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"strconv"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// TenantLabel is the label every path (collector config, HTTP binder) stamps the
// tenant into. obscel.Observation.TenantID is read from it rather than from a
// dedicated struct field because model.Observation has no tenant column: the
// label IS the tenancy on the wire (§2.3, D7).
const TenantLabel = "tenant_id"

// Closed label sets written onto a finding and a decision observation. Both are
// exhaustive: nothing else is added, and in particular the source observation's
// own labels are NOT copied, so a stored finding cannot re-expose a projected
// cloud label under a policy source.
const (
	LabelRuleID        = "rule_id"
	LabelBundleID      = "bundle_id"
	LabelBundleVersion = "bundle_version"
	LabelSeverity      = "severity"
	LabelSourceObsID   = "source_observation_id"
	LabelMode          = "mode"
	LabelWindowID      = "window_id"
	LabelCount         = "count"
	LabelFindingIDs    = "finding_ids"
)

// toObscel projects a model.Observation onto the CEL vocabulary.
//
// Actor is ActorHint, not ActorID: ActorHint is what every collector populates
// and what the §2.3 contract documents, and the store pseudonymises it later.
// Reading the resolved ActorID here would make a rule's behaviour depend on
// whether the resolution spine had caught up with the record.
func toObscel(obs *model.Observation) obscel.Observation {
	return obscel.Observation{
		ID:         obs.ID,
		Timestamp:  obs.Timestamp,
		Layer:      string(obs.Layer),
		Source:     obs.Source,
		Fidelity:   string(obs.Fidelity),
		Confidence: obs.Confidence,
		TenantID:   obs.Labels[TenantLabel],
		Actor:      obs.ActorHint,
		Labels:     obs.Labels,
	}
}

// findingObservation renders a stage-1 finding as a storable observation (D3).
//
// Layer, Fidelity and Confidence are inherited from the source observation: a
// finding is an interpretation of one record and can be no stronger than the
// evidence it rests on, so stamping a fixed tier here would overstate a
// circumstantial match and understate a definitive one.
//
// Every derived field comes from the determinism contract — ID and Timestamp are
// the finding's own (sha256-derived and observation-sourced respectively), never
// generated here.
func findingObservation(f obscel.Finding, src *model.Observation, mode obscel.Mode) model.Observation {
	return model.Observation{
		ID:             f.ID,
		Timestamp:      f.Timestamp,
		Layer:          src.Layer,
		Fidelity:       src.Fidelity,
		Source:         obscel.SourceFinding,
		Confidence:     src.Confidence,
		ActorHint:      f.Actor,
		RawEvidenceRef: f.SourceObsID,
		Description:    findingDescription(f),
		Labels: map[string]string{
			LabelRuleID:        f.RuleID,
			LabelBundleID:      f.BundleID,
			LabelBundleVersion: f.BundleVersion,
			LabelSeverity:      f.Severity,
			TenantLabel:        f.TenantID,
			LabelSourceObsID:   f.SourceObsID,
			LabelMode:          string(mode),
		},
	}
}

// decisionObservation renders a stage-2 decision as a storable observation.
//
// The triggering finding supplies Layer, Fidelity and Confidence for the same
// reason findingObservation inherits them, and supplies the timestamp: a
// decision is stamped with the moment its threshold was crossed in the data, not
// the moment the process noticed.
func decisionObservation(d obscel.Decision, trigger *model.Observation) model.Observation {
	return model.Observation{
		ID:             d.ID,
		Timestamp:      d.Timestamp,
		Layer:          trigger.Layer,
		Fidelity:       trigger.Fidelity,
		Source:         obscel.SourceDecision,
		Confidence:     trigger.Confidence,
		ActorHint:      d.Actor,
		RawEvidenceRef: strings.Join(d.FindingIDs, ","),
		Description:    decisionDescription(d),
		Labels: map[string]string{
			LabelWindowID:      d.WindowID,
			LabelRuleID:        d.RuleID,
			LabelBundleID:      d.BundleID,
			LabelBundleVersion: d.BundleVersion,
			LabelSeverity:      d.Severity,
			LabelMode:          string(d.Mode),
			LabelCount:         strconv.Itoa(d.Count),
			TenantLabel:        d.TenantID,
			LabelFindingIDs:    strings.Join(d.FindingIDs, ","),
		},
	}
}

// findingFromObservation rebuilds a stage-1 finding from its stored projection.
// Used by warm-up only. Labels are the policy label set, not the source
// observation's, so the reconstruction is lossy in exactly one way — see the
// caveat on Windows.Warm.
func findingFromObservation(obs model.Observation) obscel.Finding {
	return obscel.Finding{
		ID:            obs.ID,
		Timestamp:     obs.Timestamp,
		TenantID:      obs.Labels[TenantLabel],
		Actor:         obs.ActorHint,
		RuleID:        obs.Labels[LabelRuleID],
		BundleID:      obs.Labels[LabelBundleID],
		BundleVersion: obs.Labels[LabelBundleVersion],
		Severity:      obs.Labels[LabelSeverity],
		SourceObsID:   obs.Labels[LabelSourceObsID],
		Labels:        obs.Labels,
	}
}

// findingDescription is one line built only from derived policy fields, so no
// projected cloud value is restated under a policy source.
func findingDescription(f obscel.Finding) string {
	return "policy finding: rule " + f.RuleID + " (" + f.BundleID + "@" + f.BundleVersion +
		", severity " + f.Severity + ") matched observation " + f.SourceObsID
}

func decisionDescription(d obscel.Decision) string {
	return "policy decision: window " + d.WindowID + " over rule " + d.RuleID +
		" reached " + strconv.Itoa(d.Count) + " findings (" + d.BundleID + "@" + d.BundleVersion +
		", severity " + d.Severity + ", mode " + string(d.Mode) + ")"
}

// CanonicalDecision is the allowlisted projection of a decision, the stage-2
// counterpart of obscel.CanonicalFinding. It lives here rather than in pkg/obscel
// because that package's types are frozen; the field order mirrors
// CanonicalFinding so a replay diff reads the same way for both stages.
func CanonicalDecision(d obscel.Decision) string {
	var b strings.Builder
	b.WriteString(d.ID)
	b.WriteString("|")
	b.WriteString(d.Timestamp.UTC().Format(canonicalTimeLayout))
	b.WriteString("|")
	b.WriteString(d.TenantID)
	b.WriteString("|")
	b.WriteString(d.Actor)
	b.WriteString("|")
	b.WriteString(d.WindowID)
	b.WriteString("|")
	b.WriteString(d.RuleID)
	b.WriteString("|")
	b.WriteString(d.BundleID)
	b.WriteString("@")
	b.WriteString(d.BundleVersion)
	b.WriteString("|")
	b.WriteString(d.Severity)
	b.WriteString("|")
	b.WriteString(string(d.Mode))
	b.WriteString("|")
	b.WriteString(strconv.Itoa(d.Count))
	b.WriteString("|")
	b.WriteString(strings.Join(sortedCopy(d.FindingIDs), ","))
	return b.String()
}
