// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// Clock source labels. They are recorded in every receipt and in every SweepResult, so a regulator
// reading the ledger can see which clock authorised a deletion rather than assuming one.
const (
	// ClockSourceLocalUnverified is an unattested reading of the host clock. Named rather than left
	// implicit: a receipt that does not say which clock it trusted is a receipt that invites the
	// reader to assume the answer.
	ClockSourceLocalUnverified = "local_unverified"

	// ClockSourceTrustedSync is a reading backed by an upstream time source whose freshness and
	// drift were both inside tolerance at the moment of reading.
	ClockSourceTrustedSync = "trusted_sync"
)

// ErrClockUntrusted is returned when the clock cannot vouch for its own reading.
//
// It is a refusal, not a warning. A retention sweep computes expiry boundaries by subtraction from
// now, so a clock that is an hour fast deletes an hour of data that had not expired, and one an hour
// slow leaves an hour of expired data alive while reporting success. Neither failure announces
// itself, so the clock has to.
var ErrClockUntrusted = errors.New("retention: clock is untrusted; refusing to compute a retention boundary from it")

// Clock supplies the instant a sweep reconciles against, and its own provenance.
//
// Now returns an error rather than a bare time so that "I do not know what time it is" is
// representable. A Clock interface of the shape Now() time.Time cannot express that, which forces
// every implementation to invent an answer.
type Clock interface {
	Now() (time.Time, error)
	Source() string
}

// LocalClock reads the host clock and says so.
//
// It exists for fixtures and for a deliberately non-enforcing dry run. NewController refuses it in
// enforcing mode, so the honest label is not merely documentation — it is load-bearing.
type LocalClock struct{}

// Now returns the host clock, truncated to microseconds.
//
// Truncation happens HERE, at the source, not at receipt construction. PostgreSQL's timestamptz
// holds microseconds and Go's time.Time holds nanoseconds, so a timestamp digested in memory and
// re-digested after a database round trip differ in digits no call site can see. subjectkey/receipt.go
// records the same defect and the same fix; truncating at the source additionally means PostgreSQL's
// round-to-nearest never disagrees with Go's truncate-toward-zero.
func (LocalClock) Now() (time.Time, error) {
	return time.Now().UTC().Truncate(time.Microsecond), nil
}

// Source implements Clock.
func (LocalClock) Source() string { return ClockSourceLocalUnverified }

// TrustedClock is a reading backed by an upstream time source, with a freshness window and a drift
// tolerance, both of which fail closed.
//
// The upstream reading is supplied by Sync rather than dialled from inside Now, because a Now that
// performs I/O turns every retention decision into a network dependency on the hot path and gives
// the sweep two ways to fail for one question. Sync is called by whatever already owns the NTP or
// Roughtime client; this type owns only the trust decision.
type TrustedClock struct {
	mu sync.RWMutex

	// host reads the local clock. Injectable so the trust boundary itself is testable without
	// waiting for real time to pass.
	host func() time.Time

	freshness time.Duration
	maxDrift  time.Duration

	lastSync     time.Time // host reading at the moment of the last successful sync
	lastUpstream time.Time // upstream reading at that same moment
	synced       bool
}

// TrustedClockConfig configures a TrustedClock.
type TrustedClockConfig struct {
	// Freshness is how old the last successful sync may be before Now refuses.
	Freshness time.Duration
	// MaxDrift is how far the host may have diverged from the last upstream reading before Now
	// refuses.
	MaxDrift time.Duration
	// Host reads the local clock. Defaults to time.Now.
	Host func() time.Time
}

// DefaultClockFreshness is the default staleness window for a trusted clock.
const DefaultClockFreshness = time.Hour

// DefaultClockMaxDrift is the default drift tolerance for a trusted clock.
//
// Five seconds is tight relative to retention periods measured in days, and deliberately so: the
// point is not to catch drift that would materially change a boundary, it is to catch a host whose
// clock is no longer being maintained, long before the drift grows into something that would.
const DefaultClockMaxDrift = 5 * time.Second

// NewTrustedClock constructs a TrustedClock. It starts UNSYNCED, so Now refuses until Sync succeeds.
//
// Starting unsynced rather than optimistically trusting the host is the fail-closed choice: a
// process that boots with no upstream contact must not spend its first hour deleting data on the
// strength of a clock nobody checked.
func NewTrustedClock(cfg TrustedClockConfig) *TrustedClock {
	c := &TrustedClock{
		host:      cfg.Host,
		freshness: cfg.Freshness,
		maxDrift:  cfg.MaxDrift,
	}
	if c.host == nil {
		c.host = time.Now
	}
	if c.freshness <= 0 {
		c.freshness = DefaultClockFreshness
	}
	if c.maxDrift <= 0 {
		c.maxDrift = DefaultClockMaxDrift
	}
	return c
}

// Sync records a successful upstream reading.
func (c *TrustedClock) Sync(upstream time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastUpstream = upstream.UTC()
	c.lastSync = c.host().UTC()
	c.synced = true
}

// Now returns the trusted instant, or ErrClockUntrusted.
func (c *TrustedClock) Now() (time.Time, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if !c.synced {
		return time.Time{}, fmt.Errorf("%w: no successful upstream sync has been recorded", ErrClockUntrusted)
	}
	now := c.host().UTC()
	age := now.Sub(c.lastSync)
	if age < 0 {
		// The host clock moved backwards relative to the sync reading. That is a step change, not
		// drift, and it is exactly the condition under which a boundary computed by subtraction is
		// meaningless.
		return time.Time{}, fmt.Errorf("%w: host clock moved backwards by %s since the last sync", ErrClockUntrusted, -age)
	}
	if age > c.freshness {
		return time.Time{}, fmt.Errorf("%w: last sync was %s ago, freshness window is %s", ErrClockUntrusted, age, c.freshness)
	}
	// Expected upstream now, if both clocks ran at the same rate since the sync.
	expected := c.lastUpstream.Add(age)
	drift := now.Sub(expected)
	if drift < 0 {
		drift = -drift
	}
	if drift > c.maxDrift {
		return time.Time{}, fmt.Errorf("%w: host has drifted %s from the trusted source, tolerance is %s", ErrClockUntrusted, drift, c.maxDrift)
	}
	return now.Truncate(time.Microsecond), nil
}

// Source implements Clock.
func (c *TrustedClock) Source() string { return ClockSourceTrustedSync }

// encodeInstant renders a timestamp as its integer microseconds since the Unix epoch.
//
// Same reasoning as subjectkey.encodeInstant: not RFC3339Nano, because a timestamptz column cannot
// hold nanoseconds and a receipt round-tripped through the database would digest differently from
// the one held in memory. A whole-second test clock hides the whole class, so the receipt tests here
// use a clock with sub-microsecond digits on purpose.
func encodeInstant(t time.Time) string {
	return fmt.Sprintf("%d", t.UTC().UnixMicro())
}
