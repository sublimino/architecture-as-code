package main

// Input-shape guard for the `object` binding. Contract:
// policy/frameworks/CONFORMANCE.md § Input bindings.
//
// Every per-container check reads `object.spec.containers` (plus
// initContainers and ephemeralContainers), each guarded `has(x) ? x : []` so
// an absent list cannot error. On a workload controller those containers live
// at `spec.template.spec`, so the guards yield the EMPTY list, `.all()` is
// vacuously true and a hostile Deployment scores `pass`. A scan that cannot
// judge an object must say so, never report a pass it did not earn.
//
// fe-signalloom already unwraps the pod template before calling
// (`src/policy_scan.py:build_agent_object`). The engine is a network service
// with other callers, so it normalises the same kinds itself: the two agree,
// and a direct caller gets the same verdicts.

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// podTemplatePath maps a workload controller kind to the path of its pod
// template within the object. These are the kinds the engine unwraps; every
// other non-Pod kind is refused.
var podTemplatePath = map[string][]string{
	"Deployment":            {"spec", "template"},
	"StatefulSet":           {"spec", "template"},
	"DaemonSet":             {"spec", "template"},
	"ReplicaSet":            {"spec", "template"},
	"ReplicationController": {"spec", "template"},
	"Job":                   {"spec", "template"},
	"CronJob":               {"spec", "jobTemplate", "spec", "template"},
}

func supportedControllerKinds() string {
	kinds := make([]string, 0, len(podTemplatePath))
	for k := range podTemplatePath {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	return strings.Join(kinds, ", ")
}

// objectReadingIdent matches `object` or `manifest` used as a CEL identifier:
// not preceded by an identifier character or a dot (so `agent.object` and
// `agent_manifest` do not match) and not followed by one.
var objectReadingIdent = regexp.MustCompile(`(^|[^A-Za-z0-9_.])(object|manifest)([^A-Za-z0-9_]|$)`)

// readsObject reports whether a check reads the workload, and so whether the
// shape guard applies to it. An agent-only or request-only check is
// unaffected: an AIGF scan carrying no object at all keeps working.
//
// CONFORMANCE.md binds `manifest` to the same value as `object`, so BOTH
// names must be detected — a detector that knew only `object` would leave
// every manifest-reading check free to report a vacuous pass.
//
// The test is deliberately textual and deliberately over-inclusive: a string
// literal containing the word is read as a workload read, which errs toward
// `error` rather than toward an unearned `pass`.
func readsObject(celExpression string) bool {
	return objectReadingIdent.MatchString(celExpression)
}

// normalizeWorkload returns the Pod-shaped object the `object` binding is set
// to, or an error explaining why the input cannot be judged.
//
// The rule, in order:
//
//  1. An absent (or empty) object stays absent. Object-reading checks see `{}`
//     and fail their has() guards exactly as today.
//  2. A supported workload controller kind is unwrapped to its pod template,
//     with the workload's `metadata.namespace` copied into the pod's metadata
//     (a pod template carries none of its own). The unwrapped pod is then held
//     to rule 4.
//  3. Any other `kind` that is not `Pod` is refused: the engine has no
//     normalisation for it and must not pretend to judge it.
//  4. An object with no `kind`, or `kind: Pod`, is pod-shaped — except that a
//     `spec` which is present must be an object carrying a `containers` list.
//     `spec.containers` is required by the Pod schema; a present `spec`
//     without it is a controller or a non-workload resource, and is exactly
//     the shape that makes every per-container check vacuously true. A
//     wholly ABSENT `spec` is allowed: it evidences nothing, the packs fail
//     closed on it, and CONFORMANCE.md pins that behaviour
//     (cis-kubernetes `malformed-no-spec`).
func normalizeWorkload(object map[string]any) (map[string]any, error) {
	if len(object) == 0 {
		return object, nil
	}

	kind, _ := object["kind"].(string)
	if path, ok := podTemplatePath[kind]; ok {
		pod, err := unwrapPodTemplate(object, kind, path)
		if err != nil {
			return nil, err
		}
		if err := podShapeProblem(pod); err != nil {
			return nil, fmt.Errorf("%s pod template is not pod-shaped: %w", kind, err)
		}
		return pod, nil
	}
	if kind != "" && kind != "Pod" {
		return nil, fmt.Errorf("input object is not pod-shaped: kind %q is neither Pod nor a supported workload controller (%s)", kind, supportedControllerKinds())
	}
	if err := podShapeProblem(object); err != nil {
		return nil, fmt.Errorf("input object is not pod-shaped: %w", err)
	}
	return object, nil
}

// unwrapPodTemplate builds the Pod the controller would create. apiVersion and
// kind are synthesised because the template carries neither and the result is,
// by construction, a Pod.
func unwrapPodTemplate(object map[string]any, kind string, path []string) (map[string]any, error) {
	node := object
	for i, key := range path {
		next, ok := node[key].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("input object is not pod-shaped: %s carries no pod template at %s", kind, strings.Join(path[:i+1], "."))
		}
		node = next
	}

	// A controller we did unwrap must yield a pod spec. The absent-spec
	// carve-out in podShapeProblem is for a directly-posted Pod only.
	spec, ok := node["spec"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("input object is not pod-shaped: %s pod template at %s carries no spec object", kind, strings.Join(path, "."))
	}
	pod := map[string]any{"apiVersion": "v1", "kind": "Pod", "spec": spec}
	meta := map[string]any{}
	if m, ok := node["metadata"].(map[string]any); ok {
		for k, v := range m {
			meta[k] = v
		}
	}
	// CONFORMANCE.md: the scanner MUST copy the workload's namespace into the
	// pod's metadata. Without it `no-default-namespace` cannot be judged.
	if wm, ok := object["metadata"].(map[string]any); ok {
		if ns, present := wm["namespace"]; present {
			meta["namespace"] = ns
		}
	}
	if len(meta) > 0 {
		pod["metadata"] = meta
	}
	return pod, nil
}

// podShapeProblem reports why a Pod-kinded object is not judgeable, or nil.
func podShapeProblem(pod map[string]any) error {
	raw, present := pod["spec"]
	if !present {
		return nil
	}
	spec, ok := raw.(map[string]any)
	if !ok {
		return fmt.Errorf("spec is %T, not an object", raw)
	}
	if containers, present := spec["containers"]; present {
		if _, ok := containers.([]any); !ok {
			return fmt.Errorf("spec.containers is %T, not a list", containers)
		}
		return nil
	}
	for _, wrapper := range []string{"template", "jobTemplate"} {
		if _, ok := spec[wrapper]; ok {
			return fmt.Errorf("spec has no containers but carries spec.%s: this looks like a workload controller — send its kind (%s) so the engine can unwrap the pod template", wrapper, supportedControllerKinds())
		}
	}
	return fmt.Errorf("spec has no containers key, so every per-container check would be vacuously true")
}

// shapedWorkload is the pair handleScan and the conformance harness both
// evaluate against: the normalised workload, and the reason it could not be
// normalised. When err is non-nil the workload is nil, so a check that does
// not read it is unaffected.
type shapedWorkload struct {
	object map[string]any
	err    error
}

func shapeWorkload(object map[string]any) shapedWorkload {
	pod, err := normalizeWorkload(object)
	if err != nil {
		return shapedWorkload{err: err}
	}
	return shapedWorkload{object: pod}
}

// verdictFor returns the guard's verdict for one check, and whether the guard
// decided it. An object-reading check over an unjudgeable object is `error`.
func (s shapedWorkload) verdictFor(celExpression string) (Verdict, string, bool) {
	if s.err == nil || !readsObject(celExpression) {
		return "", "", false
	}
	return VerdictError, s.err.Error(), true
}
