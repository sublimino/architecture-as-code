// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Windows is stage 2: in-memory sliding counters over stage-1 findings, declared
// in the bundle and never in CEL (§3, D2, D3).
//
// # Keying
//
// A counter is identified by the window ID plus the window's declared key
// dimensions, evaluated against the finding. The grammar is obscel's:
// tenant_id, actor, rule_id, or labels.<key>. Dimension ORDER is the bundle's
// declared order, so the key string is stable across processes.
//
// # Firing
//
// A decision fires on the EDGE: when an arriving finding takes the counter from
// below the threshold to at or above it. It does not re-fire while the counter
// stays above the threshold, and it re-arms once pruning drops the count back
// below. The alternative — firing on every arrival at or above threshold —
// turns one burst into one alert per event, and the alternative of firing only
// on exact equality never re-arms after an out-of-order arrival.
//
// # Pruning
//
// The sliding window is anchored on the ARRIVING finding's timestamp: entries
// older than arrival - Window are dropped, boundary inclusive. Anchoring on
// wall-clock time would make a replay of the backlog disagree with live, which
// is exactly what the determinism contract forbids.
type Windows struct {
	mu       sync.Mutex
	specs    []windowSpec
	counters map[string]*counter
	log      *slog.Logger
}

// windowSpec pairs a declared window with the bundle that declared it, so a
// decision can carry the bundle identity and mode the promotion audit reads.
type windowSpec struct {
	bundle *obscel.Bundle
	window obscel.Window
}

// counter is one keyed sliding window.
type counter struct {
	entries []entry
	// crossed is the edge-trigger latch. Warm-up sets it without emitting, so a
	// restart over an already-breached window does not re-alert history.
	crossed bool
}

type entry struct {
	at time.Time
	id string
}

// NewWindows builds stage 2 from the boot-loaded bundle set. Windows are indexed
// in sorted (bundle identity, window ID) order so two processes loading the same
// tree offer findings to the same windows in the same order.
func NewWindows(bundles []*obscel.Bundle) *Windows {
	return NewWindowsWithLogger(bundles, slog.Default())
}

// NewWindowsWithLogger is NewWindows with an explicit logger.
func NewWindowsWithLogger(bundles []*obscel.Bundle, log *slog.Logger) *Windows {
	if log == nil {
		log = slog.Default()
	}
	var specs []windowSpec
	for _, b := range bundles {
		for _, w := range b.Windows {
			specs = append(specs, windowSpec{bundle: b, window: w})
		}
	}
	sort.SliceStable(specs, func(i, j int) bool {
		li := bundleIdentity(specs[i].bundle) + "|" + specs[i].window.ID
		lj := bundleIdentity(specs[j].bundle) + "|" + specs[j].window.ID
		return li < lj
	})
	return &Windows{specs: specs, counters: make(map[string]*counter), log: log}
}

func bundleIdentity(b *obscel.Bundle) string {
	return b.TenantID + "/" + b.ID + "@" + b.Version
}

// Len reports how many windows are declared across the loaded bundle set.
func (ws *Windows) Len() int {
	if ws == nil {
		return 0
	}
	return len(ws.specs)
}

// LongestWindow is the warm-up horizon: the longest window any loaded bundle
// declares. Reading further back than this cannot change any counter, and
// reading less far back silently under-counts a window that was mid-flight when
// the process restarted.
func (ws *Windows) LongestWindow() time.Duration {
	if ws == nil {
		return 0
	}
	var longest time.Duration
	for _, s := range ws.specs {
		if s.window.Window > longest {
			longest = s.window.Window
		}
	}
	return longest
}

// Offer feeds one finding to every window declared over its rule by its bundle,
// returning the decisions that fired, in window order.
func (ws *Windows) Offer(f obscel.Finding, b *obscel.Bundle) []obscel.Decision {
	return ws.offer(f, b, true)
}

func (ws *Windows) offer(f obscel.Finding, b *obscel.Bundle, emit bool) []obscel.Decision {
	if ws == nil || len(ws.specs) == 0 {
		return nil
	}
	ws.mu.Lock()
	defer ws.mu.Unlock()

	var out []obscel.Decision
	for _, spec := range ws.specs {
		if spec.window.OverRule != f.RuleID {
			continue
		}
		// A window belongs to its own bundle version. Without this a bundle
		// promoted from 1.0.0 to 1.1.0 would accumulate findings from both into
		// one counter, and the decision would cite a version that produced only
		// some of its evidence.
		if b != nil && bundleIdentity(spec.bundle) != bundleIdentity(b) {
			continue
		}

		key := spec.window.ID + "\x00" + windowKey(spec.window, f)
		c := ws.counters[key]
		if c == nil {
			c = &counter{}
			ws.counters[key] = c
		}

		c.insert(f, spec.window.Window)
		above := len(c.entries) >= spec.window.Threshold

		switch {
		case above && !c.crossed:
			c.crossed = true
			if emit {
				out = append(out, ws.decision(spec, f, c))
			}
		case !above:
			c.crossed = false
		}
	}
	return out
}

// insert adds the finding and prunes the window, keeping entries in sorted
// (timestamp, id) order so the finding-ID set a decision hashes is reproducible
// regardless of arrival order. Duplicate IDs are idempotent: the same finding
// replayed twice must not count twice.
func (c *counter) insert(f obscel.Finding, window time.Duration) {
	for _, e := range c.entries {
		if e.id == f.ID {
			return
		}
	}
	c.entries = append(c.entries, entry{at: f.Timestamp, id: f.ID})
	sort.Slice(c.entries, func(i, j int) bool {
		if !c.entries[i].at.Equal(c.entries[j].at) {
			return c.entries[i].at.Before(c.entries[j].at)
		}
		return c.entries[i].id < c.entries[j].id
	})

	cutoff := f.Timestamp.Add(-window)
	kept := c.entries[:0]
	for _, e := range c.entries {
		if !e.at.Before(cutoff) {
			kept = append(kept, e)
		}
	}
	c.entries = kept
}

// decision renders the fired decision. Every field is derived: the ID is
// obscel.DecisionID over the sorted finding IDs and the timestamp is the
// TRIGGERING finding's, never time.Now().
func (ws *Windows) decision(spec windowSpec, trigger obscel.Finding, c *counter) obscel.Decision {
	ids := make([]string, 0, len(c.entries))
	for _, e := range c.entries {
		ids = append(ids, e.id)
	}
	ids = sortedCopy(ids)

	return obscel.Decision{
		ID:            obscel.DecisionID(trigger.TenantID, trigger.RuleID, windowKey(spec.window, trigger), ids),
		Timestamp:     trigger.Timestamp,
		TenantID:      trigger.TenantID,
		Actor:         trigger.Actor,
		WindowID:      spec.window.ID,
		RuleID:        trigger.RuleID,
		BundleID:      spec.bundle.ID,
		BundleVersion: spec.bundle.Version,
		Severity:      spec.window.Severity,
		Mode:          spec.bundle.Mode,
		FindingIDs:    ids,
		Count:         len(ids),
	}
}

// windowKey renders the declared key dimensions against a finding, in the
// bundle's declared order.
func windowKey(w obscel.Window, f obscel.Finding) string {
	parts := make([]string, 0, len(w.Key))
	for _, k := range w.Key {
		switch k {
		case obscel.KeyTenantID:
			parts = append(parts, k+"="+f.TenantID)
		case obscel.KeyActor:
			parts = append(parts, k+"="+f.Actor)
		case obscel.KeyRuleID:
			parts = append(parts, k+"="+f.RuleID)
		default:
			// Conform has already rejected anything that is neither of the above
			// nor a labels.<key>, so this branch is the label case.
			parts = append(parts, k+"="+f.Labels[strings.TrimPrefix(k, obscel.KeyLabelPrefix)])
		}
	}
	return strings.Join(parts, "|")
}

// Warm rebuilds the counters from stored findings at boot (ISC-50).
//
// It is the ONLY read this package makes of the store on a live path, and it
// happens exactly once before the first collector starts. It reads back
// LongestWindow() from `now`, filters to Source == obscel.SourceFinding, and
// offers each finding in sorted (timestamp, id) order WITHOUT emitting: a
// restart must not re-alert a decision the previous process already alerted,
// but must leave the counter in the state that process had, so the next arriving
// finding crosses the threshold at the same point.
//
// # The one lossy dimension, stated plainly
//
// A stored finding carries the closed policy label set, not the source
// observation's labels (see findingObservation). So a window keyed on a
// `labels.<key>` dimension CANNOT be rebuilt faithfully — every warmed finding
// reads an empty value for that dimension and collapses into one counter.
// Warm logs a warning naming each such window rather than silently
// mis-counting. The first shipped bundle keys on [tenant_id, actor], both of
// which survive the projection.
func (ws *Windows) Warm(ctx context.Context, st store.SignalStore, now time.Time) error {
	if ws == nil || len(ws.specs) == 0 || st == nil {
		return nil
	}

	horizon := ws.LongestWindow()
	if horizon <= 0 {
		return nil
	}
	for _, s := range ws.specs {
		for _, k := range s.window.Key {
			if strings.HasPrefix(k, obscel.KeyLabelPrefix) {
				ws.log.Warn("stage-2 window keys on a source-observation label, which a stored finding does not carry; warm-up will under-key this window",
					"window", s.window.ID, "bundle", s.bundle.ID, "key", k)
			}
		}
	}

	// Before is left zero: MemoryStore and FrostDB both treat a zero Before as
	// "no upper bound", and bounding it at `now` would drop a finding whose
	// timestamp is the same instant.
	rows, err := st.QueryRange(ctx, store.Query{After: now.Add(-horizon)})
	if err != nil {
		return err
	}

	findings := make([]obscel.Finding, 0, len(rows))
	for _, row := range rows {
		if !isFinding(row) {
			continue
		}
		findings = append(findings, findingFromObservation(row))
	}
	sort.Slice(findings, func(i, j int) bool {
		if !findings[i].Timestamp.Equal(findings[j].Timestamp) {
			return findings[i].Timestamp.Before(findings[j].Timestamp)
		}
		return findings[i].ID < findings[j].ID
	})

	byIdentity := make(map[string]*obscel.Bundle, len(ws.specs))
	for _, s := range ws.specs {
		byIdentity[bundleIdentity(s.bundle)] = s.bundle
	}

	warmed := 0
	for _, f := range findings {
		b := byIdentity[f.TenantID+"/"+f.BundleID+"@"+f.BundleVersion]
		if b == nil {
			// A finding from a bundle version that is no longer loaded. Counting it
			// would attribute old evidence to a new policy.
			continue
		}
		ws.offer(f, b, false)
		warmed++
	}

	ws.log.Info("stage-2 warm-up complete",
		"horizon", horizon.String(), "findings_replayed", warmed, "windows", len(ws.specs))
	return nil
}

// WarmedCount reports how many findings a Warm call folded in. Test-facing.
func (ws *Windows) WarmedCount() int {
	if ws == nil {
		return 0
	}
	ws.mu.Lock()
	defer ws.mu.Unlock()
	n := 0
	for _, c := range ws.counters {
		n += len(c.entries)
	}
	return n
}

// isFinding is the one definition of "this stored row is a stage-1 finding", so
// warm-up and replay cannot drift apart on the filter.
func isFinding(o model.Observation) bool { return o.Source == obscel.SourceFinding }
