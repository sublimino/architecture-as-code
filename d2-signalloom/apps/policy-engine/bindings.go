package main

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
)

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
