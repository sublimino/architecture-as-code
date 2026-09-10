//go:build acceptance

// Package main contains acceptance tests for the cpai-engineer HTTP API.
//
// These tests start a real HTTP server via newServer() and exercise the
// public endpoints: GET /health, POST /tasks, GET /tasks/{id}.
// Build-tag gated so they only run with: go test -tags acceptance ./...
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// testServer creates a throwaway cpai-engineer server backed by a temp
// workspace and SQLite store. Returns the httptest.Server and a cleanup func.
func testServer(t *testing.T) *httptest.Server {
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
	t.Cleanup(func() { store.Close() })

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(workspaceDir, nono, store)
	handler := newServer(executor, store)

	return httptest.NewServer(handler)
}

// ── Health ─────────────────────────────────────────────────────────────────

func TestAcceptanceHealthEndpoint(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}

	if body["status"] != "healthy" {
		t.Errorf("expected status=healthy, got %q", body["status"])
	}
}

// ── Task Submission ────────────────────────────────────────────────────────

func TestTaskSubmission(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	payload := TaskRequest{
		Repo:        "https://github.com/example/repo.git",
		Branch:      "main",
		Instruction: "Fix the README typo",
		TokenBudget: 10000,
	}

	body, _ := json.Marshal(payload)
	resp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 202, got %d: %s", resp.StatusCode, string(b))
	}

	var task TaskResponse
	if err := json.NewDecoder(resp.Body).Decode(&task); err != nil {
		t.Fatalf("decode task: %v", err)
	}

	if task.TaskID == "" {
		t.Error("task_id must not be empty")
	}
	if task.Status != "pending" {
		t.Errorf("expected status=pending, got %q", task.Status)
	}
}

// ── Task Status ────────────────────────────────────────────────────────────

func TestTaskStatus(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	// Submit a task first.
	payload := TaskRequest{
		Repo:        "https://github.com/example/repo.git",
		Branch:      "main",
		Instruction: "Add a test",
		TokenBudget: 5000,
	}
	body, _ := json.Marshal(payload)
	createResp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}

	var created TaskResponse
	json.NewDecoder(createResp.Body).Decode(&created)
	createResp.Body.Close()

	// GET the task by ID.
	resp, err := http.Get(ts.URL + "/tasks/" + created.TaskID)
	if err != nil {
		t.Fatalf("GET /tasks/%s: %v", created.TaskID, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}

	var fetched TaskResponse
	if err := json.NewDecoder(resp.Body).Decode(&fetched); err != nil {
		t.Fatalf("decode task: %v", err)
	}

	if fetched.TaskID != created.TaskID {
		t.Errorf("task_id mismatch: %q != %q", fetched.TaskID, created.TaskID)
	}
}

// ── Invalid Body ───────────────────────────────────────────────────────────

func TestInvalidTaskBody(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	// Empty body should fail JSON decode.
	resp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader([]byte{}))
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400 for empty body, got %d", resp.StatusCode)
	}

	var errResp ErrorResponse
	json.NewDecoder(resp.Body).Decode(&errResp)
	if errResp.Error == "" {
		t.Error("error message must not be empty")
	}
}

// ── Missing Required Fields ────────────────────────────────────────────────

func TestMissingRequiredFields(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	// Missing repo and instruction.
	payload := TaskRequest{
		Branch:      "main",
		TokenBudget: 5000,
	}
	body, _ := json.Marshal(payload)
	resp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400 for missing repo/instruction, got %d", resp.StatusCode)
	}
}

// ── Token Budget Defaults ──────────────────────────────────────────────────

func TestTokenBudgetDefaultsWhenZero(t *testing.T) {
	ts := testServer(t)
	defer ts.Close()

	payload := TaskRequest{
		Repo:        "https://github.com/example/repo.git",
		Instruction: "Do something",
		// TokenBudget omitted — should default to 50000.
	}
	body, _ := json.Marshal(payload)
	resp, err := http.Post(ts.URL+"/tasks", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /tasks: %v", err)
	}
	defer resp.Body.Close()

	// Should still accept — the server defaults token_budget to 50000.
	if resp.StatusCode != http.StatusAccepted {
		b, _ := io.ReadAll(resp.Body)
		t.Errorf("expected 202, got %d: %s", resp.StatusCode, string(b))
	}
}
