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

	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		req := httptest.NewRequest("GET", path, nil)
		rec := httptest.NewRecorder()
		srv.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("path %s expected status 200, got %d", path, rec.Code)
		}

		var body map[string]string
		if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
			t.Fatalf("path %s decode response: %v", path, err)
		}
		if body["status"] != "healthy" {
			t.Fatalf("path %s expected healthy, got %s", path, body["status"])
		}

		headReq := httptest.NewRequest("HEAD", path, nil)
		headRec := httptest.NewRecorder()
		srv.ServeHTTP(headRec, headReq)
		if headRec.Code != http.StatusOK {
			t.Fatalf("HEAD path %s expected status 200, got %d", path, headRec.Code)
		}
		if headRec.Body.Len() != 0 {
			t.Fatalf("HEAD path %s expected empty body, got %d bytes", path, headRec.Body.Len())
		}
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

	// Test HEAD on workspace ID
	headReq := httptest.NewRequest("HEAD", "/workspaces/"+created.WorkspaceID, nil)
	headReq.Header.Set("X-Tenant-ID", "tenant-1")
	headRec := httptest.NewRecorder()
	srv.ServeHTTP(headRec, headReq)
	if headRec.Code != http.StatusOK {
		t.Fatalf("HEAD /workspaces/{id} expected 200, got %d", headRec.Code)
	}
	if headRec.Body.Len() != 0 {
		t.Fatalf("HEAD /workspaces/{id} expected empty body, got %d bytes", headRec.Body.Len())
	}

	// Test HEAD on /workspaces list
	headListReq := httptest.NewRequest("HEAD", "/workspaces", nil)
	headListReq.Header.Set("X-Tenant-ID", "tenant-1")
	headListRec := httptest.NewRecorder()
	srv.ServeHTTP(headListRec, headListReq)
	if headListRec.Code != http.StatusOK {
		t.Fatalf("HEAD /workspaces expected 200, got %d", headListRec.Code)
	}
	if headListRec.Body.Len() != 0 {
		t.Fatalf("HEAD /workspaces expected empty body, got %d bytes", headListRec.Body.Len())
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

func TestValidateBranch(t *testing.T) {
	validBranches := []string{
		"",
		"main",
		"feat/auth-validation",
		"bugfix_123",
		"v1.0.0",
		"release-2026.01",
	}
	for _, b := range validBranches {
		if err := validateBranch(b); err != nil {
			t.Errorf("expected branch %q to be valid, got: %v", b, err)
		}
	}

	invalidBranches := []string{
		"-u",
		"--upload-pack=exploit",
		"../escape",
		"branch/../traversal",
		"feature@{1}",
		"branch//double-slash",
		"trailing-slash/",
		"branch.lock",
		"branch with spaces",
		"branch;rm -rf",
		"feat.",
		"feat/.hidden",
		"feat/sub/.",
		"feat.lock/branch",
		"HEAD",
		strings.Repeat("a", 256),
	}
	for _, b := range invalidBranches {
		if err := validateBranch(b); err == nil {
			t.Errorf("expected branch %q to be rejected, got nil", b)
		}
	}
}

func TestWorkspaceCreationInvalidBranch(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	wsReq := WorkspaceRequest{
		PVC:    "valid-pvc",
		User:   "alice",
		Branch: "--upload-pack=evil",
	}
	raw, _ := json.Marshal(wsReq)

	req := httptest.NewRequest("POST", "/workspaces", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestHeadErrorBodySuppression(t *testing.T) {
	mgr := NewWorkspaceManager("test-ns")
	srv := newServer(mgr)

	// 1. HEAD /workspaces/nonexistent-id should return 404 with 0 body bytes and application/json Content-Type
	req404 := httptest.NewRequest("HEAD", "/workspaces/nonexistent-id", nil)
	rec404 := httptest.NewRecorder()
	srv.ServeHTTP(rec404, req404)
	if rec404.Code != http.StatusNotFound {
		t.Fatalf("expected 404 Not Found, got %d", rec404.Code)
	}
	if rec404.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on HEAD 404, got %d: %q", rec404.Body.Len(), rec404.Body.String())
	}
	if ct := rec404.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("expected Content-Type application/json, got %q", ct)
	}

	// 2. HEAD /workspaces (list) should return 200 with 0 body bytes
	reqList := httptest.NewRequest("HEAD", "/workspaces", nil)
	recList := httptest.NewRecorder()
	srv.ServeHTTP(recList, reqList)
	if recList.Code != http.StatusOK {
		t.Fatalf("expected 200 OK on HEAD /workspaces, got %d", recList.Code)
	}
	if recList.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on HEAD 200, got %d: %q", recList.Body.Len(), recList.Body.String())
	}

	// 3. HEAD to an unknown route should return 404 with 0 body bytes
	reqUnknown := httptest.NewRequest("HEAD", "/unknown-route-999", nil)
	recUnknown := httptest.NewRecorder()
	srv.ServeHTTP(recUnknown, reqUnknown)
	if recUnknown.Code != http.StatusNotFound {
		t.Fatalf("expected 404 Not Found, got %d", recUnknown.Code)
	}
	if recUnknown.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on HEAD 404 unknown route, got %d: %q", recUnknown.Body.Len(), recUnknown.Body.String())
	}
}


