// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// SLDC-P1-3: the exclusion gate on the real HTTP surface. Each refusal must
// leave cgroup.freeze untouched and emit no halt telemetry — a refused stun
// that still froze would be worse than no guard at all.

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/filter"
)

func freezeValue(t *testing.T, root string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, "kubepods.slice", "kubepods-besteffort.slice",
		"kubepods-besteffort-pod"+uidUnderscored+".slice", "cgroup.freeze"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func withFilter(srv *server, self filter.Self, audit *[]string) {
	srv.exclusion = filter.New(self, filter.WithAuditLog(func(l string) { *audit = append(*audit, l) }))
}

func TestSelfPodExclusionHTTPRefusesInfrastructureNamespace(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, false)
	srv, telem := newTestServer(t, root, "freeze-token", "resume-token")
	var audit []string
	withFilter(srv, filter.Self{}, &audit)

	for _, ns := range filter.DefaultExcludedNamespaces {
		rec := postJSON(t, srv.routes(), "/stun",
			`{"pod_uid":"`+uid+`","pod":"coredns-x","namespace":"`+ns+`"}`, authHeader("freeze-token"))
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s: status = %d, want 403: %s", ns, rec.Code, rec.Body)
		}
		if !strings.Contains(rec.Body.String(), `"skipped":true`) {
			t.Errorf("%s: refusal body lacks skipped marker: %s", ns, rec.Body)
		}
	}
	if got := freezeValue(t, root); got != "0" {
		t.Fatalf("cgroup.freeze = %s after refused stuns, want 0", got)
	}
	if strings.TrimSpace(telem.String()) != "" {
		t.Errorf("refused stun emitted halt telemetry: %q", telem.String())
	}
	if len(audit) != len(filter.DefaultExcludedNamespaces) || !strings.Contains(audit[0], "reason=infrastructure-namespace") {
		t.Errorf("audit lines = %v", audit)
	}
}

func TestSelfPodExclusionHTTPRefusesSelf(t *testing.T) {
	cases := map[string]filter.Self{
		"own pod uid": {PodUID: uid},
		// The fixture cgroup.procs holds 4242: pretend that is our host PID.
		"own pid inside target cgroup": {PID: 4242},
		"own cgroup beneath target": {CgroupPath: "/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod" +
			uidUnderscored + ".slice/cri-containerd-self.scope"},
	}
	for name, self := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			mockPodCgroup(t, root, false)
			srv, _ := newTestServer(t, root, "freeze-token", "resume-token")
			var audit []string
			withFilter(srv, self, &audit)

			rec := postJSON(t, srv.routes(), "/stun",
				`{"pod_uid":"`+uid+`","pod":"stun-sentinel-abc","namespace":"fe-signalloom-agents"}`, authHeader("freeze-token"))
			if rec.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403: %s", rec.Code, rec.Body)
			}
			if got := freezeValue(t, root); got != "0" {
				t.Fatalf("sentinel froze itself: cgroup.freeze = %s", got)
			}
			if len(audit) != 1 || !strings.Contains(audit[0], "audit: stun-sentinel skip") {
				t.Errorf("no audit skip line: %v", audit)
			}
		})
	}
}

func TestSelfPodExclusionHTTPPhaseGate(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, false)
	srv, _ := newTestServer(t, root, "freeze-token", "resume-token")
	var audit []string
	withFilter(srv, filter.Self{}, &audit)

	rec := postJSON(t, srv.routes(), "/stun",
		`{"pod_uid":"`+uid+`","pod":"agent","namespace":"tenant-demo","phase":"Pending"}`, authHeader("freeze-token"))
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 for a Pending pod: %s", rec.Code, rec.Body)
	}
	if got := freezeValue(t, root); got != "0" {
		t.Fatalf("Pending pod was frozen: cgroup.freeze = %s", got)
	}
}

func TestSelfPodExclusionHTTPAllowsAgent(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, false)
	srv, _ := newTestServer(t, root, "freeze-token", "resume-token")
	var audit []string
	withFilter(srv, filter.Self{PID: 1, PodUID: "someone-else"}, &audit)

	// The gate must not block a legitimate target. The fixture never reports
	// frozen, so the freezer itself times out (504) — past the gate is the
	// assertion here, not a successful freeze.
	rec := postJSON(t, srv.routes(), "/stun",
		`{"pod_uid":"`+uid+`","pod":"agent","namespace":"tenant-demo","phase":"Running"}`, authHeader("freeze-token"))
	if rec.Code == http.StatusForbidden || rec.Code == http.StatusConflict {
		t.Fatalf("agent pod refused by exclusion gate: %d %s", rec.Code, rec.Body)
	}
	if got := freezeValue(t, root); got != "1" {
		t.Fatalf("freezer never reached: cgroup.freeze = %s, want 1", got)
	}
	if len(audit) != 0 {
		t.Errorf("agent pod produced audit skip lines: %v", audit)
	}
}
