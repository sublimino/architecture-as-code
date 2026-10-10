package main

// Scan-boundary tests for the input-shape guard. Contract:
// policy/frameworks/CONFORMANCE.md § Input bindings.
//
// Every per-container CEL check in the CIS pack iterates
// `containers + initContainers + ephemeralContainers`, each guarded with
// `has(...) ? ... : []`. On a workload controller those live at
// `spec.template.spec`, so `object.spec.containers` is absent, the domain is
// the empty list and `.all()` is VACUOUSLY TRUE. A maximally hostile
// Deployment therefore scored `pass` on most of the pack before the guard.
// These tests drive the real handleScan, not the CEL engine directly.

import (
	"encoding/json"
	"sort"
	"testing"
)

const cisPackID = "cis-kubernetes"

// hostilePodSpec is a pod spec that violates every CIS control it can:
// privileged, host namespaces, a hostPath of /, a hostPort, runAsUser 0,
// added NET_ADMIN and NET_RAW, a secret in env, no seccomp profile and no
// securityContext worth the name. On Linux only `no-windows-hostprocess` can
// legitimately pass.
func hostilePodSpec() map[string]any {
	return map[string]any{
		"hostPID":                      true,
		"hostIPC":                      true,
		"hostNetwork":                  true,
		"automountServiceAccountToken": true,
		"volumes": []any{
			map[string]any{"name": "root", "hostPath": map[string]any{"path": "/"}},
		},
		"containers": []any{
			map[string]any{
				"name":  "hostile",
				"image": "attacker/tools:latest",
				"securityContext": map[string]any{
					"privileged":               true,
					"allowPrivilegeEscalation": true,
					"runAsUser":                0,
					"capabilities": map[string]any{
						"add": []any{"NET_ADMIN", "NET_RAW"},
					},
				},
				"ports": []any{map[string]any{"containerPort": 8080, "hostPort": 8080}},
				"env": []any{
					map[string]any{
						"name":      "TOKEN",
						"valueFrom": map[string]any{"secretKeyRef": map[string]any{"name": "creds", "key": "token"}},
					},
				},
				"volumeMounts": []any{map[string]any{"name": "root", "mountPath": "/host"}},
			},
		},
	}
}

// hostilePod is the hostile spec as a bare Pod in the default namespace.
func hostilePod() map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata":   map[string]any{"name": "hostile", "namespace": "default"},
		"spec":       hostilePodSpec(),
	}
}

// controllerKinds are the kinds the engine normalises itself. Dropping one
// from this list must turn TestScanGuard_ControllerWrappingPreservesVerdicts
// red for that kind.
var controllerKinds = []string{"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "ReplicationController"}

// wrapInController wraps a pod-shaped object in a workload controller the way
// a real Kubernetes manifest does: the pod's metadata becomes the pod
// template's metadata MINUS its namespace, which moves to the controller —
// the only place a real manifest carries it. So a scanner that unwraps the
// template but does not copy the namespace back loses
// `object.metadata.namespace` and the invariance test catches it.
func wrapInController(kind string, pod map[string]any) map[string]any {
	tmplMeta := map[string]any{}
	namespace, hasNamespace := any(nil), false
	if m, ok := pod["metadata"].(map[string]any); ok {
		for k, v := range m {
			if k == "namespace" {
				namespace, hasNamespace = v, true
				continue
			}
			tmplMeta[k] = v
		}
	}
	template := map[string]any{}
	if len(tmplMeta) > 0 {
		template["metadata"] = tmplMeta
	}
	if spec, ok := pod["spec"]; ok {
		template["spec"] = spec
	}

	meta := map[string]any{"name": "owner"}
	if hasNamespace {
		meta["namespace"] = namespace
	}
	spec := map[string]any{"replicas": 3, "selector": map[string]any{"matchLabels": map[string]any{"app": "x"}}}
	if kind == "CronJob" {
		spec = map[string]any{"schedule": "* * * * *", "jobTemplate": map[string]any{"spec": map[string]any{"template": template}}}
	} else {
		spec["template"] = template
	}
	return map[string]any{"apiVersion": "apps/v1", "kind": kind, "metadata": meta, "spec": spec}
}

// cisScanner scans one object against the CIS pack through handleScan and
// returns the verdict vector keyed by check ID. One handler, one engine.
type cisScanner struct {
	tr      handlerTransport
	version string
}

func newCISScanner(t *testing.T) cisScanner {
	t.Helper()
	root := conformancePolicyRoot(t)
	h, err := newComplianceHandler(root)
	if err != nil {
		t.Fatal(err)
	}
	var version string
	for _, p := range loadConformancePacks(t, root) {
		if p.fw.ID == cisPackID {
			version = p.fw.Version
		}
	}
	if version == "" {
		t.Fatalf("no %s pack found", cisPackID)
	}
	return cisScanner{tr: handlerTransport{h}, version: version}
}

func (s cisScanner) verdicts(t *testing.T, object map[string]any) map[string]Verdict {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"namespace":     "conformance",
		"frameworks":    []string{cisPackID},
		"policyVersion": s.version,
		"object":        object,
	})
	if err != nil {
		t.Fatal(err)
	}
	results, err := s.tr.scan(body)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]Verdict{}
	for _, r := range results {
		out[r.Check] = r.Status
	}
	return out
}

func tally(v map[string]Verdict) map[Verdict]int {
	out := map[Verdict]int{}
	for _, s := range v {
		out[s]++
	}
	return out
}

func diffVerdicts(want, got map[string]Verdict) []string {
	var out []string
	ids := map[string]bool{}
	for id := range want {
		ids[id] = true
	}
	for id := range got {
		ids[id] = true
	}
	var sorted []string
	for id := range ids {
		sorted = append(sorted, id)
	}
	sort.Strings(sorted)
	for _, id := range sorted {
		if want[id] != got[id] {
			out = append(out, id+": got "+string(got[id])+", want "+string(want[id]))
		}
	}
	return out
}

// The measured defect. Before the guard, the hostile Deployment scored 14 of
// 17 CIS checks `pass` — and the 3 non-passes were absent-field fails, not
// detections. After it, the engine unwraps the pod template and the verdict
// vector is the bare pod's: 16 fail, 1 pass (`no-windows-hostprocess`, which
// a Linux pod legitimately satisfies).
func TestScanGuard_HostileDeploymentHasNoVacuousPass(t *testing.T) {
	s := newCISScanner(t)

	pod := s.verdicts(t, hostilePod())
	podTally := tally(pod)
	if podTally[VerdictPass] != 1 || podTally[VerdictFail] != 16 {
		t.Fatalf("bare hostile pod: tally %v, want 1 pass / 16 fail", podTally)
	}
	if pod["no-windows-hostprocess"] != VerdictPass {
		t.Fatalf("bare hostile pod: no-windows-hostprocess = %s, want pass", pod["no-windows-hostprocess"])
	}

	for _, kind := range controllerKinds {
		t.Run(kind, func(t *testing.T) {
			got := s.verdicts(t, wrapInController(kind, hostilePod()))
			if n := tally(got)[VerdictPass]; n > 1 {
				t.Errorf("hostile %s scored %d passes (vacuous): %v", kind, n, got)
			}
			for _, d := range diffVerdicts(pod, got) {
				t.Errorf("hostile %s: %s", kind, d)
			}
		})
	}
}
