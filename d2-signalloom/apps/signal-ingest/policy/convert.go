// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"strconv"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
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

	// LabelActor carries the PSEUDONYMOUS actor identity onto a stored finding
	// and a stored decision.
	//
	// The key is `actor_pseudonym` and not `actor` on purpose: `actor` is on the
	// segment allow-list's forbidden-key list, because that list bounds KEYS and
	// never VALUES and so a legitimate-looking `actor` key would be an open door
	// for a collector to ship a cleartext identity. This name states its value
	// class instead.
	//
	// ActorHint on the derived observation is not enough on its own. Under
	// segment schema v2 the store pseudonymises ActorHint again on write and the
	// read path returns no cleartext column at all, so warm-up could not recover
	// an actor from a stored finding and every window keyed on `actor` would
	// collapse into a single counter after a restart -- a pod coming up with one
	// merged counter instead of one per identity.
	//
	// A label round-trips, because labels are the one part of an observation the
	// v2 schema carries verbatim. The value is already a pseudonym when it gets
	// here, so this adds no cleartext identity to the segment.
	LabelActor = "actor_pseudonym"
)

// closedPolicyLabelKeys is the closed label set findingObservation writes. It
// exists so a window-keyed label dimension cannot silently overwrite a policy
// field: a bundle may legally declare a window over `labels.severity`, and
// copying the source observation's `severity` onto the finding would replace the
// RULE's severity with the record's.
var closedPolicyLabelKeys = map[string]struct{}{
	LabelRuleID: {}, LabelBundleID: {}, LabelBundleVersion: {}, LabelSeverity: {},
	LabelSourceObsID: {}, LabelMode: {}, LabelWindowID: {}, LabelCount: {},
	LabelFindingIDs: {}, LabelActor: {}, TenantLabel: {},
}

// ActorIdentity resolves the pseudonymous actor identity of an observation.
//
// This function is the whole of the replay-parity fix, so it is worth being
// explicit about what it reconciles.
//
// Two live contracts collided. The SLDP downstream contract says a segment holds
// pseudonyms only: FrostDBStore.Append writes `hmac_actor_hint` and no
// `actor_hint` column exists in the v2 layout, so every observation read back
// carries an EMPTY ActorHint. The SLAWS replay-oracle claim (ISC-55) says a
// replay of the backlog reproduces live output. Before this change, replay read
// those rows, toObscel mapped the empty ActorHint onto obs.actor, and every rule
// saw an empty actor -- so the allowlist negatives that every shipped rule is
// written as (`!(obs.actor in vars.break_glass_actors)`) were SATISFIED, firing
// against the identities an operator had deliberately exempted, while
// `obs.actor != ""` guards dropped true positives and actor-keyed windows
// merged. Measured on the Kusari corpus: live 62 findings / 3 decisions, replay
// 64 / 2. Wrong in both directions at once.
//
// The resolution is that THE PSEUDONYM IS THE ACTOR IDENTITY, everywhere in
// policy, on both paths. So:
//
//   - A row read back from a v2 segment already holds the pseudonym the store
//     computed with the store's own key. Use it verbatim. Recomputing it is not
//     possible -- the cleartext is gone -- and that is the point of the schema.
//   - A live observation, or a row from a v1 segment, holds cleartext. Pass it
//     through the SAME pseudonymiser, with the same key, tenant scope and epoch,
//     so it lands on the identical value the v2 row would have stored. The
//     V1CleartextMatchesV2Pseudonym test pins exactly that, because a corpus
//     spanning the schema change is the documented steady state and counting one
//     identity as two across it would be a silent miscount.
//   - No actor stays no actor. The pseudonymiser returns "" for "" by design;
//     hashing "" would write one constant digest into every VPC Flow record,
//     which is both a join key linking every identity-free record and a value
//     that makes `obs.actor != ""` true for all of them.
//
// A nil pseudonymiser falls back to the cleartext hint. That is NOT a safe
// default and it is not silent: NewSink logs a warning naming the consequence.
// It exists because a binary built without key material can still run
// MemoryStore for development, where no v2 segment can be read and so no
// divergence can arise. Every production path supplies one -- under -tags
// frostdb the store refuses to start without key material at all.
func ActorIdentity(obs *model.Observation, p store.ActorPseudonymiser) (string, error) {
	if obs == nil {
		return "", nil
	}
	if obs.HMACActorHint != "" {
		return obs.HMACActorHint, nil
	}
	if obs.ActorHint == "" {
		return "", nil
	}
	if p == nil {
		return obs.ActorHint, nil
	}
	return p.Pseudonym(obs.ActorHint)
}

// toObscel projects a model.Observation onto the CEL vocabulary.
//
// Actor derives from ActorHint, not ActorID: ActorHint is what every collector
// populates and what the §2.3 contract documents. Reading the resolved ActorID
// here would make a rule's behaviour depend on whether the resolution spine had
// caught up with the record.
//
// It is the PSEUDONYM of that hint rather than the hint itself -- see
// ActorIdentity for why, and for why that has to be true on the live path and
// not only on replay.
func toObscel(obs *model.Observation, p store.ActorPseudonymiser) (obscel.Observation, error) {
	actor, err := ActorIdentity(obs, p)
	if err != nil {
		return obscel.Observation{}, err
	}
	return obscel.Observation{
		ID:         obs.ID,
		Timestamp:  obs.Timestamp,
		Layer:      string(obs.Layer),
		Source:     obs.Source,
		Fidelity:   string(obs.Fidelity),
		Confidence: obs.Confidence,
		TenantID:   obs.Labels[TenantLabel],
		Actor:      actor,
		Labels:     obs.Labels,
	}, nil
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
// keyedLabels names the source-observation label keys a stage-2 window declares
// as a key dimension over this finding's rule. Those values are copied onto the
// stored finding so warm-up can rebuild the counter; see Windows.Warm.
func findingObservation(f obscel.Finding, src *model.Observation, mode obscel.Mode, keyedLabels []string) model.Observation {
	labels := map[string]string{
		LabelRuleID:        f.RuleID,
		LabelBundleID:      f.BundleID,
		LabelBundleVersion: f.BundleVersion,
		LabelSeverity:      f.Severity,
		TenantLabel:        f.TenantID,
		LabelSourceObsID:   f.SourceObsID,
		LabelMode:          string(mode),
		LabelActor:         f.Actor,
	}
	// The keyed dimensions of every window over this rule.
	//
	// Without this a window keyed on `labels.source_ip` could not be rebuilt at
	// boot: the stored finding carried the closed policy set only, so every
	// warmed finding read an empty value for that dimension and twenty hosts
	// each retrying once warmed as one host scanning twenty times. The
	// vpc-reject-burst-5m window in cloud-signals.yaml documents that limit and
	// names policy/convert.go as the fix; this is it.
	//
	// It stays an ALLOWLIST of what a window actually keys on rather than a copy
	// of the source labels, because copying them all would re-expose a projected
	// cloud label under a policy source -- which is the property the closed set
	// exists to guarantee. A key that collides with a policy field is skipped:
	// a window over `labels.severity` must not replace the RULE's severity with
	// the record's.
	for _, k := range keyedLabels {
		if _, reserved := closedPolicyLabelKeys[k]; reserved {
			continue
		}
		if v, ok := f.Labels[k]; ok && v != "" {
			labels[k] = v
		}
	}
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
		Labels:         labels,
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
			// The pseudonymous actor, for the same reason the finding carries it:
			// a v2 segment returns no cleartext actor column, so a reviewer
			// querying "which decisions name this identity" needs the value in a
			// field that round-trips. It is already a pseudonym here.
			LabelActor: d.Actor,
		},
	}
}

// findingFromObservation rebuilds a stage-1 finding from its stored projection.
// Used by warm-up only.
//
// Labels are the policy label set plus the window-keyed dimensions
// findingObservation copied onto it, so a window keyed on `labels.<key>` now
// rebuilds faithfully where it previously collapsed.
//
// Actor comes from the LabelActor label, not from ActorHint: under segment
// schema v2 the store writes no cleartext actor column, so ActorHint is empty on
// every row read back and an actor-keyed window would warm into one merged
// counter. ActorHint is the fallback for rows written before LabelActor existed
// — a v1 segment, or a finding stored by an older binary — where it holds the
// value that was current then.
func findingFromObservation(obs model.Observation) obscel.Finding {
	actor := obs.Labels[LabelActor]
	if actor == "" {
		actor = obs.ActorHint
	}
	return obscel.Finding{
		ID:            obs.ID,
		Timestamp:     obs.Timestamp,
		TenantID:      obs.Labels[TenantLabel],
		Actor:         actor,
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

// pseudonymiserSource is implemented by a store that owns keyed pseudonymisation
// — FrostDBStore does, and it is the only one. The interface is declared here,
// at the consumer, so this package compiles identically with and without the
// frostdb build tag: MemoryStore simply does not satisfy it.
type pseudonymiserSource interface {
	Pseudonymiser() *store.SegmentPseudonymiser
}

// StorePseudonymiser returns the store's own actor pseudonymiser, or nil.
//
// Taking the store's INSTANCE rather than building a second one from the
// environment is the point. The two would agree only while key, tenant scope and
// epoch all agreed, and the failure when they drifted would be silent: findings
// against an identity nobody can match, allowlists that stop matching, and a
// replay that disagrees with live for a reason no log names. One instance cannot
// drift from itself.
//
// nil is correct for MemoryStore and is not a downgrade: a store that writes no
// pseudonymised segment can return no pseudonymised row, so there is no second
// representation for the live path to disagree with. policy.NewSink warns, and
// under -tags frostdb a store with no key material refuses to start at all, so
// the production path cannot reach here with nil.
func StorePseudonymiser(st store.SignalStore) store.ActorPseudonymiser {
	src, ok := st.(pseudonymiserSource)
	if !ok {
		return nil
	}
	p := src.Pseudonymiser()
	if p == nil {
		return nil
	}
	return p
}
