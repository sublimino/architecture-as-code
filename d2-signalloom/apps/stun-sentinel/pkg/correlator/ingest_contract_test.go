// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// signal-ingest's POST /api/v1/observations decodes a JSON ARRAY of its own
// model.Observation and requires id, timestamp, layer, fidelity and source.
// The correlator posted a single object in a different shape, so every post was
// a 400 (measured live 2026-10-01: "signal-ingest returned HTTP status 400").
// The golden file below is the contract; signal-ingest validates the same
// file with its real model.Observation.Validate in
// signal-ingest/api/sentinel_contract_test.go.

const goldenIngest = "testdata/ingest-observation.golden.json"

func sampleObservation() TelemetryObservation {
	return TelemetryObservation{
		Timestamp:      "2026-10-01T22:35:33.123456789Z",
		ActorID:        "kusari-agent",
		TenantID:       "kusari",
		PodName:        "agent-kusari-7d9f",
		Namespace:      "fe-signalloom-agents",
		Syscall:        SyscallNameOpenat,
		Target:         "/etc/passwd",
		Severity:       SeverityCritical,
		CgroupPath:     "/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable-pod771fb437.slice",
		DirectReaction: ReactionCgroupFrozen,
		Labels:         map[string]string{"app.kubernetes.io/name": "kusari-agent"},
	}
}

func TestDispatchPostsAnArrayInSignalIngestsObservationShape(t *testing.T) {
	var body []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil)

	if err := m.dispatchObservation(sampleObservation()); err != nil {
		t.Fatal(err)
	}
	var got []map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("body must be a JSON array: %v (%s)", err, body)
	}
	if len(got) != 1 {
		t.Fatalf("want exactly one observation, got %d", len(got))
	}
	o := got[0]
	for _, k := range []string{"id", "timestamp", "layer", "fidelity", "source"} {
		if s, _ := o[k].(string); s == "" {
			t.Fatalf("required field %q missing or empty in %s", k, body)
		}
	}
	if o["layer"] != "endpoint_host" || o["fidelity"] != "strong" {
		t.Fatalf("layer/fidelity = %v/%v", o["layer"], o["fidelity"])
	}
	labels, _ := o["labels"].(map[string]any)
	for k, want := range map[string]string{
		"syscall": "sys_enter_openat", "target": "/etc/passwd", "pod_name": "agent-kusari-7d9f",
		"namespace": "fe-signalloom-agents", "tenant_id": "kusari", "direct_reaction": ReactionCgroupFrozen,
		"cgroup_path": sampleObservation().CgroupPath,
	} {
		if labels[k] != want {
			t.Fatalf("labels[%q] = %v, want %q", k, labels[k], want)
		}
	}
}

func TestIngestPayloadMatchesTheGoldenContract(t *testing.T) {
	got, err := json.MarshalIndent([]ingestObservation{sampleObservation().toIngest()}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	got = append(got, '\n')
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(goldenIngest, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(filepath.Clean(goldenIngest))
	if err != nil {
		t.Fatalf("read golden (regenerate with UPDATE_GOLDEN=1): %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("wire payload drifted from the contract signal-ingest validates:\n got: %s\nwant: %s", got, want)
	}
}

func TestNormalizeObservationDoesNotAliasThePodsLabelMap(t *testing.T) {
	pod := agentPod("tenant-kusari")
	m, _ := pipeline(t, pod, nil)
	before := len(pod.Labels)
	obs := m.NormalizeObservation(SyscallEvent{}, pod)
	obs.Labels["injected"] = "x"
	if len(pod.Labels) != before {
		t.Fatal("NormalizeObservation must copy pod labels; writing to the observation mutated the informer's cached pod")
	}
}
