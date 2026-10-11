// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"log/slog"
	"sort"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// canonicalTimeLayout matches obscel.CanonicalFinding so both stages render a
// timestamp identically in replay output.
const canonicalTimeLayout = time.RFC3339Nano

// BundleResolver returns the bundles that apply to a tenant, in the loader's
// canonical (sorted path) order. A tenant with no bundle returns nil and is
// evaluated against nothing, which costs one map lookup.
type BundleResolver func(tenant string) []*obscel.Bundle

// Observer is notified of every finding and decision the pipeline produces, in
// the order produced, before either is written.
//
// It exists so that live ingest and replay can be compared on the SAME
// projection (ISC-55). Comparing the STORED finding would compare a lossy
// projection of a finding against a complete one — the stored label set is the
// closed policy set, so a window keyed on a cloud label vanishes from one side
// of the diff and not the other, and the byte-equality claim would be vacuous.
type Observer interface {
	OnFinding(f obscel.Finding)
	OnDecision(d obscel.Decision)
}

// Options are the optional collaborators of a Sink. A zero Options is valid and
// yields stage 1 only, with no counters and no alerting — which is what the
// `POLICY_BUNDLES_DIR` default of "no bundles present" degrades to.
type Options struct {
	// Windows is stage 2. nil disables it: findings are still emitted.
	Windows *Windows
	// Metrics counts findings, decisions and faults. nil is a no-op counter.
	Metrics *Metrics
	// Alerter receives decisions in warn and enforce mode. nil never alerts.
	Alerter Alerter
	// Observer, when non-nil, sees every finding and decision (replay oracle).
	Observer Observer
	// Logger defaults to slog.Default().
	Logger *slog.Logger

	// ActorPseudonymiser turns a cleartext actor hint into the keyed pseudonym
	// that IS the actor identity for every rule and every window (ActorIdentity).
	//
	// It must be the SAME pseudonymiser -- same key, tenant scope and epoch --
	// that the store writes segments with, or a live observation and the row it
	// becomes project onto two different identities and replay diverges from
	// live again, which is the whole defect this field exists to close. Under
	// -tags frostdb, FrostDBStore.Pseudonymiser() hands back exactly that
	// instance and is the only correct source.
	//
	// nil means cleartext passthrough. That is a development affordance for a
	// MemoryStore binary built with no key material, where no v2 segment can be
	// read and so no divergence can arise. NewSink logs a warning naming the
	// consequence, because a silently unpseudonymised live path next to a
	// pseudonymised segment is precisely how the two sides come apart.
	ActorPseudonymiser store.ActorPseudonymiser

	// DerivedSink receives the pipeline's OWN output -- finding and decision
	// observations -- and defaults to the inner sink, which is what every
	// caller before idempotency wanted.
	//
	// It is separate because the ingest path is now deduped on BOTH sides of
	// this sink and the two seams share one accepted-ID set. The source
	// observation is claimed upstream, before stage 1, so that a replay never
	// reaches the evaluator and never advances a stage-2 window. If the
	// pipeline then wrote that same observation back through a sink guarding
	// the same set, the FIRST write would be refused as a duplicate of its own
	// claim. So the source observation goes out through `inner` undecorated
	// (it has already passed the gate) and only derived records -- whose IDs
	// are their own, derived from the finding content -- are offered to the
	// dedupe seam. One claim per record, one entry per ID.
	DerivedSink collectors.IngestionSink
}

// Sink wraps an IngestionSink with the two-stage policy pipeline.
type Sink struct {
	inner    collectors.IngestionSink
	derived  collectors.IngestionSink
	store    store.SignalStore
	eval     obscel.Evaluator
	bundles  BundleResolver
	windows  *Windows
	metrics  *Metrics
	alerter  Alerter
	observer Observer
	log      *slog.Logger
	pseudo   store.ActorPseudonymiser

	// decisionDispatcher, when set, is offered every decision together with its
	// triggering observation (the only site holding both) so a policy FAILURE —
	// e.g. a verified Landlock denial — can be routed to containment (a stun).
	// It fires in every mode, including shadow: the dispatcher itself decides
	// which decisions it acts on and dedups. nil disables the route (today's
	// default when no stun client is configured). See SetDecisionDispatcher.
	decisionDispatcher DecisionDispatcher
}

// DecisionDispatcher routes a policy decision (with its triggering observation)
// to an external effect such as a stun. It is defined here with only
// policy-visible types so this package never imports the containment package
// (no import cycle); main constructs the concrete dispatcher and adapts it.
type DecisionDispatcher interface {
	Dispatch(ctx context.Context, d obscel.Decision, trigger model.Observation)
}

// SetDecisionDispatcher wires the decision→stun route after construction (the
// stun client is built later in main than the Sink). Not safe to call once
// ingestion is running; call it during wiring, before Start.
func (s *Sink) SetDecisionDispatcher(d DecisionDispatcher) { s.decisionDispatcher = d }

// NewSink returns inner wrapped in stage 1 (and stage 2 when opts.Windows is
// set). The returned sink satisfies collectors.IngestionSink, so it drops into
// the place storeSink occupies today and every collector flows through it.
//
// `store` is retained for warm-up and named enrichment only. It is deliberately
// NOT read by IngestObservation — see the package doc and ISC-57.
func NewSink(
	inner collectors.IngestionSink,
	st store.SignalStore,
	eval obscel.Evaluator,
	bundles BundleResolver,
	opts Options,
) collectors.IngestionSink {
	log := opts.Logger
	if log == nil {
		log = slog.Default()
	}
	derived := opts.DerivedSink
	if derived == nil {
		derived = inner
	}
	if opts.ActorPseudonymiser == nil {
		log.Warn("policy has no actor pseudonymiser; obs.actor will be the CLEARTEXT actor hint on this path",
			"consequence", "a replay over a segment-schema-v2 store reads the keyed pseudonym instead, so replay will not reproduce live and every actor allowlist inverts on the replay side",
			"remedy", "pass Options.ActorPseudonymiser, which under -tags frostdb must be FrostDBStore.Pseudonymiser()")
	}
	return &Sink{
		inner:    inner,
		derived:  derived,
		store:    st,
		eval:     eval,
		bundles:  bundles,
		windows:  opts.Windows,
		metrics:  opts.Metrics,
		alerter:  opts.Alerter,
		observer: opts.Observer,
		log:      log,
		pseudo:   opts.ActorPseudonymiser,
	}
}

// IngestObservation stores the observation, then evaluates policy over it.
//
// The only error this can return is the inner sink's error for the SOURCE
// observation. Every policy outcome — an uncompilable rule, a failed finding
// write, an unreachable webhook — is counted, logged and swallowed, because a
// writer whose batch is refused because somebody shipped a bad bundle has had
// its telemetry silently dropped by a detection control.
func (s *Sink) IngestObservation(ctx context.Context, obs *model.Observation) error {
	if obs == nil {
		return nil
	}

	// Store first.
	if err := s.inner.IngestObservation(ctx, obs); err != nil {
		return err
	}
	// Decide second.
	s.Evaluate(ctx, obs)
	return nil
}

// Evaluate runs stage 1 and stage 2 over an observation that has ALREADY been
// stored, writing findings and decisions but not the observation itself.
//
// It exists so the HTTP ingest path can keep its batch semantics. That handler
// validates a whole batch and then calls Store.Append once, atomically; routing
// it through IngestObservation per observation would turn a batch that is
// accepted or rejected as a unit into one that can half-land. So the store
// wrapper appends the batch exactly as before and then calls Evaluate per row —
// the same deciding code the collector path runs, reached by a second door
// rather than copied.
//
// It returns nothing by design: there is no policy outcome a caller should act
// on. Every fault is counted and logged.
func (s *Sink) Evaluate(ctx context.Context, obs *model.Observation) {
	if obs == nil {
		return
	}
	// Never over our own output.
	if obs.Source == obscel.SourceFinding || obs.Source == obscel.SourceDecision {
		return
	}
	if s.eval == nil || s.bundles == nil {
		return
	}

	tenant := obs.Labels[TenantLabel]
	bundles := s.bundles(tenant)
	if len(bundles) == 0 {
		return
	}

	// A pseudonymisation fault is NOT evaluated around. Carrying on with an
	// empty or cleartext actor is exactly the defect this path was fixed for:
	// every shipped rule's allowlist is a NEGATIVE test on the actor, so a wrong
	// actor does not under-detect, it fires against the identities an operator
	// deliberately exempted. Counting it as an evaluator fault and declining to
	// evaluate is the fail-closed direction, and it is visible in the metric and
	// the log rather than in a finding that names the wrong person.
	projected, err := toObscel(obs, s.pseudo)
	if err != nil {
		s.metrics.observeEvaluatorError()
		s.log.Error("policy could not resolve the actor identity; the observation was NOT evaluated",
			"observation", obs.ID, "tenant", tenant, "error", err)
		return
	}
	for _, b := range bundles {
		findings, err := s.eval.EvaluateObservation(projected, b)
		if err != nil {
			// Partial success is the evaluator's contract: `findings` holds the
			// rules that ran cleanly and `err` names the ones that faulted, so
			// both are handled rather than one discarding the other.
			s.metrics.observeEvaluatorError()
			s.log.Warn("observation policy evaluator fault; detection is degraded for this bundle",
				"bundle", b.ID, "bundle_version", b.Version, "tenant", tenant, "error", err)
		}
		for _, f := range findings {
			s.emitFinding(ctx, f, obs, b)
		}
	}
}

// emitFinding writes one finding and offers it to stage 2.
func (s *Sink) emitFinding(ctx context.Context, f obscel.Finding, src *model.Observation, b *obscel.Bundle) {
	s.metrics.observeFinding(f.Severity)
	if s.observer != nil {
		s.observer.OnFinding(f)
	}

	fo := findingObservation(f, src, b.Mode, s.windows.KeyedLabelKeys(f.RuleID, b))
	if err := s.derived.IngestObservation(ctx, &fo); err != nil {
		s.metrics.observeFindingWriteError()
		s.log.Error("policy finding could not be stored; the detection happened and was not recorded",
			"finding", f.ID, "rule", f.RuleID, "error", err)
		// Deliberately continue into stage 2: the counter is in memory and is
		// still correct. Dropping the count as well would turn one lost row
		// into a missed burst.
	}

	if s.windows == nil {
		return
	}
	for _, d := range s.windows.Offer(f, b) {
		s.emitDecision(ctx, d, src)
	}
}

// emitDecision writes one decision and alerts according to the bundle mode.
//
// The three modes differ ONLY in alerting (D5, §3):
//
//	shadow  — stored with mode=shadow, no alert.
//	warn    — stored, alerted.
//	enforce — stored, alerted, and nothing in the customer account is touched.
//
// enforce is therefore not a no-op relative to warn in the record (the stored
// mode label differs, which is what a promotion audit reads) but it is a no-op
// in the customer account by construction: there is no write path in this
// package or anything it calls.
func (s *Sink) emitDecision(ctx context.Context, d obscel.Decision, trigger *model.Observation) {
	s.metrics.observeDecision(string(d.Mode))
	if s.observer != nil {
		s.observer.OnDecision(d)
	}

	do := decisionObservation(d, trigger)
	if err := s.derived.IngestObservation(ctx, &do); err != nil {
		s.metrics.observeDecisionWriteError()
		s.log.Error("policy decision could not be stored",
			"decision", d.ID, "window", d.WindowID, "error", err)
	}

	// Route the decision to containment BEFORE the mode gate: a stun on a
	// verified Landlock denial must fire even while the bundle is in shadow
	// (detection→stun is the whole point). The dispatcher gates and dedups.
	if s.decisionDispatcher != nil && trigger != nil {
		s.decisionDispatcher.Dispatch(ctx, d, *trigger)
	}

	if d.Mode == obscel.ModeShadow {
		return
	}
	if s.alerter == nil {
		return
	}
	if err := s.alerter.Alert(ctx, d); err != nil {
		s.metrics.observeAlertFailure()
		s.log.Error("policy decision alert failed",
			"decision", d.ID, "window", d.WindowID, "mode", string(d.Mode), "error", err)
	}
}

// StaticBundles returns a BundleResolver over a fixed, boot-loaded bundle set,
// indexed by tenant. Order within a tenant is the loader's order, which
// LoadBundleDir has already made deterministic.
func StaticBundles(bundles []*obscel.Bundle) BundleResolver {
	byTenant := make(map[string][]*obscel.Bundle, len(bundles))
	for _, b := range bundles {
		byTenant[b.TenantID] = append(byTenant[b.TenantID], b)
	}
	return func(tenant string) []*obscel.Bundle { return byTenant[tenant] }
}

// sortedCopy returns a sorted copy, never mutating the input. Used wherever a
// derived identifier or a label hashes a set of IDs: sorting in place would
// reorder the caller's slice and make a second canonicalisation of the same
// value disagree with the first.
func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
