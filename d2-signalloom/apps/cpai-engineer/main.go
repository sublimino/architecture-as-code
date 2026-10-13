// Package main implements the cpai-engineer HTTP server — a Kubernetes-native
// stateful coding workspace that receives coding tasks and executes them inside
// a Landlock (nono) sandbox.
//
// Workload Type 4A: In-Cluster Sandboxed Coding Harness.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// TaskRequest is the wire format for POST /tasks.
type TaskRequest struct {
	Repo        string `json:"repo"`
	Branch      string `json:"branch"`
	Instruction string `json:"instruction"`
	TokenBudget int    `json:"token_budget"`
}

// TaskResponse is the wire format returned by POST /tasks and GET /tasks/{id}.
type TaskResponse struct {
	TaskID     string   `json:"task_id"`
	Status     string   `json:"status"`
	Commits    []string `json:"commits"`
	TokensUsed int      `json:"tokens_used"`
	Error      string   `json:"error,omitempty"`
	CreatedAt  string   `json:"created_at"`
	UpdatedAt  string   `json:"updated_at"`
}

// ErrorResponse is a standard error envelope.
type ErrorResponse struct {
	Error string `json:"error"`
}

func validateRepo(repo string) error {
	repo = strings.TrimSpace(repo)
	if repo == "" {
		return errors.New("repo is required")
	}
	if strings.HasPrefix(repo, "-") {
		return errors.New("repo cannot start with a dash")
	}
	if strings.ContainsAny(repo, "\r\n\x00") {
		return errors.New("repo cannot contain control characters")
	}
	lower := strings.ToLower(repo)
	if strings.HasPrefix(lower, "ext::") || strings.HasPrefix(lower, "fd::") {
		return errors.New("repo cannot use remote helper protocols")
	}
	if len(repo) > 1024 {
		return errors.New("repo URL must be 1024 characters or fewer")
	}
	return nil
}

var branchRegex = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9_\-\.\/]*$`)

func validateBranch(branch string) error {
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return nil
	}
	if len(branch) > 255 {
		return errors.New("branch name must be 255 characters or fewer")
	}
	if strings.HasPrefix(branch, "-") {
		return errors.New("branch cannot start with a dash")
	}
	if branch == "HEAD" {
		return errors.New("branch cannot be HEAD")
	}
	if strings.Contains(branch, "..") || strings.Contains(branch, "@{") || strings.Contains(branch, "//") || strings.Contains(branch, "/.") || strings.Contains(branch, ".lock/") {
		return errors.New("branch cannot contain path traversal, reflog syntax, hidden components, or .lock components")
	}
	if strings.HasSuffix(branch, "/") || strings.HasSuffix(branch, ".lock") || strings.HasSuffix(branch, ".") {
		return errors.New("branch cannot end with slash, dot, or .lock")
	}
	if !branchRegex.MatchString(branch) {
		return errors.New("branch contains invalid characters")
	}
	return nil
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	workspaceDir := os.Getenv("WORKSPACE_DIR")
	if workspaceDir == "" {
		workspaceDir = "/workspace"
	}

	nonoProfile := os.Getenv("NONO_PROFILE")
	if nonoProfile == "" {
		nonoProfile = "strict"
	}

	store, err := NewSessionStore(workspaceDir + "/.cpai/sessions.db")
	if err != nil {
		slog.Error("failed to initialise session store", "error", err)
		os.Exit(1)
	}
	defer store.Close()

	nono := NewNonoWrapper(nonoProfile)
	executor := NewExecutor(workspaceDir, nono, store)

	srv := newServer(executor, store)

	httpServer := &http.Server{
		Addr:              ":8084",
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go func() {
		slog.Info("cpai-engineer listening", "addr", httpServer.Addr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "error", err)
	}
}

func newServer(executor *Executor, store *SessionStore) http.Handler {
	mux := http.NewServeMux()

	healthOptionsHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	}
	mux.HandleFunc("OPTIONS /health", healthOptionsHandler)
	mux.HandleFunc("OPTIONS /healthz", healthOptionsHandler)
	mux.HandleFunc("OPTIONS /readyz", healthOptionsHandler)

	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	}
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("HEAD /health", healthHandler)
	mux.HandleFunc("GET /healthz", healthHandler)
	mux.HandleFunc("HEAD /healthz", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	mux.HandleFunc("HEAD /readyz", healthHandler)

	mux.HandleFunc("OPTIONS /tasks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /tasks", func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		defer func() {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
		}()

		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var req TaskRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
			return
		}

		req.Repo = strings.TrimSpace(req.Repo)
		req.Branch = strings.TrimSpace(req.Branch)
		req.Instruction = strings.TrimSpace(req.Instruction)

		if req.Repo == "" || req.Instruction == "" {
			writeError(w, http.StatusBadRequest, "repo and instruction are required")
			return
		}
		if err := validateRepo(req.Repo); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := validateBranch(req.Branch); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if req.TokenBudget <= 0 {
			req.TokenBudget = 50000
		} else if req.TokenBudget > 1000000 {
			writeError(w, http.StatusBadRequest, "token_budget must be 1000000 or fewer")
			return
		}

		task, err := executor.Submit(req)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to submit task: "+err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(task)
	})

	mux.HandleFunc("OPTIONS /tasks/{id}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	getTaskHandler := func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			writeError(w, http.StatusBadRequest, "task id required")
			return
		}

		task, err := store.Get(id)
		if err != nil {
			writeError(w, http.StatusNotFound, "task not found: "+id)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		json.NewEncoder(w).Encode(task)
	}
	mux.HandleFunc("GET /tasks/{id}", getTaskHandler)
	mux.HandleFunc("HEAD /tasks/{id}", getTaskHandler)

	listTasksHandler := func(w http.ResponseWriter, r *http.Request) {
		tasks, err := store.List(50)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "failed to list tasks")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		json.NewEncoder(w).Encode(tasks)
	}
	mux.HandleFunc("GET /tasks", listTasksHandler)
	mux.HandleFunc("HEAD /tasks", listTasksHandler)

	mux.HandleFunc("OPTIONS /.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	agentCardHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		http.ServeFile(w, r, ".well-known/agent-card.json")
	}
	mux.HandleFunc("GET /.well-known/agent-card.json", agentCardHandler)
	mux.HandleFunc("HEAD /.well-known/agent-card.json", agentCardHandler)

	return withLogging(headBodySuppressingMiddleware(mux))
}

type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(ErrorResponse{Error: msg})
}

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// Skip health check logging to reduce noise.
		if !strings.HasPrefix(r.URL.Path, "/health") {
			slog.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"duration", fmt.Sprintf("%dms", time.Since(start).Milliseconds()),
			)
		}
	})
}
