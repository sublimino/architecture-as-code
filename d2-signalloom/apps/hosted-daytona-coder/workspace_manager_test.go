package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHealth(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	req := httptest.NewRequest("GET", "/health", nil)
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["status"] != "healthy" {
		t.Fatalf("expected healthy, got %s", body["status"])
	}
}

func TestWorkspaceCreationAndRetrieval(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	wsReq := WorkspaceRequest{
		PVC:    "my-test-pvc",
		User:   "alice",
		Branch: "main",
	}
	raw, _ := json.Marshal(wsReq)

	req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Tenant-ID", "tenant-1")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 Created, got %d: %s", rec.Code, rec.Body.String())
	}

	var created WorkspaceResponse
	if err := json.NewDecoder(rec.Body).Decode(&created); err != nil {
		t.Fatalf("decode created workspace: %v", err)
	}
	if created.WorkspaceID == "" {
		t.Fatal("expected non-empty workspace_id")
	}
	if created.TenantID != "tenant-1" {
		t.Fatalf("expected tenant_id tenant-1, got %s", created.TenantID)
	}

	// Retrieve by ID
	getReq := httptest.NewRequest("GET", "/workspaces/"+created.WorkspaceID, nil)
	getReq.Header.Set("X-Tenant-ID", "tenant-1")
	getRec := httptest.NewRecorder()
	srv.ServeHTTP(getRec, getReq)

	if getRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d: %s", getRec.Code, getRec.Body.String())
	}

	var fetched WorkspaceResponse
	if err := json.NewDecoder(getRec.Body).Decode(&fetched); err != nil {
		t.Fatalf("decode fetched workspace: %v", err)
	}
	if fetched.WorkspaceID != created.WorkspaceID {
		t.Fatalf("expected workspace ID %s, got %s", created.WorkspaceID, fetched.WorkspaceID)
	}
}

func TestTenantIsolation(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	// Create workspace in tenant-alpha
	bodyA, _ := json.Marshal(WorkspaceRequest{PVC: "pvc-alpha", User: "alice"})
	reqA := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(bodyA))
	reqA.Header.Set("Content-Type", "application/json")
	reqA.Header.Set("X-Tenant-ID", "tenant-alpha")
	recA := httptest.NewRecorder()
	srv.ServeHTTP(recA, reqA)
	if recA.Code != http.StatusCreated {
		t.Fatalf("failed to create ws A: %s", recA.Body.String())
	}
	var wsA WorkspaceResponse
	_ = json.NewDecoder(recA.Body).Decode(&wsA)

	// Create workspace in tenant-beta
	bodyB, _ := json.Marshal(WorkspaceRequest{PVC: "pvc-beta", User: "bob"})
	reqB := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(bodyB))
	reqB.Header.Set("Content-Type", "application/json")
	reqB.Header.Set("X-Tenant-ID", "tenant-beta")
	recB := httptest.NewRecorder()
	srv.ServeHTTP(recB, reqB)
	if recB.Code != http.StatusCreated {
		t.Fatalf("failed to create ws B: %s", recB.Body.String())
	}
	var wsB WorkspaceResponse
	_ = json.NewDecoder(recB.Body).Decode(&wsB)

	// 1. List for tenant-alpha should only see wsA
	listReqA := httptest.NewRequest("GET", "/workspaces", nil)
	listReqA.Header.Set("X-Tenant-ID", "tenant-alpha")
	listRecA := httptest.NewRecorder()
	srv.ServeHTTP(listRecA, listReqA)
	if listRecA.Code != http.StatusOK {
		t.Fatalf("list tenant-alpha failed: %d", listRecA.Code)
	}
	var listA []*WorkspaceResponse
	_ = json.NewDecoder(listRecA.Body).Decode(&listA)
	if len(listA) != 1 || listA[0].WorkspaceID != wsA.WorkspaceID {
		t.Fatalf("expected 1 workspace for tenant-alpha, got %d", len(listA))
	}

	// 2. Tenant-beta accessing wsA should get 404
	getOtherReq := httptest.NewRequest("GET", "/workspaces/"+wsA.WorkspaceID, nil)
	getOtherReq.Header.Set("X-Tenant-ID", "tenant-beta")
	getOtherRec := httptest.NewRecorder()
	srv.ServeHTTP(getOtherRec, getOtherReq)
	if getOtherRec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 when tenant-beta accesses wsA, got %d", getOtherRec.Code)
	}

	// 3. Tenant-beta deleting wsA should get 403 Forbidden
	delOtherReq := httptest.NewRequest("DELETE", "/workspaces/"+wsA.WorkspaceID, nil)
	delOtherReq.Header.Set("X-Tenant-ID", "tenant-beta")
	delOtherRec := httptest.NewRecorder()
	srv.ServeHTTP(delOtherRec, delOtherReq)
	if delOtherRec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 when tenant-beta deletes wsA, got %d", delOtherRec.Code)
	}

	// 4. Tenant-alpha deleting wsA should succeed with 204
	delOwnReq := httptest.NewRequest("DELETE", "/workspaces/"+wsA.WorkspaceID, nil)
	delOwnReq.Header.Set("X-Tenant-ID", "tenant-alpha")
	delOwnRec := httptest.NewRecorder()
	srv.ServeHTTP(delOwnRec, delOwnReq)
	if delOwnRec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 when tenant-alpha deletes wsA, got %d", delOwnRec.Code)
	}
}

func TestCrossTenantConflictRejection(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	// Body tenant conflicts with header tenant
	body, _ := json.Marshal(WorkspaceRequest{PVC: "valid-pvc", User: "alice", TenantID: "tenant-other"})
	req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Tenant-ID", "tenant-auth")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden on body tenant mismatch, got %d: %s", rec.Code, rec.Body.String())
	}

	// Query tenant conflicts with header tenant
	reqQuery := httptest.NewRequest("GET", "/workspaces?tenant=tenant-query", nil)
	reqQuery.Header.Set("X-Tenant-ID", "tenant-header")
	recQuery := httptest.NewRecorder()
	srv.ServeHTTP(recQuery, reqQuery)

	if recQuery.Code != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden on query/header tenant mismatch, got %d: %s", recQuery.Code, recQuery.Body.String())
	}
}

func TestInputValidation(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	cases := []struct {
		name string
		req  WorkspaceRequest
	}{
		{"empty pvc", WorkspaceRequest{PVC: "", User: "alice"}},
		{"path traversal pvc", WorkspaceRequest{PVC: "../../etc/shadow", User: "alice"}},
		{"invalid char pvc", WorkspaceRequest{PVC: "invalid_pvc!", User: "alice"}},
		{"empty user", WorkspaceRequest{PVC: "valid-pvc", User: ""}},
		{"path traversal user", WorkspaceRequest{PVC: "valid-pvc", User: "../root"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw, _ := json.Marshal(tc.req)
			req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(raw))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			srv.ServeHTTP(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected 400 Bad Request for %s, got %d: %s", tc.name, rec.Code, rec.Body.String())
			}
		})
	}
}

func TestPayloadLimit(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	// Generate payload larger than 64KB
	hugeBranch := strings.Repeat("a", 70000)
	raw, _ := json.Marshal(WorkspaceRequest{PVC: "valid-pvc", User: "alice", Branch: hugeBranch})

	req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request for oversized payload, got %d", rec.Code)
	}
}

func TestTenantIDWhitespaceNormalization(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	body, _ := json.Marshal(WorkspaceRequest{
		PVC:      "valid-pvc",
		User:     "alice",
		TenantID: "  tenant-auth  \n",
	})
	req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Tenant-ID", "tenant-auth")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 Created with whitespace-padded tenant, got %d: %s", rec.Code, rec.Body.String())
	}
	var created WorkspaceResponse
	if err := json.NewDecoder(rec.Body).Decode(&created); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if created.TenantID != "tenant-auth" {
		t.Fatalf("expected tenant-auth, got %q", created.TenantID)
	}
}

func TestWorkspaceCloningIsolation(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	ws, err := mgr.Create(WorkspaceRequest{PVC: "valid-pvc", User: "alice", TenantID: "tenant-1"})
	if err != nil {
		t.Fatalf("failed to create: %v", err)
	}

	// Mutate returned copy
	ws.Status = "tampered"
	ws.PodName = "evil-pod"

	// Fetch fresh copy via Get
	fetched, ok := mgr.Get(ws.WorkspaceID, "tenant-1")
	if !ok {
		t.Fatalf("workspace not found")
	}
	if fetched.Status == "tampered" || fetched.PodName == "evil-pod" {
		t.Fatalf("mutation leaked into internal state: status=%q, pod=%q", fetched.Status, fetched.PodName)
	}

	// List check
	list := mgr.List("tenant-1")
	if len(list) != 1 || list[0].Status == "tampered" {
		t.Fatalf("mutation leaked into list")
	}
}

func TestPruneExpiredWorkspaces(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	ws, err := mgr.Create(WorkspaceRequest{PVC: "valid-pvc", User: "alice", TenantID: "tenant-1"})
	if err != nil {
		t.Fatalf("failed to create: %v", err)
	}

	// Manually age the workspace in manager map
	mgr.mu.Lock()
	mgr.workspaces[ws.WorkspaceID].CreatedAt = time.Now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	mgr.mu.Unlock()

	// Create fresh workspace
	freshWs, err := mgr.Create(WorkspaceRequest{PVC: "valid-pvc-2", User: "bob", TenantID: "tenant-1"})
	if err != nil {
		t.Fatalf("failed to create fresh: %v", err)
	}

	pruned := mgr.PruneExpired(1 * time.Hour)
	if pruned != 1 {
		t.Fatalf("expected 1 pruned, got %d", pruned)
	}

	if _, ok := mgr.Get(ws.WorkspaceID, "tenant-1"); ok {
		t.Fatalf("expired workspace was not pruned")
	}
	if _, ok := mgr.Get(freshWs.WorkspaceID, "tenant-1"); !ok {
		t.Fatalf("fresh workspace was erroneously pruned")
	}
}

func TestWorkspaceCapacityLimit(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	for i := 0; i < maxWorkspaces; i++ {
		_, err := mgr.Create(WorkspaceRequest{PVC: fmt.Sprintf("pvc-%d", i), User: "user", TenantID: "tenant-1"})
		if err != nil {
			t.Fatalf("unexpected error at %d: %v", i, err)
		}
	}

	// 501st creation should fail
	_, err := mgr.Create(WorkspaceRequest{PVC: "pvc-overflow", User: "user", TenantID: "tenant-1"})
	if err == nil {
		t.Fatalf("expected capacity exceeded error, got nil")
	}
}
