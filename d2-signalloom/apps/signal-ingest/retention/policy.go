// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// MaxRetentionPeriod is the hard ceiling on any configured retention period.
//
// It is a package constant and NOT a field on Policy, PolicySet or any options struct, and that is
// the whole point. A tenant-configurable maximum is not a maximum; it is a default with extra steps.
// Seven years is chosen because it is the outer edge of the financial-records obligations that
// justify long retention in the regulated estates Signal Loom targets (and which appear in the
// legal-hold reasons this package reconciles against). Anything beyond it is not a retention
// schedule, it is indefinite retention with a number attached.
//
// Raising this is a code change, a review and a redeploy. That is deliberate.
const MaxRetentionPeriod = 7 * 365 * 24 * time.Hour

// MinRetentionPeriod is the floor. Below it, a sweep would delete data the system has not finished
// writing, and an operator who typed "1s" meant something they did not say.
const MinRetentionPeriod = time.Hour

// MaxPropagationDelay is how long a copy has to reach its terminal disposition after its retention
// boundary passes, before the copy counts as overdue.
//
// It is the deadline the card requires every receipt to carry. 72 hours is not arbitrary: it is the
// Article 33 breach-notification window, which is the shortest externally-imposed clock Signal Loom
// operates against, so a retention deadline longer than it would mean discovering a retention
// failure after the window in which it would have had to be reported had already closed.
const MaxPropagationDelay = 72 * time.Hour

var (
	// ErrPolicyUnbounded is returned for a period that is zero, negative, or over the maximum.
	ErrPolicyUnbounded = errors.New("retention: policy period is unbounded or out of range; a tenant cannot configure retention as unlimited")

	// ErrPolicyIncomplete is returned for a policy missing a sink or tenant identifier.
	ErrPolicyIncomplete = errors.New("retention: policy is incomplete")

	// ErrPolicySetIncomplete is returned when a policy set does not cover every known sink. A gap in
	// the set is a sink nobody sweeps, which is the failure the inventory exists to prevent.
	ErrPolicySetIncomplete = errors.New("retention: policy set does not cover every sink in the inventory")

	// ErrPolicyDuplicate is returned when two policies claim the same sink.
	ErrPolicyDuplicate = errors.New("retention: policy set contains a duplicate sink")
)

// unlimitedSentinels are the strings an operator reaches for when they want retention off.
//
// They are refused at parse rather than silently coerced, because a config value of "never" that
// parses to "0s" and then to "delete immediately" is the most destructive possible reading of an
// operator's intent, and one that parses to "keep forever" is the control switched off while the
// KPI still reads green. Neither is acceptable, so neither is reachable.
var unlimitedSentinels = []string{"unlimited", "never", "forever", "indefinite", "infinite", "none", "off", "disabled", "-1"}

// Policy is the retention period for one sink within one tenant.
type Policy struct {
	TenantID string        `json:"tenant_id"`
	SinkID   string        `json:"sink_id"`
	Period   time.Duration `json:"period"`
}

// Validate reports whether the policy is bounded and complete.
func (p Policy) Validate() error {
	if strings.TrimSpace(p.TenantID) == "" {
		return fmt.Errorf("%w: tenant_id is required", ErrPolicyIncomplete)
	}
	if strings.TrimSpace(p.SinkID) == "" {
		return fmt.Errorf("%w: sink_id is required for tenant %q", ErrPolicyIncomplete, p.TenantID)
	}
	if p.Period <= 0 {
		return fmt.Errorf("%w: sink %q period %s is not positive", ErrPolicyUnbounded, p.SinkID, p.Period)
	}
	if p.Period < MinRetentionPeriod {
		return fmt.Errorf("%w: sink %q period %s is below the %s floor", ErrPolicyUnbounded, p.SinkID, p.Period, MinRetentionPeriod)
	}
	if p.Period > MaxRetentionPeriod {
		return fmt.Errorf("%w: sink %q period %s exceeds the %s maximum", ErrPolicyUnbounded, p.SinkID, p.Period, MaxRetentionPeriod)
	}
	return nil
}

// Boundary returns the instant before which data in this sink is expired, given now.
func (p Policy) Boundary(now time.Time) time.Time {
	return now.Add(-p.Period).UTC().Truncate(time.Microsecond)
}

// ParsePeriod parses a configured retention period, refusing every way of saying "unlimited".
func ParsePeriod(raw string) (time.Duration, error) {
	trimmed := strings.ToLower(strings.TrimSpace(raw))
	if trimmed == "" {
		return 0, fmt.Errorf("%w: empty period", ErrPolicyUnbounded)
	}
	for _, sentinel := range unlimitedSentinels {
		if trimmed == sentinel {
			return 0, fmt.Errorf("%w: %q is not a retention period", ErrPolicyUnbounded, raw)
		}
	}
	d, err := time.ParseDuration(trimmed)
	if err != nil {
		return 0, fmt.Errorf("%w: %q: %v", ErrPolicyUnbounded, raw, err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("%w: %q resolves to %s", ErrPolicyUnbounded, raw, d)
	}
	if d > MaxRetentionPeriod {
		return 0, fmt.Errorf("%w: %q exceeds the %s maximum", ErrPolicyUnbounded, raw, MaxRetentionPeriod)
	}
	return d, nil
}

// PolicySet is one tenant's complete retention configuration.
type PolicySet struct {
	TenantID string
	Policies []Policy
}

// DefaultPolicySet returns a bounded policy for every sink in AllSinkSpecs().
//
// Every period is positive and at or under the maximum by construction, and the set covers every
// sink — there is no path to an enforcing configuration with a hole in it, because Validate refuses
// a set that does not name every known sink.
func DefaultPolicySet(tenantID string) PolicySet {
	set := PolicySet{TenantID: tenantID}
	for _, spec := range AllSinkSpecs() {
		set.Policies = append(set.Policies, Policy{
			TenantID: tenantID,
			SinkID:   spec.ID,
			Period:   spec.DefaultPeriod,
		})
	}
	sort.Slice(set.Policies, func(i, j int) bool { return set.Policies[i].SinkID < set.Policies[j].SinkID })
	return set
}

// Validate reports whether the set is complete, duplicate-free and bounded in every entry.
func (s PolicySet) Validate(required []string) error {
	if strings.TrimSpace(s.TenantID) == "" {
		return fmt.Errorf("%w: tenant_id is required", ErrPolicyIncomplete)
	}
	seen := make(map[string]struct{}, len(s.Policies))
	for _, p := range s.Policies {
		if p.TenantID != s.TenantID {
			return fmt.Errorf("%w: policy for sink %q names tenant %q inside set for tenant %q",
				ErrPolicyIncomplete, p.SinkID, p.TenantID, s.TenantID)
		}
		if err := p.Validate(); err != nil {
			return err
		}
		if _, dup := seen[p.SinkID]; dup {
			return fmt.Errorf("%w: %q", ErrPolicyDuplicate, p.SinkID)
		}
		seen[p.SinkID] = struct{}{}
	}
	var missing []string
	for _, id := range required {
		if _, ok := seen[id]; !ok {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("%w: %v", ErrPolicySetIncomplete, missing)
	}
	return nil
}

// For returns the policy covering sinkID.
func (s PolicySet) For(sinkID string) (Policy, bool) {
	for _, p := range s.Policies {
		if p.SinkID == sinkID {
			return p, true
		}
	}
	return Policy{}, false
}
