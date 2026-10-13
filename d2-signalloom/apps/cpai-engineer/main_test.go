package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newTestServer creates an offline, isolated cpai-engineer server backed by a temp
// workspace and SQLite session store. Returns the httptest.Server and teardown is handled via t.Cleanup.
func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()

	tmpDir := t.TempDir()
	workspaceDir := filepath.Join(tmpDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatalf("mkdir workspace: %v", err)
	}

	dbPath := filepath.Join(tmpDir, "sessions.db")
	store, err := NewSessionStore(dbPath)
	if err != nil {
		t.Fatalf("new session store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(workspaceDir, nono, store)
	handler := newServer(executor, store)

	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return ts
}

func TestHealthProbes_MethodsAndHeadBodySuppression(t *testing.T) {
	ts := newTestServer(t)

	endpoints := []string{"/health", "/healthz", "/readyz"}
	for _, ep := range endpoints {
		// 1. GET returns 200 OK and JSON body
		getResp, err := http.Get(ts.URL + ep)
		if err != nil {
			t.Fatalf("GET %s failed: %v", ep, err)
		}
		getBody, _ := io.ReadAll(getResp.Body)
		getResp.Body.Close()

		if getResp.StatusCode != http.StatusOK {
			t.Errorf("GET %s expected 200, got %d", ep, getResp.StatusCode)
		}
		if ct := getResp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
			t.Errorf("GET %s expected Content-Type application/json, got %q", ep, ct)
		}
		var healthData map[string]string
		if err := json.Unmarshal(getBody, &healthData); err != nil {
			t.Errorf("GET %s unmarshal body: %v", ep, err)
		}
		if healthData["status"] != "healthy" {
			t.Errorf("GET %s expected status=healthy, got %q", ep, healthData["status"])
		}

		// 2. HEAD returns 200 OK, Content-Type application/json, and exactly 0 body bytes (RFC 9110 Section 6.4.1)
		headReq, _ := http.NewRequest(http.MethodHead, ts.URL+ep, nil)
		headResp, err := http.DefaultClient.Do(headReq)
		if err != nil {
			t.Fatalf("HEAD %s failed: %v", ep, err)
		}
		headBody, _ := io.ReadAll(headResp.Body)
		headResp.Body.Close()

		if headResp.StatusCode != http.StatusOK {
			t.Errorf("HEAD %s expected 200, got %d", ep, headResp.StatusCode)
		}
		if ct := headResp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
			t.Errorf("HEAD %s expected Content-Type application/json, got %q", ep, ct)
		}
		if len(headBody) != 0 {
			t.Errorf("HEAD %s expected 0 body bytes, got %d bytes: %s", ep, len(headBody), string(headBody))
		}

		// 3. Mutating methods (POST, PUT, DELETE, PATCH) return 405 Method Not Allowed with Allow: GET, HEAD
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req, _ := http.NewRequest(method, ts.URL+ep, strings.NewReader(`{}`))
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("%s %s failed: %v", method, ep, err)
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()

			if resp.StatusCode != http.StatusMethodNotAllowed {
				t.Errorf("%s %s expected 405, got %d", method, ep, resp.StatusCode)
			}
			allow := resp.Header.Get("Allow")
			if !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
				t.Errorf("%s %s expected Allow to contain GET, HEAD, got %q", method, ep, allow)
			}
			if len(body) == 0 {
				t.Errorf("%s %s expected non-empty error body", method, ep)
			}
		}
	}
}

func TestTasksSubmission_ValidationAndGates(t *testing.T) {
	ts := newTestServer(t)

	// 1. Valid task creation
	validPayload := TaskRequest{
		Repo:        "https://github.com/example/repo.git",
		Branch:      "main",
		Instruction: "Implement security hardening",
		TokenBudget: 25000,
	}
	body, _ := json.Marshal(validPayload)
	resp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /tasks failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("POST /tasks expected 202, got %d", resp.StatusCode)
	}
	var created TaskResponse
	if err := json.NewDecoder(resp.Body).Decode(&created); err != nil {
		t.Fatalf("decode created task: %v", err)
	}
	if created.TaskID == "" {
		t.Fatal("expected non-empty task_id")
	}
	if created.Status != "pending" {
		t.Errorf("expected status=pending, got %q", created.Status)
	}

	// 2. Input validation: empty body
	respEmpty, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(nil))
	if err != nil {
		t.Fatalf("POST /tasks empty failed: %v", err)
	}
	defer respEmpty.Body.Close()
	if respEmpty.StatusCode != http.StatusBadRequest {
		t.Errorf("POST /tasks empty expected 400, got %d", respEmpty.StatusCode)
	}

	// 3. Input validation: missing repo or instruction
	invalidCases := []struct {
		name    string
		payload TaskRequest
		errMsg  string
	}{
		{
			name:    "missing repo",
			payload: TaskRequest{Branch: "main", Instruction: "Fix bug"},
			errMsg:  "repo and instruction are required",
		},
		{
			name:    "missing instruction",
			payload: TaskRequest{Repo: "https://github.com/example/repo.git", Branch: "main"},
			errMsg:  "repo and instruction are required",
		},
		{
			name:    "flag injection in repo",
			payload: TaskRequest{Repo: "--upload-pack=evil.sh", Instruction: "Fix bug"},
			errMsg:  "repo cannot start with a dash",
		},
		{
			name:    "flag injection in branch",
			payload: TaskRequest{Repo: "https://github.com/example/repo.git", Branch: "--output=evil", Instruction: "Fix bug"},
			errMsg:  "branch cannot start with a dash",
		},
		{
			name:    "path traversal in branch",
			payload: TaskRequest{Repo: "https://github.com/example/repo.git", Branch: "../../../root", Instruction: "Fix bug"},
			errMsg:  "branch cannot contain path traversal or reflog syntax",
		},
		{
			name:    "reflog injection in branch",
			payload: TaskRequest{Repo: "https://github.com/example/repo.git", Branch: "main@{1}", Instruction: "Fix bug"},
			errMsg:  "branch cannot contain path traversal or reflog syntax",
		},
		{
			name:    "double slashes in branch",
			payload: TaskRequest{Repo: "https://github.com/example/repo.git", Branch: "feature//branch", Instruction: "Fix bug"},
			errMsg:  "branch cannot contain path traversal or reflog syntax",
		},
	}

	for _, tc := range invalidCases {
		t.Run(tc.name, func(t *testing.T) {
			raw, _ := json.Marshal(tc.payload)
			r, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(raw))
			if err != nil {
				t.Fatalf("POST /tasks (%s) failed: %v", tc.name, err)
			}
			defer r.Body.Close()

			if r.StatusCode != http.StatusBadRequest {
				t.Errorf("(%s) expected 400, got %d", tc.name, r.StatusCode)
			}
			var errResp ErrorResponse
			_ = json.NewDecoder(r.Body).Decode(&errResp)
			if !strings.Contains(errResp.Error, tc.errMsg) {
				t.Errorf("(%s) expected error message %q, got %q", tc.name, tc.errMsg, errResp.Error)
			}
		})
	}

	// 4. Listing tasks: GET /tasks
	listResp, err := http.Get(ts.URL + "/tasks")
	if err != nil {
		t.Fatalf("GET /tasks failed: %v", err)
	}
	defer listResp.Body.Close()
	if listResp.StatusCode != http.StatusOK {
		t.Errorf("GET /tasks expected 200, got %d", listResp.StatusCode)
	}
	var tasks []*TaskResponse
	if err := json.NewDecoder(listResp.Body).Decode(&tasks); err != nil {
		t.Fatalf("decode tasks list: %v", err)
	}
	if len(tasks) < 1 {
		t.Errorf("expected at least 1 task in list, got %d", len(tasks))
	}

	// 5. Listing tasks: HEAD /tasks
	headReq, _ := http.NewRequest(http.MethodHead, ts.URL+"/tasks", nil)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD /tasks failed: %v", err)
	}
	headBody, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD /tasks expected 200, got %d", headResp.StatusCode)
	}
	if len(headBody) != 0 {
		t.Errorf("HEAD /tasks expected 0 body bytes, got %d bytes: %s", len(headBody), string(headBody))
	}

	// 6. Mutating method gates on /tasks: PUT, DELETE, PATCH -> 405 Method Not Allowed
	for _, method := range []string{http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, _ := http.NewRequest(method, ts.URL+"/tasks", strings.NewReader(`{}`))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s /tasks failed: %v", method, err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s /tasks expected 405, got %d", method, resp.StatusCode)
		}
		allow := resp.Header.Get("Allow")
		if !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") || !strings.Contains(allow, "POST") {
			t.Errorf("%s /tasks expected Allow header to contain GET, HEAD, POST, got %q", method, allow)
		}
	}
}

func TestTasksDetail_MethodsAndHeadParity(t *testing.T) {
	ts := newTestServer(t)

	// Create task
	payload := TaskRequest{
		Repo:        "https://github.com/example/repo.git",
		Branch:      "main",
		Instruction: "Task detail test",
	}
	raw, _ := json.Marshal(payload)
	createResp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("create task: %v", err)
	}
	var created TaskResponse
	_ = json.NewDecoder(createResp.Body).Decode(&created)
	createResp.Body.Close()

	taskPath := "/tasks/" + created.TaskID

	// 1. GET /tasks/{id} returns 200 OK
	getResp, err := http.Get(ts.URL + taskPath)
	if err != nil {
		t.Fatalf("GET %s failed: %v", taskPath, err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s expected 200, got %d", taskPath, getResp.StatusCode)
	}
	var fetched TaskResponse
	if err := json.NewDecoder(getResp.Body).Decode(&fetched); err != nil {
		t.Fatalf("decode fetched task: %v", err)
	}
	if fetched.TaskID != created.TaskID {
		t.Errorf("expected task_id %q, got %q", created.TaskID, fetched.TaskID)
	}

	// 2. HEAD /tasks/{id} returns 200 OK and exactly 0 body bytes (RFC 9110 Section 6.4.1)
	headReq, _ := http.NewRequest(http.MethodHead, ts.URL+taskPath, nil)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD %s failed: %v", taskPath, err)
	}
	headBody, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD %s expected 200, got %d", taskPath, headResp.StatusCode)
	}
	if len(headBody) != 0 {
		t.Errorf("HEAD %s expected 0 body bytes, got %d bytes: %s", taskPath, len(headBody), string(headBody))
	}
	if ct := headResp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("HEAD %s expected Content-Type application/json, got %q", taskPath, ct)
	}

	// 3. Nonexistent task: GET /tasks/nonexistent -> 404 with error body
	get404Resp, err := http.Get(ts.URL + "/tasks/nonexistent-id-404")
	if err != nil {
		t.Fatalf("GET nonexistent task failed: %v", err)
	}
	get404Body, _ := io.ReadAll(get404Resp.Body)
	get404Resp.Body.Close()
	if get404Resp.StatusCode != http.StatusNotFound {
		t.Errorf("GET nonexistent task expected 404, got %d", get404Resp.StatusCode)
	}
	if len(get404Body) == 0 {
		t.Error("GET nonexistent task expected non-empty error body")
	}

	// 4. Nonexistent task: HEAD /tasks/nonexistent -> 404 with exactly 0 body bytes (RFC 9110 Section 6.4.1)
	head404Req, _ := http.NewRequest(http.MethodHead, ts.URL+"/tasks/nonexistent-id-404", nil)
	head404Resp, err := http.DefaultClient.Do(head404Req)
	if err != nil {
		t.Fatalf("HEAD nonexistent task failed: %v", err)
	}
	head404Body, _ := io.ReadAll(head404Resp.Body)
	head404Resp.Body.Close()
	if head404Resp.StatusCode != http.StatusNotFound {
		t.Errorf("HEAD nonexistent task expected 404, got %d", head404Resp.StatusCode)
	}
	if len(head404Body) != 0 {
		t.Errorf("HEAD nonexistent task expected 0 body bytes, got %d bytes: %s", len(head404Body), string(head404Body))
	}
	if ct := head404Resp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Errorf("HEAD nonexistent task expected Content-Type application/json, got %q", ct)
	}

	// 5. Mutating method gates on /tasks/{id}: POST, PUT, DELETE, PATCH -> 405 Method Not Allowed with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, _ := http.NewRequest(method, ts.URL+taskPath, strings.NewReader(`{}`))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s %s failed: %v", method, taskPath, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s %s expected 405, got %d", method, taskPath, resp.StatusCode)
		}
		allow := resp.Header.Get("Allow")
		if !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
			t.Errorf("%s %s expected Allow to contain GET, HEAD, got %q", method, taskPath, allow)
		}
		if len(body) == 0 {
			t.Errorf("%s %s expected non-empty error body", method, taskPath)
		}
	}
}

func TestAgentCard_MethodsAndHeadParity(t *testing.T) {
	ts := newTestServer(t)

	cardPath := "/.well-known/agent-card.json"

	// GET and HEAD status parity
	getResp, err := http.Get(ts.URL + cardPath)
	if err != nil {
		t.Fatalf("GET %s: %v", cardPath, err)
	}
	getResp.Body.Close()

	headReq, _ := http.NewRequest(http.MethodHead, ts.URL+cardPath, nil)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD %s: %v", cardPath, err)
	}
	headBody, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()

	if headResp.StatusCode != getResp.StatusCode {
		t.Errorf("HEAD %s status %d != GET status %d", cardPath, headResp.StatusCode, getResp.StatusCode)
	}
	if len(headBody) != 0 {
		t.Errorf("HEAD %s expected 0 body bytes, got %d bytes: %s", cardPath, len(headBody), string(headBody))
	}

	// Mutating methods -> 405 Method Not Allowed with Allow: GET, HEAD
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, _ := http.NewRequest(method, ts.URL+cardPath, strings.NewReader(`{}`))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", method, cardPath, err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s %s expected 405, got %d", method, cardPath, resp.StatusCode)
		}
		allow := resp.Header.Get("Allow")
		if !strings.Contains(allow, "GET") || !strings.Contains(allow, "HEAD") {
			t.Errorf("%s %s expected Allow header to contain GET, HEAD, got %q", method, cardPath, allow)
		}
	}
}

func TestUnmatchedRoutes_HeadBodySuppression(t *testing.T) {
	ts := newTestServer(t)

	unmatchedPaths := []string{
		"/unknown",
		"/api/v1/bogus",
		"/health/subpath",
		"/tasks/123/subpath",
	}

	for _, path := range unmatchedPaths {
		// GET -> 404
		getResp, err := http.Get(ts.URL + path)
		if err != nil {
			t.Fatalf("GET %s failed: %v", path, err)
		}
		getBody, _ := io.ReadAll(getResp.Body)
		getResp.Body.Close()
		if getResp.StatusCode != http.StatusNotFound {
			t.Errorf("GET %s expected 404, got %d", path, getResp.StatusCode)
		}
		if len(getBody) == 0 {
			t.Errorf("GET %s expected non-empty body", path)
		}

		// HEAD -> 404 with 0 body bytes (RFC 9110 Section 6.4.1)
		headReq, _ := http.NewRequest(http.MethodHead, ts.URL+path, nil)
		headResp, err := http.DefaultClient.Do(headReq)
		if err != nil {
			t.Fatalf("HEAD %s failed: %v", path, err)
		}
		headBody, _ := io.ReadAll(headResp.Body)
		headResp.Body.Close()
		if headResp.StatusCode != http.StatusNotFound {
			t.Errorf("HEAD %s expected 404, got %d", path, headResp.StatusCode)
		}
		if len(headBody) != 0 {
			t.Errorf("HEAD %s expected 0 body bytes, got %d bytes: %s", path, len(headBody), string(headBody))
		}
	}
}

func TestHeadResponseWriter_Direct(t *testing.T) {
	statuses := []int{
		http.StatusOK,
		http.StatusCreated,
		http.StatusAccepted,
		http.StatusNoContent,
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
		http.StatusNotFound,
		http.StatusMethodNotAllowed,
		http.StatusUnprocessableEntity,
		http.StatusInternalServerError,
		http.StatusBadGateway,
		http.StatusServiceUnavailable,
	}

	for _, status := range statuses {
		rec := httptest.NewRecorder()
		hw := &headResponseWriter{ResponseWriter: rec}

		hw.WriteHeader(status)
		n, err := hw.Write([]byte("this should be completely suppressed on HEAD"))
		if err != nil {
			t.Fatalf("status %d Write returned error: %v", status, err)
		}
		if n != len("this should be completely suppressed on HEAD") {
			t.Fatalf("status %d Write returned count %d, expected %d", status, n, len("this should be completely suppressed on HEAD"))
		}
		if rec.Code != status {
			t.Errorf("expected recorder status %d, got %d", status, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("status %d expected empty recorder buffer, got %d bytes: %s", status, rec.Body.Len(), rec.Body.String())
		}
	}

	// Omitted WriteHeader defaults to 200 OK
	recDefault := httptest.NewRecorder()
	hwDefault := &headResponseWriter{ResponseWriter: recDefault}
	n, err := hwDefault.Write([]byte("auto 200 payload"))
	if err != nil || n != len("auto 200 payload") {
		t.Fatalf("default Write failed: n=%d, err=%v", n, err)
	}
	if recDefault.Code != http.StatusOK {
		t.Errorf("expected default status 200, got %d", recDefault.Code)
	}
	if recDefault.Body.Len() != 0 {
		t.Errorf("expected empty buffer on default Write, got %d bytes", recDefault.Body.Len())
	}

	// Flush verification
	recFlush := httptest.NewRecorder()
	hwFlush := &headResponseWriter{ResponseWriter: recFlush}
	hwFlush.Flush()
	if !recFlush.Flushed {
		t.Error("expected recorder to be marked flushed")
	}
}

func TestHeadBodySuppressingMiddleware_Direct(t *testing.T) {
	mockHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Custom-Header", "signalloom")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"result":"accepted"}`))
	})

	wrapped := headBodySuppressingMiddleware(mockHandler)

	// GET: body is preserved
	getReq := httptest.NewRequest(http.MethodGet, "/test", nil)
	getRec := httptest.NewRecorder()
	wrapped.ServeHTTP(getRec, getReq)
	if getRec.Code != http.StatusAccepted {
		t.Errorf("GET expected 202, got %d", getRec.Code)
	}
	if getRec.Body.String() != `{"result":"accepted"}` {
		t.Errorf("GET expected body preserved, got %q", getRec.Body.String())
	}
	if getRec.Header().Get("X-Custom-Header") != "signalloom" {
		t.Errorf("GET expected header preserved, got %q", getRec.Header().Get("X-Custom-Header"))
	}

	// HEAD: body is suppressed, status and headers preserved
	headReq := httptest.NewRequest(http.MethodHead, "/test", nil)
	headRec := httptest.NewRecorder()
	wrapped.ServeHTTP(headRec, headReq)
	if headRec.Code != http.StatusAccepted {
		t.Errorf("HEAD expected 202, got %d", headRec.Code)
	}
	if headRec.Body.Len() != 0 {
		t.Errorf("HEAD expected 0 body bytes, got %d bytes: %q", headRec.Body.Len(), headRec.Body.String())
	}
	if headRec.Header().Get("X-Custom-Header") != "signalloom" {
		t.Errorf("HEAD expected header preserved, got %q", headRec.Header().Get("X-Custom-Header"))
	}
}
