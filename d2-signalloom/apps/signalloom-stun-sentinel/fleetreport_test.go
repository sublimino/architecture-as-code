// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// fakeRegistry is the fleet-manager workload registry endpoint.
type fakeRegistry struct {
	mu       sync.Mutex
	reports  []workloadReport
	auths    []string
	paths    []string
	statuses []int
	srv      *httptest.Server
}

func newFakeRegistry(t *testing.T, statuses ...int) *fakeRegistry {
	t.Helper()
	f := &fakeRegistry{statuses: statuses}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var rep workloadReport
		_ = json.Unmarshal(b, &rep)
		f.mu.Lock()
		f.reports = append(f.reports, rep)
		f.auths = append(f.auths, r.Header.Get("Authorization"))
		f.paths = append(f.paths, r.Method+" "+r.URL.Path)
		status := http.StatusOK
		if n := len(f.reports); n <= len(f.statuses) {
			status = f.statuses[n-1]
		} else if len(f.statuses) > 0 {
			status = f.statuses[len(f.statuses)-1]
		}
		f.mu.Unlock()
		w.WriteHeader(status)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeRegistry) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.reports)
}

func reportedPod(name, node string, frozen bool) *corev1.Pod {
	controller := true
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "payments", Name: name, UID: types.UID("uid-" + name),
			Labels:          map[string]string{"signalloom.ai/agent": "true", "pod-template-hash": "7d6"},
			OwnerReferences: []metav1.OwnerReference{{Kind: "ReplicaSet", Name: "agent-x-7d6", Controller: &controller}},
		},
		Spec:   corev1.PodSpec{NodeName: node, ServiceAccountName: "agent-x"},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
}

func testReporter(t *testing.T, url string, interval time.Duration) *fleetReporter {
	t.Helper()
	r := newFleetReporter(url, func() string { return testStunKey }, nil, "kusari-prod", "ip-10-0-1-7", interval)
	r.now = func() time.Time { return time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC) }
	r.tenantFor = func(p *corev1.Pod) string { return "kusari" }
	r.frozen = func(p *corev1.Pod) bool { return p.Name == "frozen-one" }
	r.listPods = func() []*corev1.Pod {
		return []*corev1.Pod{
			reportedPod("agent-x-7d6-abc", "ip-10-0-1-7", false),
			reportedPod("frozen-one", "ip-10-0-1-7", true),
			reportedPod("elsewhere", "ip-10-0-1-8", false),
			{ObjectMeta: metav1.ObjectMeta{Namespace: "fe-signalloom-agents", Name: "signalloom-warden-x",
				Labels: map[string]string{"app.kubernetes.io/name": wardenAppName}}, Spec: corev1.PodSpec{NodeName: "ip-10-0-1-7"}},
		}
	}
	return r
}

func TestWorkloadReportCarriesTheContractBody(t *testing.T) {
	reg := newFakeRegistry(t)
	r := testReporter(t, reg.srv.URL, time.Hour)
	if err := r.report(context.Background()); err != nil {
		t.Fatal(err)
	}
	if reg.paths[0] != "POST /api/v1/fleet/workloads/report" || reg.auths[0] != "Bearer "+testStunKey {
		t.Fatalf("path=%q auth=%q", reg.paths[0], reg.auths[0])
	}
	rep := reg.reports[0]
	if rep.ClusterID != "kusari-prod" || rep.Node != "ip-10-0-1-7" || rep.ReportedAt != "2026-10-04T12:00:00Z" {
		t.Fatalf("header = %+v", rep)
	}
	if len(rep.Pods) != 2 {
		t.Fatalf("want the two pods on this node (not the other node's, not the warden), got %+v", rep.Pods)
	}
	p := rep.Pods[0]
	if p.Namespace != "payments" || p.Name != "agent-x-7d6-abc" || p.UID != "uid-agent-x-7d6-abc" || p.Tenant != "kusari" || p.Frozen {
		t.Fatalf("pod = %+v", p)
	}
	if p.Owner == nil || p.Owner.Kind != "Deployment" || p.Owner.Name != "agent-x" {
		t.Fatalf("owner = %+v, want the Deployment derived from the ReplicaSet hash", p.Owner)
	}
	if p.Labels["signalloom.ai/agent"] != "true" {
		t.Fatalf("labels = %v", p.Labels)
	}
	if !rep.Pods[1].Frozen || rep.Pods[1].Name != "frozen-one" {
		t.Fatalf("frozen pod = %+v", rep.Pods[1])
	}
	if r.delivered.Load() != 1 || r.failures.Load() != 0 {
		t.Fatalf("delivered=%d failures=%d", r.delivered.Load(), r.failures.Load())
	}
}

func TestWorkloadReportOwnerFallsBackToTheController(t *testing.T) {
	controller := true
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		OwnerReferences: []metav1.OwnerReference{{Kind: "StatefulSet", Name: "agent-ss", Controller: &controller}}}}
	if o := ownerOf(pod); o == nil || o.Kind != "StatefulSet" || o.Name != "agent-ss" {
		t.Fatalf("owner = %+v", o)
	}
	if o := ownerOf(&corev1.Pod{}); o != nil {
		t.Fatalf("bare pod has no owner, got %+v", o)
	}
	rs := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		OwnerReferences: []metav1.OwnerReference{{Kind: "ReplicaSet", Name: "bare-rs", Controller: &controller}}}}
	if o := ownerOf(rs); o == nil || o.Kind != "ReplicaSet" || o.Name != "bare-rs" {
		t.Fatalf("ReplicaSet without a hash stays a ReplicaSet, got %+v", o)
	}
}

func TestWorkloadReportRunsAtStartAndEveryInterval(t *testing.T) {
	reg := newFakeRegistry(t)
	r := testReporter(t, reg.srv.URL, 20*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.run(ctx); close(done) }()
	deadline := time.Now().Add(3 * time.Second)
	for reg.count() < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if reg.count() < 3 {
		t.Fatalf("want a start report plus ticks, got %d", reg.count())
	}
}

func TestWorkloadReportFailureIsLoggedAndRetriedNextInterval(t *testing.T) {
	var log bytes.Buffer
	SetAuditOutput(&log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })
	reg := newFakeRegistry(t, http.StatusBadGateway, http.StatusUnauthorized, http.StatusOK)
	r := testReporter(t, reg.srv.URL, 10*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.run(ctx); close(done) }()
	deadline := time.Now().Add(3 * time.Second)
	for r.delivered.Load() < 1 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if r.failures.Load() < 2 || r.delivered.Load() < 1 {
		t.Fatalf("failures=%d delivered=%d", r.failures.Load(), r.delivered.Load())
	}
	out := log.String()
	if !strings.Contains(out, `"event":"fleet_report_failed"`) || !strings.Contains(out, `"kind":"server"`) || !strings.Contains(out, `"kind":"refused"`) {
		t.Fatalf("log:\n%s", out)
	}
	if !strings.Contains(out, `"event":"fleet_report_delivered"`) {
		t.Fatalf("log:\n%s", out)
	}
}

func TestWorkloadReportUnconfiguredIsAFailureNotAPanic(t *testing.T) {
	var log bytes.Buffer
	SetAuditOutput(&log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })
	r := newFleetReporter("", func() string { return "" }, nil, "", "", 0)
	if err := r.report(context.Background()); err == nil || !strings.Contains(log.String(), "unconfigured") {
		t.Fatalf("err=%v log=%s", err, log.String())
	}
	if r.interval != DefaultFleetReportInterval {
		t.Fatalf("interval default = %s", r.interval)
	}
}

func TestConfigReadsTheRemoteContractVariables(t *testing.T) {
	t.Setenv("SIGNAL_CLUSTER_ID", " kusari-prod ")
	t.Setenv("NODE_NAME", "ip-10-0-1-7")
	t.Setenv("FLEET_REPORT_INTERVAL", "90s")
	t.Setenv("FLEET_POLL_INTERVAL", "5s")
	cfg, err := parseConfig(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ClusterID != "kusari-prod" || cfg.NodeName != "ip-10-0-1-7" || cfg.FleetReportInterval != 90*time.Second || cfg.FleetPollInterval != 5*time.Second {
		t.Fatalf("cfg = %+v", cfg)
	}
	t.Setenv("FLEET_REPORT_INTERVAL", "")
	t.Setenv("FLEET_POLL_INTERVAL", "")
	cfg, err = parseConfig(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FleetReportInterval != DefaultFleetReportInterval || cfg.FleetPollInterval != DefaultFleetPollInterval {
		t.Fatalf("defaults = %s / %s", cfg.FleetReportInterval, cfg.FleetPollInterval)
	}
	t.Setenv("FLEET_REPORT_INTERVAL", "-1s")
	if _, err := parseConfig(nil); err == nil {
		t.Fatal("negative interval must be rejected")
	}
	t.Setenv("FLEET_REPORT_INTERVAL", "")
	t.Setenv("FLEET_POLL_INTERVAL", "soon")
	if _, err := parseConfig(nil); err == nil {
		t.Fatal("unparsable interval must be rejected")
	}
}

func TestKernelFrozenForReadsCgroupEvents(t *testing.T) {
	root := t.TempDir()
	uid := "a1b2c3d4-0000-1111-2222-333344445555"
	cg := filepath.Join(root, "kubepods", "burstable", "pod"+uid)
	mockFreezableCgroup(t, cg, true)
	f := newCgroupFreezer(root, false, "", "")
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{UID: types.UID(uid)}}
	if !kernelFrozenFor(f, pod) {
		t.Fatal("frozen 1 must report frozen")
	}
	if kernelFrozenFor(f, &corev1.Pod{ObjectMeta: metav1.ObjectMeta{UID: "ffffffff-0000-1111-2222-333344445555"}}) {
		t.Fatal("a pod without a cgroup is not frozen")
	}
}
