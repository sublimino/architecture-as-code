// Package main implements the hosted-daytona-coder workspace manager.
//
// Workload Type 4B: Hosted Remote Coding Harness.
//
// When the CPAI engineer agent hits a complexity barrier or HITL (Human-In-The-Loop)
// gate, this manager provisions an isolated Daytona devcontainer workspace on K8s
// sharing the same PVC, giving a human developer full IDE access.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
)

// WorkspaceRequest is the wire format for POST /workspaces.
type WorkspaceRequest struct {
	PVC    string `json:"pvc"`
	Branch string `json:"branch"`
	User   string `json:"user"`
}

// WorkspaceResponse is the wire format returned by the workspace manager.
type WorkspaceResponse struct {
	WorkspaceID    string `json:"workspace_id"`
	Status         string `json:"status"`
	SSHUrl         string `json:"ssh_url,omitempty"`
	VSCodeUrl      string `json:"vscode_url,omitempty"`
	WebTerminalUrl string `json:"web_terminal_url,omitempty"`
	PodName        string `json:"pod_name,omitempty"`
	CreatedAt      string `json:"created_at"`
	Error          string `json:"error,omitempty"`
}

// ErrorResponse is a standard error envelope.
type ErrorResponse struct {
	Error string `json:"error"`
}

// WorkspaceManager tracks active workspaces.
type WorkspaceManager struct {
	mu         sync.RWMutex
	workspaces map[string]*WorkspaceResponse
	namespace  string
}

// NewWorkspaceManager creates a manager for the given namespace.
func NewWorkspaceManager(namespace string) *WorkspaceManager {
	return &WorkspaceManager{
		workspaces: make(map[string]*WorkspaceResponse),
		namespace:  namespace,
	}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		namespace = "fe-signalloom-agents"
	}

	mgr := NewWorkspaceManager(namespace)
	srv := newServer(mgr)

	httpServer := &http.Server{
		Addr:              ":8085",
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go func() {
		slog.Info("hosted-daytona-coder workspace manager listening", "addr", httpServer.Addr)
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

func newServer(mgr *WorkspaceManager) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	mux.HandleFunc("POST /workspaces", func(w http.ResponseWriter, r *http.Request) {
		var req WorkspaceRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
			return
		}

		if req.PVC == "" {
			writeError(w, http.StatusBadRequest, "pvc is required")
			return
		}
		if req.User == "" {
			writeError(w, http.StatusBadRequest, "user is required")
			return
		}

		ws := mgr.Create(req)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(ws)
	})

	mux.HandleFunc("GET /workspaces/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		ws, ok := mgr.Get(id)
		if !ok {
			writeError(w, http.StatusNotFound, "workspace not found: "+id)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(ws)
	})

	mux.HandleFunc("DELETE /workspaces/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if !mgr.Delete(id) {
			writeError(w, http.StatusNotFound, "workspace not found: "+id)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("GET /workspaces", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(mgr.List())
	})

	return mux
}

// Create provisions a new workspace. In production this creates a K8s pod
// from the workspace-pod-template; in the demo it records the workspace
// metadata and generates synthetic endpoints.
func (m *WorkspaceManager) Create(req WorkspaceRequest) *WorkspaceResponse {
	m.mu.Lock()
	defer m.mu.Unlock()

	id := uuid.New().String()[:8]
	podName := fmt.Sprintf("daytona-ws-%s", id)

	ws := &WorkspaceResponse{
		WorkspaceID:    id,
		Status:         "provisioning",
		PodName:        podName,
		SSHUrl:         fmt.Sprintf("ssh://%s.%s.svc.cluster.local:2222", podName, m.namespace),
		VSCodeUrl:      fmt.Sprintf("https://%s.%s.svc.cluster.local:8443/?folder=/workspace", podName, m.namespace),
		WebTerminalUrl: fmt.Sprintf("https://%s.%s.svc.cluster.local:8443/terminal", podName, m.namespace),
		CreatedAt:      time.Now().UTC().Format(time.RFC3339),
	}

	m.workspaces[id] = ws

	slog.Info("workspace created",
		"workspace_id", id,
		"pod", podName,
		"pvc", req.PVC,
		"user", req.User,
		"branch", req.Branch,
	)

	// In production, this would create the pod via K8s API.
	// For the demo, mark as running after a brief delay.
	go func() {
		time.Sleep(2 * time.Second)
		m.mu.Lock()
		if ws, ok := m.workspaces[id]; ok {
			ws.Status = "running"
		}
		m.mu.Unlock()
		slog.Info("workspace running", "workspace_id", id)
	}()

	return ws
}

// Get returns a workspace by ID.
func (m *WorkspaceManager) Get(id string) (*WorkspaceResponse, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	ws, ok := m.workspaces[id]
	return ws, ok
}

// Delete removes a workspace. In production this deletes the K8s pod.
func (m *WorkspaceManager) Delete(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.workspaces[id]; !ok {
		return false
	}
	delete(m.workspaces, id)
	slog.Info("workspace deleted", "workspace_id", id)
	return true
}

// List returns all active workspaces.
func (m *WorkspaceManager) List() []*WorkspaceResponse {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]*WorkspaceResponse, 0, len(m.workspaces))
	for _, ws := range m.workspaces {
		result = append(result, ws)
	}
	return result
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(ErrorResponse{Error: msg})
}
