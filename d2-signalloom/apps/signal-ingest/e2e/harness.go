// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package e2e

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Tenant and Region are the collector configuration for the pilot. Tenancy is
// configuration and never read from a record (SLAWS D7); Region is the VPC Flow
// fallback, whose lines carry no region of their own.
const (
	Tenant = "kusari"
	Region = "us-east-1"
)

// RepoBundlesDir is the Flux-reconciled bundle tree, reached from this package.
//
// It returns the directory rather than a loaded set so the caller can point the
// mutation gate at an empty directory instead, with everything else unchanged.
func RepoBundlesDir() (string, error) {
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "policy", "bundles"))
	if err != nil {
		return "", fmt.Errorf("e2e: resolving the bundle dir: %w", err)
	}
	for _, want := range []string{
		filepath.Join(dir, "kusari", "iam-change.yaml"),
		filepath.Join(dir, "kusari", "cloud-signals.yaml"),
	} {
		if _, err := os.Stat(want); err != nil {
			return "", fmt.Errorf("e2e: shipped bundle %s not found: %w", want, err)
		}
	}
	return dir, nil
}

// Recorder accumulates what stage 1 and stage 2 actually SAW, by id.
//
// Counting the observer rather than the stored rows is deliberate and it is the
// only way the second-pass claim means anything: a dedupe that suppressed only
// the duplicate finding WRITE would leave the burst already counted, and no
// assertion over stored observations could tell the difference.
type Recorder struct {
	Findings  []obscel.Finding
	Decisions []obscel.Decision

	findingSeen  map[string]int
	decisionSeen map[string]int
}

// NewRecorder returns an empty Recorder.
func NewRecorder() *Recorder {
	return &Recorder{findingSeen: map[string]int{}, decisionSeen: map[string]int{}}
}

// OnFinding implements policy.Observer.
func (r *Recorder) OnFinding(f obscel.Finding) {
	r.Findings = append(r.Findings, f)
	r.findingSeen[f.ID]++
}

// OnDecision implements policy.Observer.
func (r *Recorder) OnDecision(d obscel.Decision) {
	r.Decisions = append(r.Decisions, d)
	r.decisionSeen[d.ID]++
}

// RepeatedFindings returns the finding IDs stage 1 evaluated more than once.
// Non-empty means a redelivery reached the evaluator.
func (r *Recorder) RepeatedFindings() []string { return repeated(r.findingSeen) }

// RepeatedDecisions returns the decision IDs stage 2 produced more than once.
func (r *Recorder) RepeatedDecisions() []string { return repeated(r.decisionSeen) }

func repeated(seen map[string]int) []string {
	var out []string
	for id, n := range seen {
		if n > 1 {
			out = append(out, fmt.Sprintf("%s x%d", id, n))
		}
	}
	sort.Strings(out)
	return out
}

// FindingsByRule counts findings per (bundle, rule).
func (r *Recorder) FindingsByRule() map[string]int {
	out := map[string]int{}
	for _, f := range r.Findings {
		out[f.BundleID+"/"+f.RuleID]++
	}
	return out
}

// DecisionsByWindow counts decisions per (bundle, window).
func (r *Recorder) DecisionsByWindow() map[string]int {
	out := map[string]int{}
	for _, d := range r.Decisions {
		out[d.BundleID+"/"+d.WindowID]++
	}
	return out
}

// CanonicalLines is the sorted canonical projection of everything recorded: the
// same projection policy.Replay writes, so the two are comparable as text.
//
// Sorting is what makes the comparison a claim about CONTENT. Two runs that
// produce the same set in a different order are the same run as far as the
// oracle is concerned, and an order difference that mattered would surface as a
// window or decision difference instead.
func (r *Recorder) CanonicalLines() []string {
	findings := make([]string, 0, len(r.Findings))
	for _, f := range r.Findings {
		findings = append(findings, obscel.CanonicalFinding(f))
	}
	decisions := make([]string, 0, len(r.Decisions))
	for _, d := range r.Decisions {
		decisions = append(decisions, policy.CanonicalDecision(d))
	}
	sort.Strings(findings)
	sort.Strings(decisions)
	return append(findings, decisions...)
}

// Harness is the production chain over one store, with one shared accepted-ID
// set and one recorder.
type Harness struct {
	Store    store.SignalStore
	Deduper  *collectors.Deduper
	Recorder *Recorder
	Metrics  *policy.Metrics
	Bundles  []*obscel.Bundle

	bound collectors.IngestionSink
}

// NewHarness composes the production chain over st, with bundles loaded from
// bundlesDir.
//
// The composition order is main.go's and the order matters. The binder is
// OUTSIDE policy: stage 1 resolves bundles from the tenant_id label on the
// observation it is HANDED, so whatever establishes tenancy must run first.
// Were the binder inside, an observation whose tenant the collector supplies by
// configuration would reach stage 1 unstamped, resolve zero bundles, and be
// silently undetected — a no-op detection control that looks exactly like a
// quiet estate.
func NewHarness(st store.SignalStore, bundlesDir string, deduper *collectors.Deduper, log *slog.Logger) (*Harness, error) {
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	bundles, err := policy.LoadBundles(bundlesDir, log)
	if err != nil {
		return nil, fmt.Errorf("e2e: loading bundles from %s: %w", bundlesDir, err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		return nil, fmt.Errorf("e2e: evaluator: %w", err)
	}

	rec := NewRecorder()
	metrics := policy.NewMetrics()
	storeSink := collectors.NewStoreSink(st)

	// obs.actor is the keyed pseudonym on both the live and the replay path, and
	// it must be the STORE'S OWN pseudonymiser, not a second one over the same
	// environment: the live observation and the segment row it becomes have to
	// project onto one identity. Under FrostDB this is the instance the store
	// writes hmac_actor_hint with; under MemoryStore it is nil and the cleartext
	// hint passes through, which is consistent because a MemoryStore returns no
	// pseudonymised row for replay to read.
	pseudo := policy.StorePseudonymiser(st)

	sink := policy.NewSink(storeSink, st, evaluator, policy.StaticBundles(bundles), policy.Options{
		Windows:            policy.NewWindowsWithLogger(bundles, log),
		Metrics:            metrics,
		Observer:           rec,
		Logger:             log,
		ActorPseudonymiser: pseudo,
		// Derived records go through the dedupe seam; the source observation
		// does not, because it was claimed upstream and would otherwise be
		// refused as a duplicate of its own claim.
		DerivedSink: collectors.NewDedupeSink(storeSink, deduper),
	})

	return &Harness{
		Store:    st,
		Deduper:  deduper,
		Recorder: rec,
		Metrics:  metrics,
		Bundles:  bundles,
		bound:    collectors.BindTenant(collectors.NewDedupeSink(sink, deduper), Tenant),
	}, nil
}

// Ingest feeds the corpus through the chain in canonical (timestamp, ID) order
// — the order replay will use, which is what makes a byte-equality claim about
// the PIPELINE rather than about the store's read order.
//
// The corpus is copied before sorting: sorting the caller's slice in place would
// make a second Ingest of "the same" corpus a different arrival order.
func (h *Harness) Ingest(ctx context.Context, corpus []model.Observation) error {
	ordered := append([]model.Observation(nil), corpus...)
	policy.SortObservations(ordered)
	for i := range ordered {
		if err := h.bound.IngestObservation(ctx, &ordered[i]); err != nil {
			return fmt.Errorf("e2e: ingesting %s (%s): %w", ordered[i].ID, ordered[i].RawEvidenceRef, err)
		}
	}
	return nil
}

// Rows returns every stored row.
func (h *Harness) Rows(ctx context.Context) ([]model.Observation, error) {
	return h.Store.QueryRange(ctx, store.Query{})
}

// Tally is the row census by kind.
type Tally struct {
	Observations, Findings, Decisions int
}

// Census counts stored rows by kind.
func Census(rows []model.Observation) Tally {
	var t Tally
	for _, r := range rows {
		switch r.Source {
		case obscel.SourceFinding:
			t.Findings++
		case obscel.SourceDecision:
			t.Decisions++
		default:
			t.Observations++
		}
	}
	return t
}

// KusariCorpus is the Kusari pilot fixture projection.
func KusariCorpus() ([]model.Observation, error) {
	obs, err := awslogs.KusariFixtureObservations(Tenant, Region)
	if err != nil {
		return nil, err
	}
	if len(obs) == 0 {
		return nil, fmt.Errorf("e2e: the kusari fixture corpus is empty; every assertion would be vacuous")
	}
	return obs, nil
}

// Bracket returns a range that strictly contains every timestamp in corpus, for
// a replay query. It is widened by an hour on each side rather than computed
// exactly because store.Query's bounds differ in inclusivity between the two
// store implementations, and a boundary observation dropped from one side of the
// replay would read as a policy difference.
func Bracket(corpus []model.Observation) (from, to time.Time) {
	if len(corpus) == 0 {
		return time.Time{}, time.Time{}
	}
	from, to = corpus[0].Timestamp, corpus[0].Timestamp
	for _, o := range corpus {
		if o.Timestamp.Before(from) {
			from = o.Timestamp
		}
		if o.Timestamp.After(to) {
			to = o.Timestamp
		}
	}
	return from.Add(-time.Hour), to.Add(time.Hour)
}

// SummaryTable renders the stage-1 and stage-2 outcome as a fixed-width table,
// so a run's output is readable in CI logs rather than being a count to decode.
func SummaryTable(rules []ruleExpectation, windows []windowExpectation, byRule, byWindow map[string]int, t Tally) string {
	var b strings.Builder
	b.WriteString("\nKusari AWS signal e2e — stage 1\n")
	b.WriteString("  bundle               rule                              want  got  status\n")
	b.WriteString("  -------------------- --------------------------------- ----- ---- ------\n")
	for _, r := range rules {
		got := byRule[r.Bundle+"/"+r.Rule]
		fmt.Fprintf(&b, "  %-20s %-33s %5d %4d  %s\n",
			shortBundle(r.Bundle), r.Rule, r.Findings, got, okMark(got == r.Findings))
	}
	b.WriteString("\nKusari AWS signal e2e — stage 2\n")
	b.WriteString("  bundle               window                            want  got  status\n")
	b.WriteString("  -------------------- --------------------------------- ----- ---- ------\n")
	for _, w := range windows {
		got := byWindow[w.Bundle+"/"+w.Window]
		fmt.Fprintf(&b, "  %-20s %-33s %5d %4d  %s\n",
			shortBundle(w.Bundle), w.Window, w.Decisions, got, okMark(got == w.Decisions))
	}
	fmt.Fprintf(&b, "\n  stored: %s observations, %s findings, %s decisions\n",
		strconv.Itoa(t.Observations), strconv.Itoa(t.Findings), strconv.Itoa(t.Decisions))
	return b.String()
}

func shortBundle(id string) string { return strings.TrimPrefix(id, "kusari-") }

func okMark(ok bool) string {
	if ok {
		return "ok"
	}
	return "DRIFT"
}
