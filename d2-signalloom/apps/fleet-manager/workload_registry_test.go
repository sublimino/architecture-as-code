package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

const (
	wardenWorkloadKey    = "warden-workload-key-0123456789abcdef0123456789"
	dashboardWorkloadKey = "dashboard-workload-key-0123456789abcdef012345"
)

func testWorkloadCallerKeys(t *testing.T) *callerKeys {
	t.Helper()
	keys, err := loadCallerKeys([]string{
		"FLEET_MANAGER_KEY_WARDEN=" + wardenWorkloadKey,
		"FLEET_MANAGER_KEY_WARDEN_SCOPES=report",
		"FLEET_MANAGER_KEY_DASHBOARD=" + dashboardWorkloadKey,
		"FLEET_MANAGER_KEY_DASHBOARD_SCOPES=read",
	})
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

func validWorkloadReport(at time.Time) WorkloadReport {
	return WorkloadReport{
		ClusterID:             "cluster-a",
		Node:                  "node-a",
		ReportedAt:            at.UTC().Format(time.RFC3339),
		ReportIntervalSeconds: 60,
		Pods: []ReportedPod{
			{
				Namespace: "tenant-a",
				Name:      "api-0",
				UID:       "uid-api-0",
				Owner: ReportedPodOwner{
					Kind: "StatefulSet",
					Name: "api",
				},
				Tenant: "tenant-a",
				Labels: map[string]string{
					"app.kubernetes.io/name": "api",
				},
			},
		},
	}
}

func marshalWorkloadReport(t *testing.T, report WorkloadReport) string {
	t.Helper()
	body, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestHandleWorkloadReportValidation(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	s := &server{workloads: NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })}

	manyPodsBody := `{"cluster_id":"cluster-a","node":"node-a","reported_at":"2026-10-04T12:00:00Z","report_interval_seconds":60,"pods":[` +
		strings.TrimSuffix(strings.Repeat("{},", 10001), ",") + `]}`

	tests := []struct {
		name      string
		mutate    func(*WorkloadReport)
		rawBody   string
		wantCode  int
		wantField string
	}{
		{
			name:     "valid baseline",
			wantCode: http.StatusOK,
		},
		{
			name: "cluster id",
			mutate: func(report *WorkloadReport) {
				report.ClusterID = "Cluster_A"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "cluster_id",
		},
		{
			name: "node",
			mutate: func(report *WorkloadReport) {
				report.Node = "Node_A"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "node",
		},
		{
			name: "reported at",
			mutate: func(report *WorkloadReport) {
				report.ReportedAt = "yesterday"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "reported_at",
		},
		{
			name: "report interval range",
			mutate: func(report *WorkloadReport) {
				report.ReportIntervalSeconds = int(^uint(0) >> 1)
			},
			wantCode:  http.StatusBadRequest,
			wantField: "report_interval_seconds",
		},
		{
			name:      "pod count",
			rawBody:   manyPodsBody,
			wantCode:  http.StatusBadRequest,
			wantField: "pods",
		},
		{
			name: "namespace",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Namespace = "Tenant_A"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "namespace",
		},
		{
			name: "name",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Name = "API_0"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "name",
		},
		{
			name: "tenant",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Tenant = "Tenant_A"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "tenant",
		},
		// uid is OPTIONAL, so an empty one is accepted: only its bounds are
		// enforced. A row asserting that "" is rejected would be asserting the
		// opposite of the contract.
		{
			name: "uid too long",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].UID = strings.Repeat("u", 65)
			},
			wantCode:  http.StatusBadRequest,
			wantField: "uid",
		},
		{
			name: "uid not printable ascii",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].UID = "uid-\x00-api"
			},
			wantCode:  http.StatusBadRequest,
			wantField: "uid",
		},
		{
			name: "uid absent is accepted",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].UID = ""
			},
			wantCode: http.StatusOK,
		},
		{
			name: "owner kind",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Owner.Kind = ""
			},
			wantCode:  http.StatusBadRequest,
			wantField: "owner.kind",
		},
		{
			name: "owner name",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Owner.Name = ""
			},
			wantCode:  http.StatusBadRequest,
			wantField: "owner.name",
		},
		{
			name: "label count",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Labels = make(map[string]string, 65)
				for i := 0; i < 65; i++ {
					report.Pods[0].Labels[fmt.Sprintf("label-%02d", i)] = "value"
				}
			},
			wantCode:  http.StatusBadRequest,
			wantField: "labels",
		},
		{
			name: "label key",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Labels = map[string]string{"bad key": "value"}
			},
			wantCode:  http.StatusBadRequest,
			wantField: "labels",
		},
		{
			name: "label value",
			mutate: func(report *WorkloadReport) {
				report.Pods[0].Labels = map[string]string{"app": strings.Repeat("x", 64)}
			},
			wantCode:  http.StatusBadRequest,
			wantField: "labels",
		},
		{
			name: "duplicate pod",
			mutate: func(report *WorkloadReport) {
				report.Pods = append(report.Pods, report.Pods[0])
			},
			wantCode:  http.StatusBadRequest,
			wantField: "pods",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body := test.rawBody
			if body == "" {
				report := validWorkloadReport(now)
				if test.mutate != nil {
					test.mutate(&report)
				}
				body = marshalWorkloadReport(t, report)
			}

			w := call(t, http.HandlerFunc(s.handleWorkloadReport), http.MethodPost, "/api/v1/fleet/workloads/report", body)
			if w.Code != test.wantCode {
				t.Fatalf("status = %d, want %d; body=%s", w.Code, test.wantCode, w.Body.String())
			}
			if test.wantField != "" && !strings.Contains(w.Body.String(), test.wantField) {
				t.Fatalf("body %q does not name field %q", w.Body.String(), test.wantField)
			}
		})
	}
}

func TestWorkloadRegistryApplyReplacesOnlyReportingNode(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })

	nodeB := validWorkloadReport(now)
	nodeB.Node = "node-b"
	nodeB.Pods[0].Name = "worker-0"
	nodeB.Pods[0].UID = "uid-worker-0"
	if _, _, err := registry.Apply(nodeB); err != nil {
		t.Fatal(err)
	}

	nodeA := validWorkloadReport(now)
	nodeA.Pods = append(nodeA.Pods, ReportedPod{
		Namespace: "tenant-a",
		Name:      "api-1",
		UID:       "uid-api-1",
		Owner:     ReportedPodOwner{Kind: "StatefulSet", Name: "api"},
		Tenant:    "tenant-a",
	})
	if _, _, err := registry.Apply(nodeA); err != nil {
		t.Fatal(err)
	}

	nodeA.Pods = nodeA.Pods[1:]
	if _, _, err := registry.Apply(nodeA); err != nil {
		t.Fatal(err)
	}

	if _, ok := registry.ByKey("cluster-a", "tenant-a", "api-0"); ok {
		t.Fatal("pod omitted from the second node-a snapshot remained registered")
	}
	if _, ok := registry.ByKey("cluster-a", "tenant-a", "api-1"); !ok {
		t.Fatal("pod retained in the second node-a snapshot disappeared")
	}
	if _, ok := registry.ByKey("cluster-a", "tenant-a", "worker-0"); !ok {
		t.Fatal("node-a replacement removed node-b workload")
	}
}

func TestWorkloadRegistryEvictionUsesReceiptClockAndPerReportInterval(t *testing.T) {
	start := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name            string
		defaultInterval time.Duration
		reportInterval  int
		reportedAt      time.Time
		wantLifetime    time.Duration
	}{
		{
			name:            "default interval",
			defaultInterval: 10 * time.Second,
			reportedAt:      start,
			wantLifetime:    30 * time.Second,
		},
		{
			name:            "per report interval overrides default",
			defaultInterval: 60 * time.Second,
			reportInterval:  5,
			reportedAt:      start,
			wantLifetime:    15 * time.Second,
		},
		{
			name:            "future reported at cannot extend receipt lifetime",
			defaultInterval: 10 * time.Second,
			reportedAt:      start.Add(time.Hour),
			wantLifetime:    30 * time.Second,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			now := start
			registry := NewWorkloadRegistry(test.defaultInterval, func() time.Time { return now })
			report := validWorkloadReport(test.reportedAt)
			report.ReportIntervalSeconds = test.reportInterval
			if _, _, err := registry.Apply(report); err != nil {
				t.Fatal(err)
			}

			now = start.Add(test.wantLifetime)
			if got := registry.List(""); len(got) != 1 {
				t.Fatalf("entry count at exact expiry = %d, want 1", len(got))
			}

			now = now.Add(time.Nanosecond)
			if got := registry.List(""); len(got) != 0 {
				t.Fatalf("entry count just past expiry = %d, want 0", len(got))
			}
		})
	}
}

func TestWorkloadRegistryZeroPodReportClearsOnlyReportingNode(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })

	for _, node := range []string{"node-a", "node-b"} {
		report := validWorkloadReport(now)
		report.Node = node
		report.Pods[0].Name = node + "-pod"
		report.Pods[0].UID = node + "-uid"
		if _, _, err := registry.Apply(report); err != nil {
			t.Fatal(err)
		}
	}

	clearReport := validWorkloadReport(now)
	clearReport.Pods = []ReportedPod{}
	if _, _, err := registry.Apply(clearReport); err != nil {
		t.Fatal(err)
	}

	if _, ok := registry.ByKey("cluster-a", "tenant-a", "node-a-pod"); ok {
		t.Fatal("zero-pod report did not clear reporting node")
	}
	if _, ok := registry.ByKey("cluster-a", "tenant-a", "node-b-pod"); !ok {
		t.Fatal("zero-pod report cleared a different node")
	}
}

func TestHandleWorkloadReportDecodeFailures(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	s := &server{workloads: NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })}

	reportBody := marshalWorkloadReport(t, validWorkloadReport(now))
	unknownBody := strings.TrimSuffix(reportBody, "}") + `,"warden_typo":true}`

	tests := []struct {
		name     string
		body     string
		wantCode int
		wantText string
	}{
		{
			name:     "oversized body",
			body:     strings.Repeat(" ", maxWorkloadReportBytes+1),
			wantCode: http.StatusRequestEntityTooLarge,
			wantText: "exceeds",
		},
		{
			name:     "unknown field",
			body:     unknownBody,
			wantCode: http.StatusBadRequest,
			wantText: "unknown field",
		},
		{
			name:     "malformed json",
			body:     `{"cluster_id":`,
			wantCode: http.StatusBadRequest,
			wantText: "unexpected",
		},
		{
			name:     "multiple json values",
			body:     reportBody + `{}`,
			wantCode: http.StatusBadRequest,
			wantText: "one JSON object",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			w := call(t, http.HandlerFunc(s.handleWorkloadReport), http.MethodPost, "/api/v1/fleet/workloads/report", test.body)
			if w.Code != test.wantCode {
				t.Fatalf("status = %d, want %d; body=%s", w.Code, test.wantCode, w.Body.String())
			}
			if !strings.Contains(w.Body.String(), test.wantText) {
				t.Fatalf("body %q does not contain %q", w.Body.String(), test.wantText)
			}
		})
	}
}

func TestHandleWorkloadReportResponse(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(5*time.Second, func() time.Time { return now })
	s := &server{workloads: registry}

	stale := validWorkloadReport(now)
	stale.ReportIntervalSeconds = 0
	if _, _, err := registry.Apply(stale); err != nil {
		t.Fatal(err)
	}

	now = now.Add(15*time.Second + time.Nanosecond)
	current := validWorkloadReport(now)
	current.Node = "node-b"
	current.Pods[0].Name = "worker-0"
	current.Pods[0].UID = "uid-worker-0"

	w := call(t, http.HandlerFunc(s.handleWorkloadReport), http.MethodPost, "/api/v1/fleet/workloads/report", marshalWorkloadReport(t, current))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var response WorkloadReportResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.ClusterID != "cluster-a" || response.Node != "node-b" {
		t.Fatalf("identity = %q/%q, want cluster-a/node-b", response.ClusterID, response.Node)
	}
	if response.Accepted != 1 || response.Evicted != 1 || response.RegistrySize != 1 {
		t.Fatalf("counts = accepted:%d evicted:%d size:%d, want 1/1/1", response.Accepted, response.Evicted, response.RegistrySize)
	}
}

func TestHandleWorkloadsFilteringAndEmptyEncoding(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })
	s := &server{workloads: registry}

	tests := []struct {
		name        string
		path        string
		wantCode    int
		wantCount   int
		wantCluster string
	}{
		{
			name:      "empty registry",
			path:      "/api/v1/fleet/workloads",
			wantCode:  http.StatusOK,
			wantCount: 0,
		},
		{
			name:      "invalid cluster filter",
			path:      "/api/v1/fleet/workloads?cluster_id=Cluster_A",
			wantCode:  http.StatusBadRequest,
			wantCount: -1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			w := call(t, http.HandlerFunc(s.handleWorkloads), http.MethodGet, test.path, "")
			if w.Code != test.wantCode {
				t.Fatalf("status = %d, want %d; body=%s", w.Code, test.wantCode, w.Body.String())
			}
			if test.wantCount == 0 && !strings.Contains(w.Body.String(), `"workloads":[]`) {
				t.Fatalf("empty workload list encoded incorrectly: %s", w.Body.String())
			}
		})
	}

	for _, cluster := range []string{"cluster-a", "cluster-b"} {
		report := validWorkloadReport(now)
		report.ClusterID = cluster
		report.Pods[0].Name = cluster + "-pod"
		report.Pods[0].UID = cluster + "-uid"
		if _, _, err := registry.Apply(report); err != nil {
			t.Fatal(err)
		}
	}

	filterTests := []struct {
		name        string
		path        string
		wantCount   int
		wantCluster string
	}{
		{
			name:      "all clusters",
			path:      "/api/v1/fleet/workloads",
			wantCount: 2,
		},
		{
			name:        "one cluster",
			path:        "/api/v1/fleet/workloads?cluster_id=cluster-b",
			wantCount:   1,
			wantCluster: "cluster-b",
		},
	}

	for _, test := range filterTests {
		t.Run(test.name, func(t *testing.T) {
			w := call(t, http.HandlerFunc(s.handleWorkloads), http.MethodGet, test.path, "")
			if w.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
			}
			var response WorkloadListResponse
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Count != test.wantCount || len(response.Workloads) != test.wantCount {
				t.Fatalf("count = %d/%d, want %d", response.Count, len(response.Workloads), test.wantCount)
			}
			if test.wantCluster != "" && response.Workloads[0].ClusterID != test.wantCluster {
				t.Fatalf("cluster = %q, want %q", response.Workloads[0].ClusterID, test.wantCluster)
			}
		})
	}
}

func TestWorkloadRegistryCopiesLabelsAtInputAndOutputBoundaries(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })
	report := validWorkloadReport(now)

	if _, _, err := registry.Apply(report); err != nil {
		t.Fatal(err)
	}
	report.Pods[0].Labels["app.kubernetes.io/name"] = "mutated-input"

	first, ok := registry.ByKey("cluster-a", "tenant-a", "api-0")
	if !ok {
		t.Fatal("workload missing after Apply")
	}
	if got := first.Labels["app.kubernetes.io/name"]; got != "api" {
		t.Fatalf("stored input label = %q, want api", got)
	}

	first.Labels["app.kubernetes.io/name"] = "mutated-output"
	second, ok := registry.ByKey("cluster-a", "tenant-a", "api-0")
	if !ok {
		t.Fatal("workload missing after output mutation")
	}
	if got := second.Labels["app.kubernetes.io/name"]; got != "api" {
		t.Fatalf("stored output label = %q, want api", got)
	}
}

func TestWorkloadRegistryListOrderingIsStable(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })
	report := validWorkloadReport(now)
	report.Pods = []ReportedPod{
		{Namespace: "tenant-a", Name: "zeta", UID: "uid-zeta", Owner: ReportedPodOwner{Kind: "Deployment", Name: "zeta"}, Tenant: "tenant-a"},
		{Namespace: "tenant-a", Name: "alpha", UID: "uid-alpha", Owner: ReportedPodOwner{Kind: "Deployment", Name: "alpha"}, Tenant: "tenant-a"},
		{Namespace: "tenant-a", Name: "middle", UID: "uid-middle", Owner: ReportedPodOwner{Kind: "Deployment", Name: "middle"}, Tenant: "tenant-a"},
	}
	if _, _, err := registry.Apply(report); err != nil {
		t.Fatal(err)
	}

	first := registry.List("")
	second := registry.List("")
	want := []string{"alpha", "middle", "zeta"}
	for i := range want {
		if first[i].Name != want[i] {
			t.Fatalf("first order[%d] = %q, want %q", i, first[i].Name, want[i])
		}
		if second[i].Name != want[i] {
			t.Fatalf("second order[%d] = %q, want %q", i, second[i].Name, want[i])
		}
	}
}

func TestWorkloadRoutesEnforceCallerScopes(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	s := &server{
		workloads:  NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now }),
		callerKeys: testWorkloadCallerKeys(t),
	}
	handler := s.routes()
	reportBody := marshalWorkloadReport(t, validWorkloadReport(now))

	tests := []struct {
		name     string
		method   string
		path     string
		body     string
		auth     string
		wantCode int
	}{
		{
			name:     "report without key",
			method:   http.MethodPost,
			path:     "/api/v1/fleet/workloads/report",
			body:     reportBody,
			wantCode: http.StatusUnauthorized,
		},
		{
			name:     "read without key",
			method:   http.MethodGet,
			path:     "/api/v1/fleet/workloads",
			wantCode: http.StatusUnauthorized,
		},
		{
			name:     "read key cannot report",
			method:   http.MethodPost,
			path:     "/api/v1/fleet/workloads/report",
			body:     reportBody,
			auth:     "Bearer " + dashboardWorkloadKey,
			wantCode: http.StatusForbidden,
		},
		// The list route admits `read` OR `report` (see requireAny). The warden
		// holds only `report` and the remote contract still has it read the
		// registry back to confirm what the hub believes about its own cluster,
		// so this must be 200 and not 403. The asymmetry is one-way: a `read`
		// key still cannot report, which the row above pins.
		{
			name:     "report key may also read",
			method:   http.MethodGet,
			path:     "/api/v1/fleet/workloads",
			auth:     "Bearer " + wardenWorkloadKey,
			wantCode: http.StatusOK,
		},
		{
			name:     "report key can report",
			method:   http.MethodPost,
			path:     "/api/v1/fleet/workloads/report",
			body:     reportBody,
			auth:     "Bearer " + wardenWorkloadKey,
			wantCode: http.StatusOK,
		},
		{
			name:     "read key can read",
			method:   http.MethodGet,
			path:     "/api/v1/fleet/workloads",
			auth:     "Bearer " + dashboardWorkloadKey,
			wantCode: http.StatusOK,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var w interface {
				Result() *http.Response
			}
			if test.auth == "" {
				w = call(t, handler, test.method, test.path, test.body)
			} else {
				w = call(t, handler, test.method, test.path, test.body, test.auth)
			}
			if got := w.Result().StatusCode; got != test.wantCode {
				t.Fatalf("status = %d, want %d", got, test.wantCode)
			}
		})
	}
}

func TestWorkloadHandlersRejectMissingRegistryAndWrongMethod(t *testing.T) {
	now := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	reportBody := marshalWorkloadReport(t, validWorkloadReport(now))

	tests := []struct {
		name     string
		server   *server
		handler  func(*server) http.HandlerFunc
		method   string
		path     string
		body     string
		wantCode  int
		wantText  string
		wantAllow string
	}{
		{
			name:     "report nil registry",
			server:   &server{},
			handler:  func(s *server) http.HandlerFunc { return s.handleWorkloadReport },
			method:   http.MethodPost,
			path:     "/api/v1/fleet/workloads/report",
			body:     reportBody,
			wantCode: http.StatusServiceUnavailable,
			wantText: "workload registry is not configured",
		},
		{
			name:     "list nil registry",
			server:   &server{},
			handler:  func(s *server) http.HandlerFunc { return s.handleWorkloads },
			method:   http.MethodGet,
			path:     "/api/v1/fleet/workloads",
			wantCode: http.StatusServiceUnavailable,
			wantText: "workload registry is not configured",
		},
		{
			name:      "report wrong method",
			server:    &server{workloads: NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })},
			handler:   func(s *server) http.HandlerFunc { return s.handleWorkloadReport },
			method:    http.MethodGet,
			path:      "/api/v1/fleet/workloads/report",
			wantCode:  http.StatusMethodNotAllowed,
			wantText:  "method not allowed",
			wantAllow: "POST, OPTIONS",
		},
		{
			name:      "list wrong method",
			server:    &server{workloads: NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })},
			handler:   func(s *server) http.HandlerFunc { return s.handleWorkloads },
			method:    http.MethodPost,
			path:      "/api/v1/fleet/workloads",
			wantCode:  http.StatusMethodNotAllowed,
			wantText:  "method not allowed",
			wantAllow: "GET, HEAD, OPTIONS",
		},
		{
			name:     "list HEAD returns 200 with empty body",
			server:   &server{workloads: NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })},
			handler:  func(s *server) http.HandlerFunc { return s.handleWorkloads },
			method:   http.MethodHead,
			path:     "/api/v1/fleet/workloads",
			wantCode: http.StatusOK,
			wantText: "",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			w := call(t, test.handler(test.server), test.method, test.path, test.body)
			if w.Code != test.wantCode {
				t.Fatalf("status = %d, want %d; body=%s", w.Code, test.wantCode, w.Body.String())
			}
			if test.wantText != "" && !strings.Contains(w.Body.String(), test.wantText) {
				t.Fatalf("body %q does not contain %q", w.Body.String(), test.wantText)
			}
			if test.method == http.MethodHead && w.Body.Len() != 0 {
				t.Fatalf("HEAD response had body %q, want empty", w.Body.String())
			}
			if test.wantAllow != "" && w.Header().Get("Allow") != test.wantAllow {
				t.Fatalf("Allow header = %q, want %q", w.Header().Get("Allow"), test.wantAllow)
			}
		})
	}
}

func TestFleetReportIntervalFrom(t *testing.T) {
	tests := []struct {
		raw       string
		want      time.Duration
		wantError bool
	}{
		{raw: "60s", want: 60 * time.Second},
		{raw: "90", want: 90 * time.Second},
		{raw: "", want: DefaultFleetReportInterval},
		{raw: "abc", want: DefaultFleetReportInterval, wantError: true},
		{raw: "0", want: DefaultFleetReportInterval, wantError: true},
		{raw: "-5", want: DefaultFleetReportInterval, wantError: true},
	}

	for _, test := range tests {
		t.Run(test.raw, func(t *testing.T) {
			got, err := fleetReportIntervalFrom(test.raw)
			if got != test.want {
				t.Fatalf("duration = %s, want %s", got, test.want)
			}
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v, wantError=%v", err, test.wantError)
			}
		})
	}
}

func TestWorkloadRegistryQueriesCopySortAndEvict(t *testing.T) {
	start := time.Date(2026, time.October, 4, 12, 0, 0, 0, time.UTC)
	now := start
	registry := NewWorkloadRegistry(5*time.Second, func() time.Time { return now })

	report := validWorkloadReport(now)
	report.ReportIntervalSeconds = 0
	report.Pods = []ReportedPod{
		{
			Namespace: "tenant-b",
			Name:      "shared",
			UID:       "uid-b",
			Owner:     ReportedPodOwner{Kind: "Deployment", Name: "owner"},
			Tenant:    "tenant-b",
			Labels:    map[string]string{"source": "original"},
		},
		{
			Namespace: "tenant-a",
			Name:      "shared",
			UID:       "uid-a",
			Owner:     ReportedPodOwner{Kind: "Deployment", Name: "owner"},
			Tenant:    "tenant-a",
			Labels:    map[string]string{"source": "original"},
		},
		{
			Namespace: "tenant-c",
			Name:      "other",
			UID:       "uid-c",
			Owner:     ReportedPodOwner{Kind: "StatefulSet", Name: "owner"},
			Tenant:    "tenant-c",
			Labels:    map[string]string{"source": "original"},
		},
	}
	if _, _, err := registry.Apply(report); err != nil {
		t.Fatal(err)
	}

	byKey, ok := registry.ByKey("cluster-a", "tenant-a", "shared")
	if !ok {
		t.Fatal("ByKey did not find workload")
	}
	byKey.Labels["source"] = "by-key-mutation"
	byKeyAgain, ok := registry.ByKey("cluster-a", "tenant-a", "shared")
	if !ok || byKeyAgain.Labels["source"] != "original" {
		t.Fatal("ByKey did not return a defensive copy")
	}

	byPod := registry.ByPodName("shared")
	if len(byPod) != 2 {
		t.Fatalf("ByPodName count = %d, want 2", len(byPod))
	}
	if byPod[0].Namespace != "tenant-a" || byPod[1].Namespace != "tenant-b" {
		t.Fatalf("ByPodName order = %q, %q, want tenant-a, tenant-b", byPod[0].Namespace, byPod[1].Namespace)
	}
	byPod[0].Labels["source"] = "by-pod-mutation"
	byPodAgain := registry.ByPodName("shared")
	if byPodAgain[0].Labels["source"] != "original" {
		t.Fatal("ByPodName did not return defensive copies")
	}

	byOwner := registry.ByOwnerName("owner")
	if len(byOwner) != 3 {
		t.Fatalf("ByOwnerName count = %d, want 3", len(byOwner))
	}
	wantNamespaces := []string{"tenant-a", "tenant-b", "tenant-c"}
	for i, want := range wantNamespaces {
		if byOwner[i].Namespace != want {
			t.Fatalf("ByOwnerName order[%d] = %q, want %q", i, byOwner[i].Namespace, want)
		}
	}
	byOwner[0].Labels["source"] = "by-owner-mutation"
	byOwnerAgain := registry.ByOwnerName("owner")
	if byOwnerAgain[0].Labels["source"] != "original" {
		t.Fatal("ByOwnerName did not return defensive copies")
	}

	now = start.Add(15*time.Second + time.Nanosecond)
	if _, ok := registry.ByKey("cluster-a", "tenant-a", "shared"); ok {
		t.Fatal("ByKey returned an expired workload")
	}
	if got := registry.ByPodName("shared"); len(got) != 0 {
		t.Fatalf("ByPodName returned %d expired workloads", len(got))
	}
	if got := registry.ByOwnerName("owner"); len(got) != 0 {
		t.Fatalf("ByOwnerName returned %d expired workloads", len(got))
	}
}
