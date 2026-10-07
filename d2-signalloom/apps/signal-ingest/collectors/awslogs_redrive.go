// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// RedriveResult reports what the redrive command accomplished.
type RedriveResult struct {
	Redriven    uint64 `json:"redriven"`
	Duplicates  uint64 `json:"duplicates"`
	Discarded   uint64 `json:"discarded"`
	Unparseable uint64 `json:"unparseable"`
}

// RedriveOptions allows programmatic invocation of the redrive command with injected
// streams and options (for tests).
type RedriveOptions struct {
	Argv        []string
	OpenStore   func() (store.SignalStore, error)
	AWSLogsOpts []awslogs.Option
	Out         io.Writer
	Err         io.Writer
}

// IsRedriveInvocation reports whether argv selects the awslogs redrive subcommand.
func IsRedriveInvocation(argv []string) bool {
	return len(argv) >= 3 && argv[1] == "awslogs" && argv[2] == "redrive"
}

// RunRedriveCommand parses redrive flags, connects to the dead-letter queue, and
// replays notifications through the standard projection and deduplication sink.
func RunRedriveCommand(ctx context.Context, argv []string, open func() (store.SignalStore, error)) int {
	return RunRedriveWithOptions(ctx, RedriveOptions{
		Argv:      argv,
		OpenStore: open,
		Out:       os.Stdout,
		Err:       os.Stderr,
	})
}

// RunRedriveWithOptions executes the redrive subcommand with explicit options.
func RunRedriveWithOptions(ctx context.Context, opts RedriveOptions) int {
	out := opts.Out
	if out == nil {
		out = os.Stdout
	}
	errOut := opts.Err
	if errOut == nil {
		errOut = os.Stderr
	}

	fs := flag.NewFlagSet("signal-ingest awslogs redrive", flag.ContinueOnError)
	fs.SetOutput(errOut)

	var (
		queue   = fs.String("queue", "", "DLQ URL to redrive messages from (required)")
		account = fs.String("account", "", "AWS account ID to redrive for")
		max     = fs.Int("max", 1000, "maximum number of records to redrive")
		dryRun  = fs.Bool("dry-run", false, "receive and project records without deleting from DLQ")
	)

	fs.Usage = func() {
		fmt.Fprintf(errOut,
			"usage: signal-ingest awslogs redrive --queue <dlq-url> [--account <id>] [--max <n>] [--dry-run]\n\n"+
				"Replays dead-lettered S3 notifications through the identical projection and sink composition,\n"+
				"deduplicated by derived Observation.ID. See docs/signalloom/runbooks/slaws-awslogs-accounts.md\n\n")
		fs.PrintDefaults()
	}

	if len(opts.Argv) < 3 {
		fs.Usage()
		return 2
	}
	if err := fs.Parse(opts.Argv[3:]); err != nil {
		return 2
	}

	if *queue == "" {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: --queue is required\n")
		fs.Usage()
		return 2
	}
	if *max <= 0 {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: --max must be greater than 0, got %d\n", *max)
		fs.Usage()
		return 2
	}

	var cfg awslogs.AWSCollectorConfig
	cfgs, err := awslogs.AccountsFromEnv()
	if err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: parsing %s: %v\n", awslogs.EnvAccounts, err)
		return 1
	}

	if len(cfgs) > 0 {
		if *account != "" {
			found := false
			for _, c := range cfgs {
				if c.AccountID == *account {
					cfg = c
					found = true
					break
				}
			}
			if !found {
				fmt.Fprintf(errOut, "signal-ingest awslogs redrive: account %q not found in %s\n", *account, awslogs.EnvAccounts)
				return 1
			}
		} else {
			cfg = cfgs[0]
		}
	} else {
		cfg = awslogs.ConfigFromEnv()
	}

	cfg.QueueURL = *queue
	tempDir, err := os.MkdirTemp("", "awslogs-redrive-*")
	if err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: creating temp buffer dir: %v\n", err)
		return 1
	}
	defer func() { _ = os.RemoveAll(tempDir) }()
	cfg.BufferDir = tempDir

	st, err := opts.OpenStore()
	if err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: opening store: %v\n", err)
		return 1
	}
	defer func() { _ = st.Close() }()

	logger := slog.Default()
	deduper := NewDeduperFromEnv(logger)
	warmWindow := deduper.WarmWindow()
	if warmWindow < 14*24*time.Hour {
		warmWindow = 14 * 24 * time.Hour
	}
	if err := deduper.Warm(ctx, st, warmWindow, time.Now(), logger); err != nil {
		logger.Warn("redrive deduper warm-up failed", "error", err)
	}

	storeSink := NewStoreSink(st)
	dedupeSink := NewDedupeSink(storeSink, deduper)
	pipelineSink := BindTenant(dedupeSink, cfg.TenantID)

	colOpts := []awslogs.Option{
		awslogs.WithMode(string(awslogs.ModeLive)),
		awslogs.WithoutPollLoop(),
	}
	if *dryRun {
		colOpts = append(colOpts, awslogs.WithDryRun())
	}
	colOpts = append(colOpts, opts.AWSLogsOpts...)

	col, err := awslogs.New(cfg, pipelineSink, colOpts...)
	if err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: building collector: %v\n", err)
		return 1
	}

	if err := col.Start(ctx); err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: starting collector: %v\n", err)
		return 1
	}
	defer col.Stop()

	totalRedriven := 0
	for totalRedriven < *max {
		acked, err := col.PollOnce(ctx)
		if err != nil {
			fmt.Fprintf(errOut, "signal-ingest awslogs redrive: poll error: %v\n", err)
			return 1
		}
		if acked == 0 {
			break
		}
		totalRedriven += acked
	}

	stats := col.Stats()
	result := RedriveResult{
		Redriven:    stats["acknowledged_total"],
		Duplicates:  uint64(deduper.Dropped()),
		Discarded:   stats["discarded_total"],
		Unparseable: stats["unparseable_total"],
	}

	if err := json.NewEncoder(out).Encode(result); err != nil {
		fmt.Fprintf(errOut, "signal-ingest awslogs redrive: encoding JSON result: %v\n", err)
		return 1
	}

	return 0
}
