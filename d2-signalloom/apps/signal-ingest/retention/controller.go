// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

var (
	// ErrControllerMisconfigured is returned when the controller cannot be safely constructed.
	ErrControllerMisconfigured = errors.New("retention: controller is misconfigured")

	// ErrSweepIncomplete is returned when a sweep did not reach a complete disposition for every copy.
	//
	// It is returned as an ERROR rather than reported as a field, because a caller that only checks
	// err == nil must not read "one sink was unreachable" as a clean sweep. That is the exact failure
	// mode the receipt ledger exists to expose, and it would be absurd for the controller's own
	// signature to reintroduce it.
	ErrSweepIncomplete = errors.New("retention: sweep did not complete for every copy")
)

// Evaluator is the slice of privacy.Retention the controller depends on.
//
// Declared as an interface so the fail-closed paths (hold-source error, no jurisdiction) are testable
// without standing up a quarantine engine, and so that the precedence rule keeps living in
// privacy.Retention rather than being reimplemented here.
type Evaluator interface {
	Evaluate(ctx context.Context, tenantID, subjectID string, retentionEndsAt time.Time) (privacy.RetentionDecision, error)
}

// Controller is the retention state machine.
//
// One Sweep walks every configured sink and drives each copy through:
//
//	pending -> due? -> held? -> dispatched -> {purged | already_absent | retained_token} = complete
//	                         \-> held      -> outstanding -> overdue past deadline
//	                         \-> unreachable -> outstanding -> overdue past deadline
//
// The terminal states are receipts, not memory: the controller holds no progress state between
// sweeps. Resumption works because the operation ID is a deterministic function of
// (tenant, sink, boundary), so a re-run recomputes the same identity, the ledger upsert collapses it,
// and a copy is neither double-counted nor skipped.
type Controller struct {
	clock     Clock
	ledger    Ledger
	evaluator Evaluator
	audit     audit.AuditWriter
	metrics   *Metrics
	policies  PolicySet
	sinks     []Sink
	log       *slog.Logger

	// enforcing refuses an unverified clock. A non-enforcing controller is for fixtures and dry runs
	// and is opted into explicitly, so the safe configuration is the default one.
	enforcing bool

	mu sync.Mutex
}

// Config configures a Controller.
type Config struct {
	Clock     Clock
	Ledger    Ledger
	Evaluator Evaluator
	Audit     audit.AuditWriter
	Metrics   *Metrics
	Policies  PolicySet
	Sinks     []Sink
	Logger    *slog.Logger

	// NonEnforcing permits a local_unverified clock. Named for what it gives up.
	NonEnforcing bool
}

// NewController constructs a Controller, refusing every configuration that could fail open.
func NewController(cfg Config) (*Controller, error) {
	if cfg.Ledger == nil {
		return nil, fmt.Errorf("%w: ledger is required; a controller with no ledger deletes without proof", ErrControllerMisconfigured)
	}
	if cfg.Clock == nil {
		return nil, fmt.Errorf("%w: clock is required; a controller with no clock would fall back to local time", ErrControllerMisconfigured)
	}
	if cfg.Evaluator == nil {
		return nil, fmt.Errorf("%w: evaluator is required; a controller that cannot see legal holds deletes through them", ErrControllerMisconfigured)
	}
	if cfg.Audit == nil {
		return nil, fmt.Errorf("%w: audit writer is required; an unaudited deletion is unprovable", ErrControllerMisconfigured)
	}
	if len(cfg.Sinks) == 0 {
		return nil, fmt.Errorf("%w: sink set is empty; an empty sweep passes every acceptance criterion vacuously", ErrControllerMisconfigured)
	}
	if !cfg.NonEnforcing && cfg.Clock.Source() == ClockSourceLocalUnverified {
		return nil, fmt.Errorf("%w: clock source %q is not trusted; retention boundaries computed from an unattested clock expire data early or late with no signal",
			ErrControllerMisconfigured, cfg.Clock.Source())
	}

	ids := make([]string, 0, len(cfg.Sinks))
	seen := make(map[string]struct{}, len(cfg.Sinks))
	for _, s := range cfg.Sinks {
		if s == nil {
			return nil, fmt.Errorf("%w: sink set contains a nil sink", ErrControllerMisconfigured)
		}
		if _, dup := seen[s.SinkID()]; dup {
			return nil, fmt.Errorf("%w: duplicate sink %q", ErrControllerMisconfigured, s.SinkID())
		}
		seen[s.SinkID()] = struct{}{}
		ids = append(ids, s.SinkID())
	}
	if err := cfg.Policies.Validate(ids); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrControllerMisconfigured, err)
	}

	metrics := cfg.Metrics
	if metrics == nil {
		metrics = NewMetrics()
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Controller{
		clock:     cfg.Clock,
		ledger:    cfg.Ledger,
		evaluator: cfg.Evaluator,
		audit:     cfg.Audit,
		metrics:   metrics,
		policies:  cfg.Policies,
		sinks:     cfg.Sinks,
		log:       logger,
		enforcing: !cfg.NonEnforcing,
	}, nil
}

// Metrics returns the controller's metric registry.
func (c *Controller) Metrics() *Metrics { return c.metrics }

// SweepResult is the outcome of one sweep.
type SweepResult struct {
	TenantID    string
	EvaluatedAt time.Time
	ClockSource string

	// Dispositions counts receipts by disposition.
	Dispositions map[Disposition]int

	// Receipts are the operation IDs written this sweep, sorted.
	Receipts []string

	// Failures are per-sink errors. A non-empty Failures is why OK() is false.
	Failures map[string]string

	// Outstanding is every copy without a complete receipt at EvaluatedAt.
	Outstanding []Outstanding

	// OverdueCount is how many of those are past their deadline.
	OverdueCount int

	// RecordsRemoved is the total removed BY THIS SWEEP. It deliberately excludes copies already
	// discharged by an earlier sweep: counting a prior receipt's removals again is the double-counting
	// a resumed sweep is specifically warned against, and it read as a 67% overstatement in the test
	// that caught it.
	RecordsRemoved int64

	// AlreadyDischarged counts copies skipped because a complete receipt already existed. Reported
	// separately so "we removed nothing because there was nothing left" is distinguishable from
	// "we removed nothing because we did not look".
	AlreadyDischarged int

	// Aborted reports that the sweep stopped before touching any sink — currently only on an untrusted
	// clock. It exists because OK() must be false in that case: without it, an aborted sweep has no
	// failures, no unreachable sinks and no overdue copies yet, so OK() would read TRUE for a sweep
	// that did nothing at all. A caller inspecting only OK() would see a clean bill of health.
	Aborted bool
}

// OK reports whether the sweep discharged every copy's retention obligation.
//
// False when the sweep aborted, anything was unreachable, anything failed, or anything is overdue. A
// sweep is not OK because it ran; it is OK because no expired copy is still alive past its deadline.
//
// Note what OK() deliberately tolerates: a copy under an active legal hold, inside its propagation
// window. That is the normal state of a lawful hold, and failing every sweep that encounters one would
// make the signal permanently red and therefore ignored. Such a copy is still reported in Outstanding,
// still rendered by the outstanding gauge, and DOES turn OK() false once its deadline passes — which is
// what stops a permanent hold from becoming invisible indefinite retention.
func (r SweepResult) OK() bool {
	return !r.Aborted &&
		len(r.Failures) == 0 &&
		r.Dispositions[DispositionUnreachable] == 0 &&
		r.OverdueCount == 0
}

// Sweep runs one retention pass over every configured sink for one tenant.
func (c *Controller) Sweep(ctx context.Context, tenantID string) (SweepResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	result := SweepResult{
		TenantID:     tenantID,
		ClockSource:  c.clock.Source(),
		Dispositions: make(map[Disposition]int),
		Failures:     make(map[string]string),
	}

	now, err := c.clock.Now()
	if err != nil {
		// Fail closed, loudly, and WITHOUT touching a sink. Note what this deliberately does not do:
		// it does not substitute time.Now(), and it does not record a clean sweep. Outstanding copies
		// stay outstanding, so the overdue gauge keeps counting them and the failure surfaces as
		// expired data rather than as silence.
		result.Aborted = true
		c.metrics.ObserveClockUntrusted()
		c.log.Error("retention sweep aborted: clock is untrusted",
			"tenant", tenantID, "clock_source", c.clock.Source(), "error", err,
			"consequence", "no copy was purged; outstanding copies remain outstanding and will go overdue")
		return result, fmt.Errorf("retention sweep aborted before touching any sink: %w", err)
	}
	result.EvaluatedAt = now
	c.metrics.ObserveSweep()

	for _, sink := range c.sinks {
		receipt, fresh, sweepErr := c.evaluateSink(ctx, tenantID, sink, now)
		if sweepErr != nil {
			result.Failures[sink.SinkID()] = sweepErr.Error()
			c.metrics.ObserveSinkFailure(sink.SinkID())
			// A failure that produced no receipt still leaves the copy outstanding, which is the
			// correct state: nothing was demonstrated.
			if receipt.OperationID == "" {
				continue
			}
		} else {
			c.metrics.ResetSinkFailures(sink.SinkID())
		}

		if !fresh {
			// Either the copy is not due (no receipt at all), or a complete receipt already exists.
			// Neither is re-recorded and neither is counted: re-recording would rewrite a sealed row
			// and re-counting would add the prior receipt's RecordsRemoved to this sweep's total,
			// which is precisely the double-count a resumed sweep must not produce.
			if receipt.OperationID != "" {
				result.AlreadyDischarged++
			}
			continue
		}

		if err := c.ledger.Record(ctx, receipt); err != nil {
			// The purge may have happened and we cannot prove it. That is worse than a failed purge,
			// so it is reported rather than swallowed, and the copy stays outstanding.
			result.Failures[sink.SinkID()] = fmt.Errorf("%w: %v", ErrLedgerUnavailable, err).Error()
			c.log.Error("retention receipt could not be recorded",
				"tenant", tenantID, "sink", sink.SinkID(), "operation_id", receipt.OperationID, "error", err,
				"consequence", "deletion may have occurred and cannot be proven; copy remains outstanding")
			continue
		}

		if err := c.writeAudit(ctx, receipt); err != nil {
			// audit.AuditWriter fails closed by contract (NopWriter returns ErrAuditDisabled unless
			// explicitly opted out), so an error here is surfaced rather than logged and forgotten.
			result.Failures[sink.SinkID()] = fmt.Errorf("audit write failed for sink %q: %w", sink.SinkID(), err).Error()
			c.log.Error("retention audit event could not be written",
				"tenant", tenantID, "sink", sink.SinkID(), "receipt_digest", receipt.ReceiptDigest, "error", err)
		}

		result.Dispositions[receipt.Disposition]++
		result.Receipts = append(result.Receipts, receipt.OperationID)
		result.RecordsRemoved += receipt.RecordsRemoved
		c.metrics.ObserveReceipt(receipt)
	}
	sort.Strings(result.Receipts)

	outstanding, err := c.ledger.Outstanding(ctx, tenantID, c.specs(), now)
	if err != nil {
		return result, fmt.Errorf("retention sweep cannot report outstanding copies: %w", err)
	}
	result.Outstanding = outstanding
	overdue := Overdue(outstanding, now)
	result.OverdueCount = len(overdue)

	c.metrics.SetOutstanding(tenantID, outstanding, now)
	c.metrics.ObserveSuccessfulSweep(now)

	for _, o := range overdue {
		c.log.Warn("retention deadline breached",
			"tenant", o.TenantID, "sink", o.SinkID, "sink_class", o.SinkClass,
			"disposition", string(o.Disposition), "deadline", o.Deadline.Format(time.RFC3339),
			"overdue_age", o.OverdueAge(now).String(), "hold_ids", o.HoldIDs)
	}

	if !result.OK() {
		return result, fmt.Errorf("%w: %d overdue, %d unreachable, %d failed",
			ErrSweepIncomplete, result.OverdueCount, result.Dispositions[DispositionUnreachable], len(result.Failures))
	}
	return result, nil
}

// specs returns the SinkSpec for each configured sink, so Outstanding is computed over exactly the
// set the controller actually sweeps rather than over the global inventory.
func (c *Controller) specs() []SinkSpec {
	out := make([]SinkSpec, 0, len(c.sinks))
	for _, s := range c.sinks {
		if spec, ok := SpecByID(s.SinkID()); ok {
			out = append(out, spec)
			continue
		}
		out = append(out, SinkSpec{ID: s.SinkID(), Class: s.Class(), Reach: s.Reach()})
	}
	return out
}

// evaluateSink drives one copy through the state machine and returns its receipt.
//
// It returns a receipt in EVERY path that reached a decision — including held, unreachable and
// already-absent — because a ledger that only records successes cannot distinguish a working sweep
// from one pointed at the wrong store.
//
// The second return value is FRESH: true when this call produced a new decision that must be recorded
// and counted, false when the copy was not due, or when a complete receipt already existed and is
// being returned unchanged. The caller must not accumulate a non-fresh receipt's RecordsRemoved into
// the sweep total; doing so double-counts every already-discharged copy on every subsequent sweep.
func (c *Controller) evaluateSink(ctx context.Context, tenantID string, sink Sink, now time.Time) (DeletionReceipt, bool, error) {
	policy, ok := c.policies.For(sink.SinkID())
	if !ok {
		return DeletionReceipt{}, false, fmt.Errorf("%w: no policy covers sink %q", ErrPolicySetIncomplete, sink.SinkID())
	}
	boundary := policy.Boundary(now)

	nonce, err := NewReceiptNonce()
	if err != nil {
		return DeletionReceipt{}, false, err
	}

	spec, _ := SpecByID(sink.SinkID())

	// The deadline is ANCHORED, not recomputed.
	//
	// boundary is now-minus-period, so it advances on every sweep and a naively-derived deadline advances
	// with it. That was a live defect in this file: a copy blocked by a permanent legal hold got a fresh
	// always-future deadline on every sweep, so it could never go overdue, the gauge read zero forever,
	// and legal hold became unlimited retention that no test using a single sweep could detect. Inheriting
	// the earliest still-open deadline for this sink makes the clock start once and keep running.
	deadline := boundary.Add(policy.Period).Add(MaxPropagationDelay).UTC().Truncate(time.Microsecond)
	if anchored, found, err := c.ledger.EarliestOpenDeadline(ctx, tenantID, sink.SinkID()); err == nil && found && anchored.Before(deadline) {
		deadline = anchored
	}

	receipt := DeletionReceipt{
		Schema:              ReceiptSchema,
		OperationID:         NewOperationID(tenantID, sink.SinkID(), boundary),
		TenantID:            tenantID,
		SinkID:              sink.SinkID(),
		SinkClass:           string(sink.Class()),
		DroppedBefore:       boundary,
		PropagationDeadline: deadline,
		EvaluatedAt:         now,
		ClockSource:         c.clock.Source(),
		ReceiptNonce:        nonce,
	}

	// Idempotence. A completed receipt for this exact operation means the copy is already discharged;
	// re-purging would double-count RecordsRemoved and re-purging an already-purged store is how a
	// resumed sweep corrupts its own figures. Returning the stored receipt rather than a fresh one
	// also keeps the digest stable, which is what makes "one operation, one receipt" assertable.
	if prior, found, err := c.ledger.Get(ctx, tenantID, receipt.OperationID); err == nil && found && prior.Disposition.Complete() {
		return prior, false, nil
	}

	// Precedence. Delegated to privacy.Retention, which is the single implementation of "a legal hold
	// beats retention expiry" and which fails closed on an undetermined or unauthorised hold lookup.
	// The subject scope for a sink-wide sweep is the sink itself: a hold on any subject within it
	// blocks the sweep for that sink, which is the conservative reading and the only one that cannot
	// delete through a hold it failed to enumerate.
	decision, err := c.evaluator.Evaluate(ctx, tenantID, sink.SinkID(), boundary.Add(policy.Period))
	if err != nil {
		receipt.Disposition = DispositionUnreachable
		receipt.ResidualState = ResidualNotDemonstrated
		receipt.ComplianceNote = ComplianceNoteUnreachable
		sealed, sealErr := receipt.Seal()
		if sealErr != nil {
			return DeletionReceipt{}, false, sealErr
		}
		return sealed, true, fmt.Errorf("hold evaluation failed for sink %q, refusing to purge: %w", sink.SinkID(), err)
	}
	if !decision.Deletable {
		if len(decision.HoldIDs) > 0 {
			receipt.Disposition = DispositionHeld
			receipt.HoldIDs = decision.HoldIDs
			receipt.ResidualState = ResidualNotDemonstrated
			receipt.ComplianceNote = ComplianceNoteHeld
			sealed, sealErr := receipt.Seal()
			if sealErr != nil {
				return DeletionReceipt{}, false, sealErr
			}
			return sealed, true, nil
		}
		// Not due. Not a receipt: nothing was in scope, so recording one would put a row in the
		// ledger asserting an evaluation of data that had not expired. The copy is simply not
		// outstanding yet, and its deadline has not been set.
		return DeletionReceipt{}, false, nil
	}

	outcome, purgeErr := sink.Purge(ctx, PurgeRequest{TenantID: tenantID, Before: boundary})
	switch {
	case errors.Is(purgeErr, ErrSinkUnreachable):
		receipt.Disposition = DispositionUnreachable
		receipt.ResidualState = ResidualNotDemonstrated
		receipt.ComplianceNote = ComplianceNoteUnreachable
		sealed, sealErr := receipt.Seal()
		if sealErr != nil {
			return DeletionReceipt{}, false, sealErr
		}
		return sealed, true, purgeErr

	case purgeErr != nil:
		receipt.Disposition = DispositionUnreachable
		receipt.ResidualState = ResidualNotDemonstrated
		receipt.ComplianceNote = ComplianceNoteUnreachable
		sealed, sealErr := receipt.Seal()
		if sealErr != nil {
			return DeletionReceipt{}, false, sealErr
		}
		return sealed, true, purgeErr

	case sink.Reach() == ReachContinuityBearing:
		receipt.Disposition = DispositionRetainedUnresolvableToken
		receipt.LinkageReceipts = outcome.LinkageReceipts
		receipt.ResidualState = outcome.ResidualState
		receipt.ComplianceNote = ComplianceNoteRetainedToken
		receipt.CompletedAt = now

	case outcome.AlreadyAbsent:
		receipt.Disposition = DispositionAlreadyAbsent
		receipt.ResidualState = outcome.ResidualState
		receipt.ComplianceNote = ComplianceNoteAlreadyAbsent
		receipt.CompletedAt = now

	default:
		receipt.Disposition = DispositionPurged
		receipt.RecordsRemoved = outcome.RecordsRemoved
		receipt.PartitionsDropped = outcome.PartitionsDropped
		receipt.ResidualState = outcome.ResidualState
		receipt.ComplianceNote = ComplianceNotePurged
		receipt.CompletedAt = now
	}

	if receipt.ResidualState == "" {
		// A sink that says nothing about residue is refused rather than defaulted. Silence about
		// residue reads as "nothing survives", which is false for any PostgreSQL row and any
		// unlinked file, and the receipt is what a regulator reads.
		return DeletionReceipt{}, false, fmt.Errorf("%w: sink %q returned no residual_state", ErrSinkMisconfigured, sink.SinkID())
	}
	_ = spec
	sealed, err := receipt.Seal()
	if err != nil {
		return DeletionReceipt{}, false, err
	}
	return sealed, true, nil
}

// writeAudit emits the partition-dropped audit event for one receipt.
//
// NOTE, and this is a cross-card finding rather than a defect here: audit.EventPartitionDropped
// already has one call site, privacy/erasure.go:495, where it means "an Article 17 erasure decision
// was permitted". Emitting the same event type for a retention sweep makes the two indistinguishable
// in the signal_audit_trail.event_type column. The detail payload below carries "cause":"retention"
// precisely so they can still be told apart by a reader, but the durable fix is a distinct event type
// with a widened CHECK constraint, which lives outside this card's boundary. Recorded in errata for
// P6-GOV.
func (c *Controller) writeAudit(ctx context.Context, receipt DeletionReceipt) error {
	detail, err := json.Marshal(map[string]any{
		"cause":                "retention",
		"schema":               receipt.Schema,
		"operation_id":         receipt.OperationID,
		"sink_id":              receipt.SinkID,
		"sink_class":           receipt.SinkClass,
		"disposition":          string(receipt.Disposition),
		"dropped_before":       receipt.DroppedBefore.UTC().Format(time.RFC3339Nano),
		"propagation_deadline": receipt.PropagationDeadline.UTC().Format(time.RFC3339Nano),
		"records_removed":      receipt.RecordsRemoved,
		"partitions_dropped":   receipt.PartitionsDropped,
		"receipt_digest":       receipt.ReceiptDigest,
		"residual_state":       receipt.ResidualState,
		"compliance_note":      receipt.ComplianceNote,
		"clock_source":         receipt.ClockSource,
		"hold_ids":             receipt.HoldIDs,
	})
	if err != nil {
		return fmt.Errorf("encode retention audit detail: %w", err)
	}
	return c.audit.WriteAuditEvent(ctx, audit.Event{
		TenantID:  receipt.TenantID,
		EventType: audit.EventPartitionDropped,
		Detail:    detail,
		CreatedAt: receipt.EvaluatedAt,
	})
}

// ExternalAttestation is an operator's assertion that a copy this process cannot reach was deleted —
// or that no such copy exists.
//
// It is how a ReachExternalAttestation sink ever reaches a complete disposition. Deliberately
// explicit: there is no configuration that makes an unreachable sink discharge itself, because a
// control that can mark its own unreachable copies done is a control with an off switch.
type ExternalAttestation struct {
	TenantID  string
	SinkID    string
	Attestor  string
	Absent    bool // true when the honest answer is that no copy exists
	Records   int64
	Residual  string
	Completed time.Time
}

// SubmitExternalReceipt records an external deletion attestation as a receipt.
func (c *Controller) SubmitExternalReceipt(ctx context.Context, att ExternalAttestation) (DeletionReceipt, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if att.Attestor == "" {
		return DeletionReceipt{}, fmt.Errorf("%w: external attestation names no attestor", ErrReceiptIncomplete)
	}
	spec, ok := SpecByID(att.SinkID)
	if !ok {
		return DeletionReceipt{}, fmt.Errorf("%w: sink %q is not in the inventory", ErrControllerMisconfigured, att.SinkID)
	}
	if spec.Reach != ReachExternalAttestation {
		return DeletionReceipt{}, fmt.Errorf("%w: sink %q has reach %q and must be purged in-process, not attested",
			ErrControllerMisconfigured, att.SinkID, spec.Reach)
	}
	policy, ok := c.policies.For(att.SinkID)
	if !ok {
		return DeletionReceipt{}, fmt.Errorf("%w: no policy covers sink %q", ErrPolicySetIncomplete, att.SinkID)
	}
	now, err := c.clock.Now()
	if err != nil {
		return DeletionReceipt{}, fmt.Errorf("cannot record an external attestation on an untrusted clock: %w", err)
	}
	boundary := policy.Boundary(now)
	nonce, err := NewReceiptNonce()
	if err != nil {
		return DeletionReceipt{}, err
	}
	completed := att.Completed
	if completed.IsZero() {
		completed = now
	}
	residual := att.Residual
	if residual == "" {
		residual = spec.Residual
	}

	receipt := DeletionReceipt{
		Schema:              ReceiptSchema,
		OperationID:         NewOperationID(att.TenantID, att.SinkID, boundary),
		TenantID:            att.TenantID,
		SinkID:              att.SinkID,
		SinkClass:           string(spec.Class),
		DroppedBefore:       boundary,
		PropagationDeadline: boundary.Add(policy.Period).Add(MaxPropagationDelay).UTC().Truncate(time.Microsecond),
		EvaluatedAt:         now,
		CompletedAt:         completed.UTC().Truncate(time.Microsecond),
		ClockSource:         c.clock.Source(),
		ReceiptNonce:        nonce,
		ResidualState:       residual,
	}
	if att.Absent {
		receipt.Disposition = DispositionAlreadyAbsent
		receipt.ComplianceNote = ComplianceNoteAlreadyAbsent
	} else {
		receipt.Disposition = DispositionPurged
		receipt.RecordsRemoved = att.Records
		receipt.ComplianceNote = ComplianceNotePurged
	}

	sealed, err := receipt.Seal()
	if err != nil {
		return DeletionReceipt{}, err
	}
	if err := c.ledger.Record(ctx, sealed); err != nil {
		return DeletionReceipt{}, fmt.Errorf("%w: %v", ErrLedgerUnavailable, err)
	}
	if err := c.writeAudit(ctx, sealed); err != nil {
		return sealed, fmt.Errorf("external attestation recorded but audit write failed: %w", err)
	}
	c.metrics.ObserveReceipt(sealed)
	c.log.Info("external deletion attestation recorded",
		"tenant", att.TenantID, "sink", att.SinkID, "attestor", att.Attestor,
		"disposition", string(sealed.Disposition), "receipt_digest", sealed.ReceiptDigest)
	return sealed, nil
}

// Reconcile refreshes the outstanding set and the overdue gauge WITHOUT sweeping.
//
// It exists so the gauge is a function of the ledger rather than of the last sweep's memory. A gauge
// derived from the sweep that just cleared it is structurally incapable of reporting non-zero, which
// is the most plausible way this whole control could ship green and useless.
func (c *Controller) Reconcile(ctx context.Context, tenantID string) ([]Outstanding, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now, err := c.clock.Now()
	if err != nil {
		c.metrics.ObserveClockUntrusted()
		return nil, fmt.Errorf("cannot reconcile retention state on an untrusted clock: %w", err)
	}
	outstanding, err := c.ledger.Outstanding(ctx, tenantID, c.specs(), now)
	if err != nil {
		return nil, err
	}
	c.metrics.SetOutstanding(tenantID, outstanding, now)
	return outstanding, nil
}

// LinkageLookup returns a function suitable for NewContinuitySink, bound to this controller's ledger.
func LinkageLookup(ledger Ledger) func(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error) {
	return func(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error) {
		return ledger.CompletedDigests(ctx, tenantID, sinkIDs)
	}
}

// LinkageSinksFor returns the linkage copies whose purge makes a continuity-bearing sink's retained
// tokens unresolvable.
//
// Both, not either. A pseudonym stays resolvable while EITHER the re-identification map or the
// subject key survives, so requiring both is the only reading under which the retained token is
// genuinely unresolvable.
func LinkageSinksFor(_ string) []string {
	return []string{"postgres_segment_reidentification_map", "postgres_subject_keys"}
}

// DefaultSweepInterval is how often the reaper sweeps.
const DefaultSweepInterval = 6 * time.Hour

// Reaper runs Sweep on an interval.
//
// Shaped after identity.DelegationReaper so the process has one background-worker idiom rather than
// two: Start is idempotent via an atomic swap, Stop closes a channel, and the loop survives a panic.
type Reaper struct {
	controller *Controller
	tenants    func() []string
	interval   time.Duration
	log        *slog.Logger

	stopCh  chan struct{}
	running bool
	mu      sync.Mutex
}

// NewReaper constructs a retention reaper.
func NewReaper(controller *Controller, tenants func() []string, interval time.Duration, logger *slog.Logger) (*Reaper, error) {
	if controller == nil {
		return nil, fmt.Errorf("%w: reaper requires a controller", ErrControllerMisconfigured)
	}
	if tenants == nil {
		return nil, fmt.Errorf("%w: reaper requires a tenant source; a reaper with no tenants sweeps nothing and reports no error", ErrControllerMisconfigured)
	}
	if interval <= 0 {
		interval = DefaultSweepInterval
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Reaper{controller: controller, tenants: tenants, interval: interval, log: logger, stopCh: make(chan struct{})}, nil
}

// Start spawns the background sweep loop.
func (r *Reaper) Start(ctx context.Context) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.running {
		return
	}
	r.running = true
	go r.runLoop(ctx)
}

// Stop terminates the background sweep loop.
func (r *Reaper) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.running {
		return
	}
	r.running = false
	close(r.stopCh)
}

func (r *Reaper) runLoop(ctx context.Context) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.stopCh:
			return
		case <-ticker.C:
			r.sweepOnce(ctx)
		}
	}
}

// sweepOnce sweeps every tenant, isolating panics so one tenant cannot stop the loop.
func (r *Reaper) sweepOnce(ctx context.Context) {
	defer func() {
		if rec := recover(); rec != nil {
			r.log.Error("retention sweep panicked", "panic", rec)
		}
	}()
	for _, tenant := range r.tenants() {
		res, err := r.controller.Sweep(ctx, tenant)
		if err != nil {
			r.log.Warn("retention sweep incomplete",
				"tenant", tenant, "overdue", res.OverdueCount,
				"unreachable", res.Dispositions[DispositionUnreachable],
				"failures", len(res.Failures), "error", err)
			continue
		}
		r.log.Info("retention sweep complete",
			"tenant", tenant, "purged", res.Dispositions[DispositionPurged],
			"already_absent", res.Dispositions[DispositionAlreadyAbsent],
			"retained_token", res.Dispositions[DispositionRetainedUnresolvableToken],
			"records_removed", res.RecordsRemoved)
	}
}
