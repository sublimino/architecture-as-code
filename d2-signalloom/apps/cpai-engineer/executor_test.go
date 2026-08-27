package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- Nono wrapper unit tests ---

func TestNonoWrapper_StrictProfile(t *testing.T) {
	n := NewNonoWrapper("strict")
	cmd := n.Wrap("echo", "hello")

	got := strings.Join(cmd.Args, " ")
	// Must contain nono, sandbox flags, and the wrapped command.
	for _, want := range []string{
		"nono",
		"--allow-read", "/workspace",
		"--allow-write", "/workspace",
		"--allow-read", "/tmp",
		"--allow-write", "/tmp",
		"--",
		"echo", "hello",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("strict profile command missing %q\ngot: %s", want, got)
		}
	}
}

func TestNonoWrapper_RelaxedProfile(t *testing.T) {
	n := NewNonoWrapper("relaxed")
	readPaths, writePaths := n.profilePaths()

	if len(readPaths) < 4 {
		t.Errorf("relaxed profile should have >= 4 read paths, got %d", len(readPaths))
	}
	if len(writePaths) < 3 {
		t.Errorf("relaxed profile should have >= 3 write paths, got %d", len(writePaths))
	}
}

func TestNonoWrapper_DefaultFallsBackToStrict(t *testing.T) {
	n := NewNonoWrapper("unknown-profile")
	readPaths, _ := n.profilePaths()

	strictN := NewNonoWrapper("strict")
	strictRead, _ := strictN.profilePaths()

	if len(readPaths) != len(strictRead) {
		t.Errorf("unknown profile should fall back to strict, got %d read paths vs %d",
			len(readPaths), len(strictRead))
	}
}

func TestNonoWrapper_WrapWithDir(t *testing.T) {
	n := NewNonoWrapper("strict")
	cmd := n.WrapWithDir("/workspace/myrepo", "git", "status")

	if cmd.Dir != "/workspace/myrepo" {
		t.Errorf("expected dir /workspace/myrepo, got %s", cmd.Dir)
	}
}

func TestNonoWrapper_CommandString(t *testing.T) {
	n := NewNonoWrapper("strict")
	s := n.CommandString("opencode", "-y", "--message", "fix the bug")

	if !strings.Contains(s, "nono") {
		t.Errorf("CommandString should start with nono, got: %s", s)
	}
	if !strings.Contains(s, "opencode") {
		t.Errorf("CommandString should contain the wrapped command, got: %s", s)
	}
}

// --- Session store unit tests ---

func TestSessionStore_CRUD(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "test.db")

	store, err := NewSessionStore(dbPath)
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	task := &TaskResponse{
		TaskID:    "test-123",
		Status:    "pending",
		Commits:   []string{},
		CreatedAt: "2026-01-01T00:00:00Z",
		UpdatedAt: "2026-01-01T00:00:00Z",
	}

	// Insert.
	if err := store.Insert(task, "https://github.com/test/repo", "main", "fix the bug"); err != nil {
		t.Fatalf("Insert: %v", err)
	}

	// Get.
	got, err := store.Get("test-123")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.TaskID != "test-123" || got.Status != "pending" {
		t.Errorf("Get returned unexpected task: %+v", got)
	}

	// Update.
	task.Status = "completed"
	task.Commits = []string{"abc123", "def456"}
	task.TokensUsed = 12345
	task.UpdatedAt = "2026-01-01T01:00:00Z"
	if err := store.Update(task); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err = store.Get("test-123")
	if err != nil {
		t.Fatalf("Get after update: %v", err)
	}
	if got.Status != "completed" {
		t.Errorf("expected completed, got %s", got.Status)
	}
	if len(got.Commits) != 2 {
		t.Errorf("expected 2 commits, got %d", len(got.Commits))
	}
	if got.TokensUsed != 12345 {
		t.Errorf("expected 12345 tokens, got %d", got.TokensUsed)
	}

	// List.
	tasks, err := store.List(10)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(tasks) != 1 {
		t.Errorf("expected 1 task, got %d", len(tasks))
	}
}

func TestSessionStore_GetNotFound(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	_, err = store.Get("nonexistent")
	if err == nil {
		t.Error("expected error for nonexistent task")
	}
}

func TestSessionStore_ListEmpty(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	tasks, err := store.List(10)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(tasks) != 0 {
		t.Errorf("expected empty list, got %d", len(tasks))
	}
}

// --- HTTP handler unit tests ---

func TestHealthEndpoint(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(dir, nono, store)
	srv := newServer(executor, store)

	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	json.NewDecoder(w.Body).Decode(&body)
	if body["status"] != "healthy" {
		t.Errorf("expected healthy, got %s", body["status"])
	}
}

func TestPostTask_Validation(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(dir, nono, store)
	srv := newServer(executor, store)

	tests := []struct {
		name string
		body string
		code int
	}{
		{"empty body", `{}`, http.StatusBadRequest},
		{"missing instruction", `{"repo":"test"}`, http.StatusBadRequest},
		{"missing repo", `{"instruction":"fix it"}`, http.StatusBadRequest},
		{"invalid json", `{bad`, http.StatusBadRequest},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/tasks", strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.ServeHTTP(w, req)

			if w.Code != tc.code {
				t.Errorf("expected %d, got %d: %s", tc.code, w.Code, w.Body.String())
			}
		})
	}
}

func TestPostTask_ValidRequest(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	// The executor will fail because there's no real repo, but we test that
	// the HTTP layer accepts the request and returns 202.
	nono := NewNonoWrapper("strict")
	executor := NewExecutor(dir, nono, store)
	srv := newServer(executor, store)

	body := `{"repo":"https://github.com/test/repo","branch":"main","instruction":"fix the bug","token_budget":10000}`
	req := httptest.NewRequest("POST", "/tasks", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)

	if w.Code != http.StatusAccepted {
		t.Errorf("expected 202, got %d: %s", w.Code, w.Body.String())
	}

	var resp TaskResponse
	json.NewDecoder(w.Body).Decode(&resp)
	if resp.TaskID == "" {
		t.Error("expected non-empty task_id")
	}
	if resp.Status != "pending" {
		t.Errorf("expected pending, got %s", resp.Status)
	}
}

func TestGetTaskNotFound(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(dir, nono, store)
	srv := newServer(executor, store)

	req := httptest.NewRequest("GET", "/tasks/nonexistent-id", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

func TestGetTasksList(t *testing.T) {
	dir := t.TempDir()
	store, err := NewSessionStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("NewSessionStore: %v", err)
	}
	defer store.Close()

	nono := NewNonoWrapper("strict")
	executor := NewExecutor(dir, nono, store)
	srv := newServer(executor, store)

	req := httptest.NewRequest("GET", "/tasks", nil)
	w := httptest.NewRecorder()
	srv.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var tasks []TaskResponse
	json.NewDecoder(w.Body).Decode(&tasks)
	if len(tasks) != 0 {
		t.Errorf("expected empty list, got %d", len(tasks))
	}
}

// --- sanitisePath tests ---

func TestSanitisePath(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"https://github.com/org/repo.git", "github.com_org_repo"},
		{"git@github.com:org/repo.git", "github.com_org_repo"},
		{"http://gitlab.example.com/team/project", "gitlab.example.com_team_project"},
	}
	for _, tc := range tests {
		got := sanitisePath(tc.input)
		if got != tc.want {
			t.Errorf("sanitisePath(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// --- Environment variable defaults ---

func TestDefaultWorkspaceDir(t *testing.T) {
	// Just verify the env var mechanism works.
	os.Setenv("WORKSPACE_DIR", "/custom/workspace")
	defer os.Unsetenv("WORKSPACE_DIR")

	val := os.Getenv("WORKSPACE_DIR")
	if val != "/custom/workspace" {
		t.Errorf("expected /custom/workspace, got %s", val)
	}
}
