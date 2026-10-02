// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil, WithBearerToken(testIngestToken))

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

// sampleUnattributedObservation is a workload the operator's tenant map does
// not name (review M5). It travels with signal-ingest's reserved quarantine
// tenant rather than being dropped or filed under kusari.
func sampleUnattributedObservation() TelemetryObservation {
	o := sampleObservation()
	o.ActorID, o.PodName, o.TenantID = "cardvault-agent", "agent-cardvault-5b7c", UnattributedTenantID
	return o
}

func TestIngestPayloadMatchesTheGoldenContract(t *testing.T) {
	got, err := json.MarshalIndent([]ingestObservation{
		sampleObservation().toIngest(), sampleUnattributedObservation().toIngest(),
	}, "", "  ")
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

// Review M4/M5 (2026-10-02): toIngest copied every pod label onto the wire.
// Pod labels are chosen by whoever deploys the pod, so in a multi-tenant
// cluster they are attacker-influenced; they also blew through signal-ingest's
// closed segment label allow-list. The wire now carries the sentinel's own
// keys and nothing else.
//
// Correction: that change (39605eb2) also claimed a pod label could not
// override tenant_id. It could -- NormalizeObservation copied tenant_id FROM
// the pod's `tenant` label, before this filter ever ran. Attribution now comes
// from the operator's TenantMap; see tenancy_test.go.
func TestIngestLabelsAreExactlyTheSentinelsOwnKeys(t *testing.T) {
	o := sampleObservation()
	o.Labels = map[string]string{"syscall": "forged", "tenant_id": "other-tenant", "evil": "x"}
	got := o.toIngest().Labels
	want := map[string]bool{"syscall": true, "target": true, "pod_name": true, "namespace": true,
		"tenant_id": true, "severity": true, "direct_reaction": true, "cgroup_path": true}
	for k := range got {
		if !want[k] {
			t.Fatalf("wire label %q is not a sentinel key; pod labels must not reach signal-ingest (%v)", k, got)
		}
	}
	if got["syscall"] != SyscallNameOpenat || got["tenant_id"] != "kusari" {
		t.Fatalf("a pod label overrode a sentinel key: %v", got)
	}
}

// signal-ingest redacts labels.target at Append, but the stored id was
// "<ns>/<pod>:<ts>:<syscall>:<target>", so a home-directory username reached
// the store through the id. The id now carries a digest of the target.
func TestObservationIDCarriesATargetDigestNotThePath(t *testing.T) {
	o := sampleObservation()
	o.Target = "/home/alice/.ssh/id_rsa"
	id := o.toIngest().ID
	if strings.Contains(id, "alice") || strings.Contains(id, o.Target) || strings.Contains(id, "/home/") {
		t.Fatalf("observation id carries the raw target path: %q", id)
	}
	sum := sha256.Sum256([]byte(o.Target))
	if want := hex.EncodeToString(sum[:])[:16]; !strings.HasSuffix(id, ":"+want) {
		t.Fatalf("id %q does not end in the target digest %q", id, want)
	}
}

// The same leak through the other two stored strings. Nothing in the repo
// parses a path out of raw_evidence_ref (frostdb keeps a keyed digest of it,
// correlation and the dashboard treat it as opaque), so it carries the digest.
// The path survives only in labels.target, which signal-ingest redacts.
func TestEvidenceRefAndDescriptionCarryNoTargetPath(t *testing.T) {
	o := sampleObservation()
	o.Target = "/home/alice/.ssh/id_rsa"
	got := o.toIngest()
	digest := targetDigest(o.Target)
	if want := "ebpf://" + o.Syscall + "/" + digest; got.RawEvidenceRef != want {
		t.Fatalf("raw_evidence_ref = %q, want %q", got.RawEvidenceRef, want)
	}
	for field, v := range map[string]string{"raw_evidence_ref": got.RawEvidenceRef, "description": got.Description} {
		if strings.Contains(v, "alice") || strings.Contains(v, "/home/") || strings.Contains(v, o.Target) {
			t.Fatalf("%s carries the raw target path: %q", field, v)
		}
	}
	if !strings.Contains(got.Description, digest) || !strings.Contains(got.Description, o.Namespace+"/"+o.PodName) {
		t.Fatalf("description %q lost the target digest or the pod", got.Description)
	}
	if got.Labels["target"] != o.Target {
		t.Fatalf("labels.target = %q: the path must still reach signal-ingest there, where it is redacted", got.Labels["target"])
	}
}

func TestObservationIDsDifferForDifferentTargetsAtTheSameInstant(t *testing.T) {
	a, b := sampleObservation(), sampleObservation()
	b.Target = "/etc/shadow"
	if a.toIngest().ID == b.toIngest().ID {
		t.Fatal("two opens of different files by the same pod at the same instant share an ID")
	}
}
