// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestIsEndpointClass(t *testing.T) {
	endpoint := []string{"process_exec", "file_access", "kprobe:cap_capable", "tracepoint:syscalls/sys_enter_execve"}
	notEndpoint := []string{"network_connect", "unattributed", ""}
	for _, c := range endpoint {
		if !IsEndpointClass(c) {
			t.Errorf("IsEndpointClass(%q) = false, want true", c)
		}
	}
	for _, c := range notEndpoint {
		if IsEndpointClass(c) {
			t.Errorf("IsEndpointClass(%q) = true, want false", c)
		}
	}
}

func TestEndpointSyscall(t *testing.T) {
	cases := map[string]string{
		"file_access":                        "openat",
		"process_exec":                       "execve",
		"kprobe:__x64_sys_ptrace":            "__x64_sys_ptrace",
		"kprobe:cap_capable":                 "cap_capable",
		"tracepoint:syscalls/sys_enter_open": "sys_enter_open",
		"network_connect":                    "",
	}
	for in, want := range cases {
		if got := EndpointSyscall(in); got != want {
			t.Errorf("EndpointSyscall(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProjectEndpoint_FileAccess(t *testing.T) {
	ev := &netebpf.InboundFlowEvent{
		Time:           time.Date(2026, 10, 12, 10, 0, 0, 0, time.UTC),
		CgroupID:       1,
		SeqNum:         1,
		PodName:        "agent-snoop-0",
		PodNamespace:   "fe-signalloom-agents",
		PodUID:         "uid-snoop-0",
		ServiceAccount: "agent-snoop-sa",
		AgentRole:      "snoop_suspect",
		Provider:       "tetragon",
		Classification: ClassFileAccess,
		Domain:         "/etc/shadow",
		NodeName:       "kind-worker-1",
	}
	obs, ok := ProjectEndpoint(ev, "endpoint_testdata/sensitive-file-open.json")
	if !ok {
		t.Fatal("ProjectEndpoint skipped a file_access event")
	}
	if obs.Layer != model.LayerEndpointHost {
		t.Errorf("layer = %q, want endpoint_host", obs.Layer)
	}
	if obs.Source != EndpointObservationSource {
		t.Errorf("source = %q, want %q", obs.Source, EndpointObservationSource)
	}
	if obs.ActorHint != "agent-snoop-sa" {
		t.Errorf("ActorHint = %q, want the service account (identity is never a label)", obs.ActorHint)
	}
	if obs.Labels["target"] != "/etc/shadow" {
		t.Errorf("target = %q, want /etc/shadow", obs.Labels["target"])
	}
	if obs.Labels["syscall"] != "openat" {
		t.Errorf("syscall = %q, want openat", obs.Labels["syscall"])
	}
	if _, ok := obs.Labels["service_account"]; !ok {
		t.Error("service_account label missing")
	}
	assertEndpointLabelsAllowListed(t, obs)
}

func TestProjectEndpoint_SkipsNetworkConnect(t *testing.T) {
	ev := &netebpf.InboundFlowEvent{
		Classification: ClassNetworkConnect,
		PodName:        "agent-x",
		ServiceAccount: "agent-x-sa",
	}
	if _, ok := ProjectEndpoint(ev, "ref"); ok {
		t.Error("ProjectEndpoint projected a network_connect; that is egress, not endpoint_host")
	}
	if _, ok := ProjectEndpoint(nil, "ref"); ok {
		t.Error("ProjectEndpoint projected a nil event")
	}
}

func TestFixtureEndpointObservationsAreAllowListClean(t *testing.T) {
	obs, err := FixtureEndpointObservations()
	if err != nil {
		t.Fatalf("FixtureEndpointObservations: %v", err)
	}
	if len(obs) == 0 {
		t.Fatal("endpoint fixture corpus is empty; every downstream assertion would be vacuous")
	}
	ids := map[string]bool{}
	for i := range obs {
		o := obs[i]
		if o.Source != EndpointObservationSource {
			t.Errorf("observation %s has source %q, want %q", o.ID, o.Source, EndpointObservationSource)
		}
		if o.RawEvidenceRef == "" {
			t.Errorf("observation %s has no RawEvidenceRef; negative-discipline attribution would fail", o.ID)
		}
		if ids[o.ID] {
			t.Errorf("duplicate observation ID %q; the e2e deduper would drop one and skew counts", o.ID)
		}
		ids[o.ID] = true
		assertEndpointLabelsAllowListed(t, o)
	}
}

// assertEndpointLabelsAllowListed checks every label key is in the segment label
// allow-list (store/label_allowlist.go). Every endpoint key is already allowed —
// unlike netebpf, this stream introduces NO new label key.
func assertEndpointLabelsAllowListed(t *testing.T, o model.Observation) {
	t.Helper()
	allowed := map[string]bool{
		"classification": true, "syscall": true, "target": true, "pod_name": true,
		"namespace": true, "node": true, "agent_role": true, "service_account": true,
		"pod_uid": true, "provider": true, "direction": true,
	}
	for k := range o.Labels {
		if !allowed[k] {
			t.Errorf("observation %s carries non-allow-listed label key %q", o.ID, k)
		}
	}
}
