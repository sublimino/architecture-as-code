// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// SLCD-P5-GOV end-to-end harness server.
//
// This file exists so the Phase 5 Governor can prove the ingestion-to-render
// path END TO END against the REAL merged pipeline rather than a mock. It
// starts the REAL ProtectedRouter -- the same router, the same authorize()
// path, the same handlers and the same codingagent store that production
// wires up in main.go -- on a REAL TCP listener, so the dashboard's REAL
// api/client.ts can speak to it over REAL HTTP.
//
// Why this lives in a _test.go file and not in cmd/:
//
//	The harness authenticates by a static bearer-token -> Principal map. That
//	is an authentication bypass by construction, and it must therefore be
//	structurally incapable of shipping. A _test.go file is excluded from
//	`go build`, from the Dockerfile, and from every production binary by the
//	Go toolchain itself -- not by a flag anyone can forget to pass. A cmd/
//	binary behind a build tag would rely on the tag being remembered; this
//	relies on nothing.
//
// The server is inert unless SLCD_E2E_HARNESS_ADDR is set, so `go test ./...`
// skips it and the required test command is unaffected.
package api

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
)

// e2eTokenAuthenticator resolves a Principal from the bearer token alone.
//
// Modelling identity on the CREDENTIAL rather than on a request header is the
// point: it is what lets the hostile-tenant assertion mean something. A client
// that forges X-Tenant-ID gets no say in which Principal is returned here,
// exactly as a real JWT-SVID would give it no say.
type e2eTokenAuthenticator struct {
	principals map[string]Principal
}

func (a e2eTokenAuthenticator) Authenticate(r *http.Request) (Principal, error) {
	tok := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	p, ok := a.principals[tok]
	if !ok {
		return Principal{}, ErrMissingCredential
	}
	return p, nil
}

func e2ePrincipal(subject, tenant string) Principal {
	return Principal{
		Subject:   subject,
		TenantID:  tenant,
		ExpiresAt: time.Now().Add(time.Hour),
		Permissions: map[Permission]bool{
			PermissionObservationWrite: true,
			PermissionObservationRead:  true,
		},
	}
}

// TestSLCDE2EHarnessServer is a server, not an assertion. It is skipped unless
// SLCD_E2E_HARNESS_ADDR is set, which keeps `go test ./...` green and fast.
//
// Protocol with the caller:
//   - SLCD_E2E_HARNESS_ADDR       -- host:port to bind (required to run at all)
//   - SLCD_E2E_HARNESS_READY_FILE -- readiness is signalled by CREATING this
//     file after the listener is accepting. The caller polls for it rather
//     than sleeping, so there is no race and no arbitrary delay.
//   - stdin EOF                   -- shuts the server down cleanly.
func TestSLCDE2EHarnessServer(t *testing.T) {
	addr := os.Getenv("SLCD_E2E_HARNESS_ADDR")
	if addr == "" {
		t.Skip("SLCD_E2E_HARNESS_ADDR unset -- e2e harness server not requested")
	}

	h, _ := newTestHandlers(t)
	h.CodingAgentStore = codingagent.NewMemoryStore()

	authn := e2eTokenAuthenticator{principals: map[string]Principal{
		"e2e-token-tenant-alpha": e2ePrincipal("spiffe://cluster.local/ns/prod/sa/sensor-alpha", "tenant-alpha"),
		"e2e-token-tenant-beta":  e2ePrincipal("spiffe://cluster.local/ns/prod/sa/sensor-beta", "tenant-beta"),
	}}

	// The per-principal request budget is real production behaviour, but it is
	// not what this harness certifies, and the renderer trips it as an
	// artefact of the test rather than of the pipeline: every mounted
	// CodingAgentsTab polls on a 2.5s interval, and a latency run mounts it
	// many times. Raising the ceiling keeps the budget in the path (a bug that
	// broke it would still surface) while stopping a test-harness poll storm
	// from being reported as an ingestion failure.
	router, err := NewProtectedRouter(h, authn, h.Audit, http.NotFoundHandler(), RouterOptions{
		PrincipalBudget: 1_000_000,
		BudgetWindow:    time.Minute,
	})
	if err != nil {
		t.Fatalf("failed to build the real ProtectedRouter: %v", err)
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("failed to bind %s: %v", addr, err)
	}
	defer func() { _ = ln.Close() }()

	// CORS is a jsdom/browser-origin concern only. The dashboard in production
	// is same-origin with /api via nginx, so this wrapper exists purely so the
	// test renderer's XHR is not blocked before it reaches the real router.
	// It adds no authorization behaviour and sits OUTSIDE the router, so every
	// authenticated request still traverses authorize() unchanged.
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Tenant-ID, X-SignalLoom-Tenant, X-Tenant")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		router.ServeHTTP(w, r)
	})

	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = srv.Serve(ln) }()

	if rf := os.Getenv("SLCD_E2E_HARNESS_READY_FILE"); rf != "" {
		payload, _ := json.Marshal(map[string]string{"addr": ln.Addr().String()})
		if err := os.WriteFile(rf, payload, 0o600); err != nil {
			t.Fatalf("failed to write readiness file %s: %v", rf, err)
		}
	}
	fmt.Fprintf(os.Stderr, "SLCD_E2E_HARNESS_READY %s\n", ln.Addr().String())

	// Block until the caller creates the stop file, with a hard ceiling so a
	// crashed caller can never leave this process resident.
	//
	// Deliberately NOT stdin EOF: a caller that redirects stdin from /dev/null
	// (every shell background job does) would signal EOF instantly and the
	// server would exit before serving a single request, while still having
	// written its readiness file. That failure reads as "connection refused
	// against a server that reported ready", which is a confusing way to
	// spend an afternoon. A stop file has the same meaning under every
	// stdin arrangement.
	stopFile := os.Getenv("SLCD_E2E_HARNESS_STOP_FILE")
	deadline := time.Now().Add(5 * time.Minute)
	for time.Now().Before(deadline) {
		if stopFile != "" {
			if _, err := os.Stat(stopFile); err == nil {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Log("e2e harness server hit its 5 minute ceiling and is shutting down")
}
