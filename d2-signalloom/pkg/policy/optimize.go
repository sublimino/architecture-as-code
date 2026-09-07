package policy

import (
	"fmt"
	"sort"
)

// Diagnostic codes. Stable identifiers so CI can gate on a code rather than on
// prose that a later edit will reword.
const (
	// WarnDuplicatePath — two rules declare the identical path.
	WarnDuplicatePath = "W001"
	// WarnRedundantDescendant — a rule is a descendant of another rule carrying
	// the same access, so it changes nothing.
	WarnRedundantDescendant = "W002"
	// WarnShadowedByDeny — a grant sits under a denied ancestor and can never be
	// reached at the host tier.
	WarnShadowedByDeny = "W003"
	// WarnUnreachableDeny — a deny sits under an ancestor deny, so it is already
	// implied.
	WarnUnreachableDeny = "W004"
	// WarnSingleTier — a filesystem rule targets one tier only, so it is outside
	// the strict-equivalence guarantee.
	WarnSingleTier = "W005"
)

// Diagnostic is one compiler warning about the rule set.
type Diagnostic struct {
	Code        string `json:"code"`
	Path        string `json:"path"`
	Against     string `json:"against,omitempty"`
	InvariantID string `json:"invariantId"`
	Detail      string `json:"detail"`
}

// OptimizeResult carries the reduced rule set and the diagnostics that explain
// every removal.
type OptimizeResult struct {
	Rules       []NormalFSRule `json:"-"`
	Removed     []NormalFSRule `json:"-"`
	Diagnostics []Diagnostic   `json:"diagnostics"`
}

// Optimize eliminates rules that cannot change any verdict and reports the ones
// that a human should look at.
//
// The safety property is that optimisation must be verdict-preserving. It is not
// asserted by inspection: compiler_test.go re-runs the full equivalence probe
// matrix against both the pre- and post-optimisation rule sets and requires the
// same answer at every point. A "simplification" that changes a security verdict
// is the worst possible bug in a policy compiler, so it gets the same oracle the
// generators get.
func Optimize(rules []NormalFSRule) OptimizeResult {
	res := OptimizeResult{Diagnostics: []Diagnostic{}}

	// Work shallowest-first so an ancestor is always classified before the
	// descendants whose reachability depends on it.
	ordered := append([]NormalFSRule(nil), rules...)
	sort.Slice(ordered, func(i, j int) bool {
		di, dj := PathDepth(ordered[i].Path), PathDepth(ordered[j].Path)
		if di != dj {
			return di < dj
		}
		return ordered[i].Path < ordered[j].Path
	})

	drop := make([]bool, len(ordered))
	for i := range ordered {
		for j := range ordered {
			if i == j || drop[i] {
				continue
			}
			a, b := ordered[i], ordered[j]

			// Duplicates are caught during normalisation, but a manifest can still
			// spell the same directory two ways, so report it rather than assume.
			if a.Path == b.Path && i > j {
				res.Diagnostics = append(res.Diagnostics, Diagnostic{
					Code: WarnDuplicatePath, Path: a.Path, Against: b.Path, InvariantID: a.InvariantID,
					Detail: fmt.Sprintf("path %s is declared more than once", a.Path),
				})
				drop[i] = true
				continue
			}

			// b must be a strict ancestor of a for any of the remaining checks.
			if a.Path == b.Path || !IsUnder(a.Path, b.Path) {
				continue
			}
			if PathDepth(b.Path) >= PathDepth(a.Path) {
				continue
			}

			switch {
			case a.Access == b.Access:
				res.Diagnostics = append(res.Diagnostics, Diagnostic{
					Code: WarnRedundantDescendant, Path: a.Path, Against: b.Path, InvariantID: a.InvariantID,
					Detail: fmt.Sprintf("%s grants %s, which its ancestor %s already grants; the rule changes no verdict",
						a.Path, a.Access, b.Path),
				})
				drop[i] = true

			case b.Access == AccessNone && a.Access != AccessNone:
				// Reported, never removed. At the host tier nono resolves by
				// longest prefix, so this grant IS reachable and removing it would
				// change behaviour — but an allow buried under a deny is almost
				// always an authoring mistake, and the operator should confirm the
				// widening is intentional.
				res.Diagnostics = append(res.Diagnostics, Diagnostic{
					Code: WarnShadowedByDeny, Path: a.Path, Against: b.Path, InvariantID: a.InvariantID,
					Detail: fmt.Sprintf("%s grants %s beneath denied ancestor %s; longest-prefix resolution makes "+
						"this an intentional hole in the denial — confirm that is meant", a.Path, a.Access, b.Path),
				})

			case b.Access == AccessNone && a.Access == AccessNone:
				res.Diagnostics = append(res.Diagnostics, Diagnostic{
					Code: WarnUnreachableDeny, Path: a.Path, Against: b.Path, InvariantID: a.InvariantID,
					Detail: fmt.Sprintf("%s is already denied by ancestor %s", a.Path, b.Path),
				})
				drop[i] = true
			}
		}
	}

	for _, r := range ordered {
		if !hasTarget(r.Targets, TargetVAP) || !hasTarget(r.Targets, TargetLandlock) {
			res.Diagnostics = append(res.Diagnostics, Diagnostic{
				Code: WarnSingleTier, Path: r.Path, InvariantID: r.InvariantID,
				Detail: fmt.Sprintf("%s targets a single tier, so it is outside the strict cross-tier equivalence guarantee", r.Path),
			})
		}
	}

	for i, r := range ordered {
		if drop[i] {
			res.Removed = append(res.Removed, r)
		} else {
			res.Rules = append(res.Rules, r)
		}
	}

	// Restore the deepest-first order the generators and the evaluator rely on.
	sort.Slice(res.Rules, func(i, j int) bool {
		di, dj := PathDepth(res.Rules[i].Path), PathDepth(res.Rules[j].Path)
		if di != dj {
			return di > dj
		}
		return res.Rules[i].Path < res.Rules[j].Path
	})
	sort.Slice(res.Diagnostics, func(i, j int) bool {
		a, b := res.Diagnostics[i], res.Diagnostics[j]
		if a.Code != b.Code {
			return a.Code < b.Code
		}
		if a.Path != b.Path {
			return a.Path < b.Path
		}
		return a.Against < b.Against
	})
	return res
}
