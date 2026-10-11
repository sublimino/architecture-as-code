package main

// Unit tests for the input-shape guard in workload_shape.go, plus two
// scan-boundary tests that pin the two halves of the rule that the CIS pack
// cannot exercise: a `manifest`-reading check, and agent/request-only checks
// staying unaffected by a workload the engine refuses.

import (
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/frameworks"
)

func podSpecWith(extra map[string]any) map[string]any {
	spec := map[string]any{"containers": []any{map[string]any{"name": "c", "image": "i"}}}
	for k, v := range extra {
		spec[k] = v
	}
	return spec
}

// Rule 1: an absent or empty object stays absent, so an AIGF-style scan that
// carries no object at all is untouched by the guard.
func TestWorkloadShape_AbsentObjectIsNotRefused(t *testing.T) {
	for name, in := range map[string]map[string]any{"nil": nil, "empty": {}} {
		got, err := normalizeWorkload(in)
		if err != nil {
			t.Errorf("%s object: %v, want no error", name, err)
		}
		if len(got) != 0 {
			t.Errorf("%s object: got %v, want empty", name, got)
		}
	}
}

// Rule 2: every supported controller kind is unwrapped to its pod template,
// with apiVersion/kind synthesised and the workload's namespace copied in.
// Dropping a kind from podTemplatePath turns this red for that kind.
func TestWorkloadShape_UnwrapsEveryControllerKind(t *testing.T) {
	pod := map[string]any{
		"apiVersion": "v1", "kind": "Pod",
		"metadata": map[string]any{"name": "app", "namespace": "payments"},
		"spec":     podSpecWith(map[string]any{"hostPID": true}),
	}
	for _, kind := range controllerKinds {
		t.Run(kind, func(t *testing.T) {
			if _, ok := podTemplatePath[kind]; !ok {
				t.Fatalf("%s has no pod template path: the engine cannot normalise it", kind)
			}
			got, err := normalizeWorkload(wrapInController(kind, pod))
			if err != nil {
				t.Fatalf("%v", err)
			}
			if got["kind"] != "Pod" || got["apiVersion"] != "v1" {
				t.Errorf("unwrapped apiVersion/kind = %v/%v, want v1/Pod", got["apiVersion"], got["kind"])
			}
			meta, _ := got["metadata"].(map[string]any)
			if meta["namespace"] != "payments" {
				t.Errorf("metadata.namespace = %v, want payments copied from the workload", meta["namespace"])
			}
			if meta["name"] != "app" {
				t.Errorf("metadata.name = %v, want the pod template's name", meta["name"])
			}
			spec, _ := got["spec"].(map[string]any)
			if spec["hostPID"] != true || spec["containers"] == nil {
				t.Errorf("spec = %v, want the pod template's spec", spec)
			}
		})
	}
}

// A controller whose pod template (or its spec) is missing is refused rather
// than falling through to a pod with no containers.
func TestWorkloadShape_RefusesControllerWithoutPodTemplate(t *testing.T) {
	cases := map[string]map[string]any{
		"no template":      {"kind": "Deployment", "spec": map[string]any{"replicas": 2}},
		"no template spec": {"kind": "Deployment", "spec": map[string]any{"template": map[string]any{"metadata": map[string]any{"name": "x"}}}},
		"no jobTemplate":   {"kind": "CronJob", "spec": map[string]any{"schedule": "* * * * *"}},
	}
	for name, in := range cases {
		if _, err := normalizeWorkload(in); err == nil {
			t.Errorf("%s: accepted, want an error", name)
		}
	}
}

// Rule 3: any other kind is refused. The engine has no normalisation for it
// and must not pretend to judge it.
func TestWorkloadShape_RefusesNonWorkloadKinds(t *testing.T) {
	for _, kind := range []string{"Service", "Secret", "ConfigMap", "Node", "deployment", "Rollout"} {
		in := map[string]any{"kind": kind, "metadata": map[string]any{"name": "x"}, "spec": podSpecWith(nil)}
		_, err := normalizeWorkload(in)
		if err == nil {
			t.Errorf("kind %q accepted as pod-shaped", kind)
			continue
		}
		if !strings.Contains(err.Error(), kind) {
			t.Errorf("kind %q: error %q does not name the kind", kind, err)
		}
	}
}

// Rule 4: kind absent or Pod is pod-shaped. A wholly absent spec is allowed
// (the packs fail closed on it; cis-kubernetes/malformed-no-spec pins that),
// but a present spec must carry a containers list.
func TestWorkloadShape_PodShapeRequirements(t *testing.T) {
	accepted := map[string]map[string]any{
		"kind Pod":             {"kind": "Pod", "spec": podSpecWith(nil)},
		"kind absent":          {"spec": podSpecWith(nil)},
		"no spec at all":       {"kind": "Pod", "metadata": map[string]any{"name": "x"}},
		"empty container list": {"kind": "Pod", "spec": map[string]any{"containers": []any{}}},
	}
	for name, in := range accepted {
		if _, err := normalizeWorkload(in); err != nil {
			t.Errorf("%s refused: %v", name, err)
		}
	}

	refused := map[string]struct {
		in   map[string]any
		want string
	}{
		"spec without containers": {map[string]any{"kind": "Pod", "spec": map[string]any{"hostPID": true}}, "no containers key"},
		"containers not a list":   {map[string]any{"kind": "Pod", "spec": map[string]any{"containers": map[string]any{}}}, "not a list"},
		"spec not an object":      {map[string]any{"kind": "Pod", "spec": "privileged"}, "not an object"},
		// A controller shape with no kind to unwrap by: named as such, because
		// guessing the wrapper is worse than refusing it.
		"kindless controller": {map[string]any{"spec": map[string]any{"template": map[string]any{"spec": podSpecWith(nil)}}}, "send its kind"},
		"kindless cronjob":    {map[string]any{"spec": map[string]any{"jobTemplate": map[string]any{}}}, "send its kind"},
	}
	for name, tc := range refused {
		_, err := normalizeWorkload(tc.in)
		if err == nil {
			t.Errorf("%s accepted, want an error", name)
			continue
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: error %q does not contain %q", name, err, tc.want)
		}
	}
}

// The object-reading detector. `manifest` is bound to the same value as
// `object` (CONFORMANCE.md), so a detector that knew only `object` would let
// every manifest-reading check report a vacuous pass. No shipped pack uses
// `manifest`, so this is the only place that half of the rule is pinned.
func TestReadsObject_DetectsBothBindingsAndNothingElse(t *testing.T) {
	reads := []string{
		"object.spec.hostPID == false",
		"manifest.spec.hostPID == false",
		"has(object.spec) && has(agent.registry)",
		"has(agent.registry) && manifest.metadata.name != ''",
		"object",
		"manifest",
		"size(object.spec.containers) > 0",
	}
	for _, expr := range reads {
		if !readsObject(expr) {
			t.Errorf("readsObject(%q) = false, want true", expr)
		}
	}
	doesNot := []string{
		"has(agent.registry) && agent.registry.model_registered == true",
		"request.peer == 'spiffe://x'",
		"agent.object.count > 0",
		"agent.manifest_sha != ''",
		"agent.objects.all(o, o.ok)",
		"true",
	}
	for _, expr := range doesNot {
		if readsObject(expr) {
			t.Errorf("readsObject(%q) = true, want false", expr)
		}
	}
}

// --- scan boundary: the guard reaches manifest-reading checks and spares the rest.

const shapePackID = "shape-pack"

// shapeGuardHandler is a pack with one check per binding, so one scan shows
// which checks the guard touches.
func shapeGuardHandler(t *testing.T) *complianceHandler {
	t.Helper()
	root := t.TempDir()
	exprs := map[string]string{
		"object-name":      `object.metadata.name == "app"`,
		"manifest-name":    `manifest.metadata.name == "app"`,
		"agent-registered": "has(agent.registry) && agent.registry.model_registered == true",
		"request-peer":     `has(request.peer) && request.peer == "p"`,
	}
	var controls []frameworks.Control
	for _, id := range []string{"object-name", "manifest-name", "agent-registered", "request-peer"} {
		controls = append(controls, frameworks.Control{ID: "CTRL-" + id, Name: "Control " + id, Checks: []frameworks.Check{packCheck(id, exprs[id])}})
	}
	writePack(t, root, shapePackID, "v1.0", frameworks.Framework{
		ID: shapePackID, Name: "Shape", Version: "v1.0.0",
		ControlSets: []frameworks.ControlSet{{ID: "CS", Name: "Set", Controls: controls}},
	})
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func shapeScan(extra map[string]any) map[string]any {
	body := map[string]any{"namespace": "ns", "frameworks": []string{shapePackID},
		"agent":   map[string]any{"registry": map[string]any{"model_registered": true}},
		"request": map[string]any{"peer": "p"}}
	for k, v := range extra {
		body[k] = v
	}
	return body
}

func TestScanGuard_RefusedObjectErrorsBothWorkloadBindingsOnly(t *testing.T) {
	h := shapeGuardHandler(t)
	res := postScan(t, h, shapeScan(map[string]any{
		"object": map[string]any{"kind": "Service", "metadata": map[string]any{"name": "app"}},
	}))
	for _, id := range []string{"object-name", "manifest-name"} {
		assertStatus(t, res, id, "error")
		if msg, _ := res[id]["error"].(string); !strings.Contains(msg, "not pod-shaped") {
			t.Errorf("check %q: error %q, want the shape-guard text", id, msg)
		}
	}
	// Agent-only and request-only checks are untouched by a refused workload.
	assertStatus(t, res, "agent-registered", "pass")
	assertStatus(t, res, "request-peer", "pass")
}

// The engine unwraps the controller itself, so a direct caller that posts a
// Deployment gets the pod template's verdicts — including on `manifest`.
func TestScanGuard_ControllerIsUnwrappedForBothBindings(t *testing.T) {
	h := shapeGuardHandler(t)
	pod := map[string]any{"metadata": map[string]any{"name": "app", "namespace": "payments"}, "spec": podSpecWith(nil)}
	res := postScan(t, h, shapeScan(map[string]any{"object": wrapInController("Deployment", pod)}))
	assertStatus(t, res, "object-name", "pass")
	assertStatus(t, res, "manifest-name", "pass")
}

// A scan with no object at all keeps working exactly as before: the guard does
// not fire, and the object checks error from CEL's own missing-key text.
func TestScanGuard_ScanWithoutObjectIsUnaffected(t *testing.T) {
	res := postScan(t, shapeGuardHandler(t), shapeScan(nil))
	assertStatus(t, res, "agent-registered", "pass")
	assertStatus(t, res, "request-peer", "pass")
	for _, id := range []string{"object-name", "manifest-name"} {
		assertStatus(t, res, id, "error")
		msg, _ := res[id]["error"].(string)
		if !strings.Contains(msg, "no such key: metadata") {
			t.Errorf("check %q: error %q, want CEL's missing-key text (the guard must not fire)", id, msg)
		}
	}
}
