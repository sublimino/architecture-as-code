package identity

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// DefaultReaperInterval defines the canonical polling period for temporal lease expiration (10s).
const DefaultReaperInterval = 10 * time.Second

// DelegationReaper runs a background temporal lease expiration sweeper to transition expired delegations.
type DelegationReaper struct {
	repo       Repository
	bus        EventBus
	interval   time.Duration
	stopCh     chan struct{}
	running    atomic.Bool
	sweepCount atomic.Uint64
	reapedRows atomic.Uint64
	crashCount atomic.Uint64
	mu         sync.Mutex
}

// NewDelegationReaper constructs a DelegationReaper configured with the specified interval.
func NewDelegationReaper(repo Repository, bus EventBus, interval ...time.Duration) *DelegationReaper {
	iv := DefaultReaperInterval
	if len(interval) > 0 && interval[0] > 0 {
		iv = interval[0]
	}
	return &DelegationReaper{
		repo:     repo,
		bus:      bus,
		interval: iv,
		stopCh:   make(chan struct{}),
	}
}

// Start spawns the background lease sweeping worker goroutine.
func (r *DelegationReaper) Start(ctx context.Context) {
	if r.running.Swap(true) {
		return
	}
	go r.runLoop(ctx)
}

// Stop cleanly terminates the background lease sweeper.
func (r *DelegationReaper) Stop() {
	if !r.running.Swap(false) {
		return
	}
	close(r.stopCh)
}

// runLoop executes the periodic sweep guarded by panic recovery and auto-restart.
func (r *DelegationReaper) runLoop(ctx context.Context) {
	defer func() {
		if rec := recover(); rec != nil {
			r.crashCount.Add(1)
			slog.Error("delegation reaper panic recovered; restarting worker", "panic", rec)
			time.Sleep(100 * time.Millisecond)
			if r.running.Load() {
				go r.runLoop(ctx)
			}
		}
	}()

	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-r.stopCh:
			return
		case now := <-ticker.C:
			r.sweepCount.Add(1)
			count, err := r.SweepExpired(ctx, now)
			if err != nil {
				slog.Warn("delegation reaper sweep failed", "error", err)
			} else if count > 0 {
				r.reapedRows.Add(uint64(count))
				slog.Info("delegation reaper swept expired temporal leases", "count", count)
				if r.bus != nil {
					_ = r.bus.Publish(ctx, TopicCacheFlush, "reaper_sweep")
				}
			}
		}
	}
}

// SweepExpired executes a single sweep of expired delegation records as of timestamp now.
func (r *DelegationReaper) SweepExpired(ctx context.Context, now time.Time) (int64, error) {
	if r.repo == nil {
		return 0, nil
	}
	return r.repo.SweepExpiredDelegations(ctx, now)
}

// Stats returns operational metrics for monitoring the sweeper health.
func (r *DelegationReaper) Stats() (sweeps, reaped, crashes uint64) {
	return r.sweepCount.Load(), r.reapedRows.Load(), r.crashCount.Load()
}
