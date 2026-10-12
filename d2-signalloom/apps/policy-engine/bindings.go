package main

import (
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

// celBindings builds the activation every framework check is evaluated with.
// The contract lives in policy/frameworks/CONFORMANCE.md: `object` is the
// Pod-shaped workload, `manifest` aliases it, `agent` is the agent context
// document and `request` the runtime request context. An absent input is bound
// to an empty map so a check reading it fails its has() guard rather than
// erroring on an undeclared variable.
func celBindings(object, agent, request map[string]any) map[string]any {
	return map[string]any{
		"object":   orEmpty(object),
		"manifest": orEmpty(object),
		"agent":    orEmpty(agent),
		"request":  orEmpty(request),
	}
}

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// Verdict is the outcome of one check. An evaluation error is never folded
// into Fail, and a placeholder check is never evaluated at all.
type Verdict string

const (
	VerdictPass  Verdict = "pass"
	VerdictFail  Verdict = "fail"
	VerdictError Verdict = "error"
	// VerdictNotEvaluated is a placeholder check (or any check of a
	// placeholder framework): it is reported, never evaluated, and counts
	// neither as failed, errored nor exposure.
	VerdictNotEvaluated Verdict = "not_evaluated"
	// VerdictNotInForce is a REAL, evaluable check whose regime's obligations
	// do not exist on the scan's assessmentDate. It is reported, never
	// evaluated, and counts neither as passed, failed, errored nor exposure.
	//
	// It must not be pass, which would imply compliance with an obligation
	// nobody has yet, and must not be fail, which would imply breach of one.
	// It is deliberately NOT not_evaluated: that token is a property of the
	// pack (no expression exists), this one is a property of the request (the
	// expression exists and would run, but the date asked about predates the
	// duty), and the same check flips to pass or fail at a later as-of date.
	// The full argument is on applicability_scan_test.go.
	VerdictNotInForce Verdict = "not_in_force"
)

// gateVerdict maps an applicability window status onto the verdict it forces.
// Only a status the window is permitted to act on reaches here; see
// frameworks.Applicability.Gates, which refuses to act on an unverified window.
func gateVerdict(st frameworks.WindowStatus) (Verdict, string) {
	switch st {
	case frameworks.WindowNotYetInForce:
		return VerdictNotInForce, "the obligation does not apply on the assessmentDate"
	case frameworks.WindowSuperseded:
		return VerdictNotInForce, "the obligation no longer applies on the assessmentDate"
	default:
		return "", ""
	}
}

// statusPlaceholder marks a pack or check that is not yet evaluable.
const statusPlaceholder = "placeholder"

// isPlaceholder reports whether a check is not evaluated: its own status or
// its framework's status is placeholder.
func isPlaceholder(frameworkStatus, checkStatus string) bool {
	return frameworkStatus == statusPlaceholder || checkStatus == statusPlaceholder
}

func verdictOf(passed bool, err error) Verdict {
	switch {
	case err != nil:
		return VerdictError
	case passed:
		return VerdictPass
	default:
		return VerdictFail
	}
}
