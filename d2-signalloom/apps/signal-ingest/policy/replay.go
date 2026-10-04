// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sort"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// ReplayOptions configures one regression replay (ISC-55).
type ReplayOptions struct {
	// BundlesDir is the bundle tree to replay WITH. It is an explicit argument
	// rather than the boot value, because the point of a replay is often to ask
	// what a candidate bundle would have found in the backlog.
	BundlesDir string
	// From and To bound the observation range, inclusive of From.
	From, To time.Time
	// Tenant, when non-empty, restricts the replay to one tenant.
	Tenant string
	// Out receives the canonical lines.
	Out io.Writer
	// Log is optional.
	Log *slog.Logger
}

// Replay re-evaluates stored observations through the SAME stage 1 and stage 2
// code the live sink runs, with the clock replaced by observation timestamps,
// and writes the canonical projection.
//
// # Why this is the regression oracle
//
// Nothing here is a second implementation. Replay builds a policy.Sink over a
// discarding inner sink and a fresh Windows, and feeds it observations read from
// the store in sorted order. If the output differs from live, the difference is
// in the data or in the bundle, never in two copies of the rules that drifted.
//
// # Determinism
//
// The clock is never read. Observations are fed in (timestamp, ID) order, so the
// sliding window sees the same arrivals a live stream saw; findings carry
// observation timestamps by construction; the output is sorted, so a difference
// in read order cannot show up as a difference in output. Findings and
// decisions already in the store are SKIPPED as input — replaying stage-1 output
// back through stage 1 would compare a run against a run plus its own echo.
func Replay(ctx context.Context, st store.SignalStore, opts ReplayOptions) (findings, decisions int, err error) {
	log := opts.Log
	if log == nil {
		log = slog.Default()
	}
	if st == nil {
		return 0, 0, errors.New("policy: replay needs a store")
	}
	if opts.Out == nil {
		return 0, 0, errors.New("policy: replay needs an output writer")
	}

	bundles, err := LoadBundles(opts.BundlesDir, log)
	if err != nil {
		return 0, 0, err
	}
	if len(bundles) == 0 {
		// Not an error: an operator asking "what would no policy have found" gets
		// an empty answer rather than a failure. The e2e mutation gate relies on
		// the EMPTY RESULT being visible rather than on an error being raised.
		log.Warn("replay loaded zero bundles; the output will be empty", "dir", opts.BundlesDir)
	}

	eval, err := obscel.NewEvaluator()
	if err != nil {
		return 0, 0, fmt.Errorf("policy: replay evaluator: %w", err)
	}

	rows, err := st.QueryRange(ctx, store.Query{After: opts.From, Before: opts.To})
	if err != nil {
		return 0, 0, fmt.Errorf("policy: replay QueryRange: %w", err)
	}

	input := make([]model.Observation, 0, len(rows))
	for _, row := range rows {
		if row.Source == obscel.SourceFinding || row.Source == obscel.SourceDecision {
			continue
		}
		if opts.Tenant != "" && row.Labels[TenantLabel] != opts.Tenant {
			continue
		}
		input = append(input, row)
	}
	SortObservations(input)

	rec := &canonicalRecorder{}
	sink := NewSink(discardSink{}, st, eval, StaticBundles(bundles), Options{
		Windows:  NewWindowsWithLogger(bundles, log),
		Observer: rec,
		Logger:   log,
	})

	for i := range input {
		if err := sink.IngestObservation(ctx, &input[i]); err != nil {
			return 0, 0, fmt.Errorf("policy: replaying observation %s: %w", input[i].ID, err)
		}
	}

	lines := rec.Lines()
	for _, line := range lines {
		if _, err := io.WriteString(opts.Out, line+"\n"); err != nil {
			return 0, 0, fmt.Errorf("policy: writing replay output: %w", err)
		}
	}

	log.Info("replay complete",
		"observations", len(input), "findings", len(rec.findings), "decisions", len(rec.decisions),
		"bundles", len(bundles), "dir", opts.BundlesDir)
	return len(rec.findings), len(rec.decisions), nil
}

// SortObservations orders observations by (timestamp, ID), the canonical arrival
// order. Exported so the e2e harness feeds live ingest in the same order replay
// will, which is what makes the byte-equality claim about the PIPELINE rather
// than about the store's read order.
func SortObservations(obs []model.Observation) {
	sort.Slice(obs, func(i, j int) bool {
		if !obs[i].Timestamp.Equal(obs[j].Timestamp) {
			return obs[i].Timestamp.Before(obs[j].Timestamp)
		}
		return obs[i].ID < obs[j].ID
	})
}

// canonicalRecorder is the Observer that both live capture and replay use, so
// the two sides of the comparison are the same projection of the same type.
type canonicalRecorder struct {
	findings  []string
	decisions []string
}

func (c *canonicalRecorder) OnFinding(f obscel.Finding) {
	c.findings = append(c.findings, obscel.CanonicalFinding(f))
}

func (c *canonicalRecorder) OnDecision(d obscel.Decision) {
	c.decisions = append(c.decisions, CanonicalDecision(d))
}

// Lines returns sorted findings followed by sorted decisions. Sorting is what
// makes the comparison a claim about CONTENT: two runs that produce the same set
// in a different order are the same run as far as the oracle is concerned, and
// an order difference that mattered would show up as a window/decision
// difference instead.
func (c *canonicalRecorder) Lines() []string {
	out := make([]string, 0, len(c.findings)+len(c.decisions))
	out = append(out, sortedCopy(c.findings)...)
	out = append(out, sortedCopy(c.decisions)...)
	return out
}

// NewCanonicalRecorder returns an Observer that accumulates canonical lines,
// for a live capture that is to be compared against a replay.
func NewCanonicalRecorder() interface {
	Observer
	Lines() []string
} {
	return &canonicalRecorder{}
}

// discardSink accepts and drops. Replay must not write its findings back: the
// store already holds the live run's output, and appending a second copy would
// change the input of the next replay.
type discardSink struct{}

func (discardSink) IngestObservation(_ context.Context, _ *model.Observation) error { return nil }

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

// ReplayCommandName is the argv[1] that selects replay mode.
const ReplayCommandName = "replay"

// IsReplayInvocation reports whether argv selects the replay subcommand. Kept
// separate from RunReplayCommand so main.go's branch is one readable line.
func IsReplayInvocation(argv []string) bool {
	return len(argv) > 1 && argv[1] == ReplayCommandName
}

// RunReplayCommand parses the replay flags and runs it, returning a process exit
// code. The store is supplied by the caller so main.go owns store construction
// and this stays testable without touching the environment.
func RunReplayCommand(ctx context.Context, argv []string, open func() (store.SignalStore, error)) int {
	fs := flag.NewFlagSet("signal-ingest "+ReplayCommandName, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	var (
		bundlesDir = fs.String("bundles", DefaultBundlesDir, "directory of policy bundles to replay with")
		fromRaw    = fs.String("from", "", "start of the observation range, RFC3339 (required)")
		toRaw      = fs.String("to", "", "end of the observation range, RFC3339 (required)")
		tenant     = fs.String("tenant", "", "restrict the replay to one tenant")
		outPath    = fs.String("out", "", "write canonical findings and decisions here (required)")
	)
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr,
			"usage: signal-ingest %s --bundles <dir> --from <RFC3339> --to <RFC3339> [--tenant t] --out <file>\n\n"+
				"Re-evaluates stored observations through the same stage 1 and stage 2 code the\n"+
				"live sink runs, with the clock replaced by observation timestamps, and writes the\n"+
				"canonical finding and decision projection. See\n"+
				"docs/signalloom/runbooks/slaws-policy-replay.md\n\n", ReplayCommandName)
		fs.PrintDefaults()
	}

	if err := fs.Parse(argv[2:]); err != nil {
		return 2
	}

	from, to, err := parseRange(*fromRaw, *toRaw)
	if err != nil {
		fmt.Fprintf(os.Stderr, "signal-ingest %s: %v\n", ReplayCommandName, err)
		fs.Usage()
		return 2
	}
	if *outPath == "" {
		fmt.Fprintf(os.Stderr, "signal-ingest %s: --out is required\n", ReplayCommandName)
		fs.Usage()
		return 2
	}

	st, err := open()
	if err != nil {
		fmt.Fprintf(os.Stderr, "signal-ingest %s: opening the store: %v\n", ReplayCommandName, err)
		return 1
	}
	defer func() { _ = st.Close() }()

	f, err := os.Create(*outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "signal-ingest %s: creating %s: %v\n", ReplayCommandName, *outPath, err)
		return 1
	}
	defer func() { _ = f.Close() }()

	nf, nd, err := Replay(ctx, st, ReplayOptions{
		BundlesDir: *bundlesDir,
		From:       from,
		To:         to,
		Tenant:     *tenant,
		Out:        f,
		Log:        slog.Default(),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "signal-ingest %s: %v\n", ReplayCommandName, err)
		return 1
	}

	fmt.Fprintf(os.Stdout, "replay wrote %d finding(s) and %d decision(s) to %s\n", nf, nd, *outPath)
	return 0
}

func parseRange(fromRaw, toRaw string) (from, to time.Time, err error) {
	if fromRaw == "" || toRaw == "" {
		return from, to, errors.New("--from and --to are both required")
	}
	from, err = time.Parse(time.RFC3339, fromRaw)
	if err != nil {
		return from, to, fmt.Errorf("--from %q is not RFC3339: %w", fromRaw, err)
	}
	to, err = time.Parse(time.RFC3339, toRaw)
	if err != nil {
		return from, to, fmt.Errorf("--to %q is not RFC3339: %w", toRaw, err)
	}
	if !from.Before(to) {
		return from, to, fmt.Errorf("--from %s must be before --to %s", fromRaw, toRaw)
	}
	return from, to, nil
}
