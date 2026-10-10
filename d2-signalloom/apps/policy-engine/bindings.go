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

// Verdict is the three-valued outcome of one check. An evaluation error is
// never folded into Fail.
type Verdict string

const (
	VerdictPass  Verdict = "pass"
	VerdictFail  Verdict = "fail"
	VerdictError Verdict = "error"
)

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
