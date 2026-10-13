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
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
)

// WorkspaceRequest is the wire format for POST /workspaces.
type WorkspaceRequest struct {
	PVC      string `json:"pvc"`
	Branch   string `json:"branch"`
	User     string `json:"user"`
	TenantID string `json:"tenant_id,omitempty"`
}

// WorkspaceResponse is the wire format returned by the workspace manager.
type WorkspaceResponse struct {
	WorkspaceID    string `json:"workspace_id"`
	TenantID       string `json:"tenant_id,omitempty"`
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

var (
	pvcRegex    = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`)
	userRegex   = regexp.MustCompile(`^[a-zA-Z0-9_\-\.]+$`)
	branchRegex = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9_\-\.\/]*$`)
	tenantRegex = regexp.MustCompile(`^[a-zA-Z0-9][-a-zA-Z0-9_.]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$`)
)

func validateTenant(tenant string) error {
	tenant = strings.TrimSpace(tenant)
	if tenant == "" || tenant == "*" {
		return nil
	}
	if len(tenant) > 63 {
		return errors.New("tenant must be 63 characters or fewer")
	}
	if strings.Contains(tenant, "..") || strings.Contains(tenant, "/") || !tenantRegex.MatchString(tenant) {
		return errors.New("tenant contains invalid characters or path traversal")
	}
	return nil
}

func validatePVC(pvc string) error {
	pvc = strings.TrimSpace(pvc)
	if pvc == "" {
		return errors.New("pvc is required")
	}
	if len(pvc) > 253 {
		return errors.New("pvc must be 253 characters or fewer")
	}
	if strings.Contains(pvc, "..") || strings.Contains(pvc, "/") || !pvcRegex.MatchString(pvc) {
		return errors.New("pvc must be a valid DNS subdomain name")
	}
	return nil
}

func validateUser(user string) error {
	user = strings.TrimSpace(user)
	if user == "" {
		return errors.New("user is required")
	}
	if len(user) > 63 {
		return errors.New("user must be 63 characters or fewer")
	}
	if strings.Contains(user, "..") || strings.Contains(user, "/") || !userRegex.MatchString(user) {
		return errors.New("user must be an alphanumeric identifier without path traversal")
	}
	return nil
}

func validateBranch(branch string) error {
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return nil
	}
	if len(branch) > 255 {
		return errors.New("branch must be 255 characters or fewer")
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

func extractTenant(r *http.Request) (string, error) {
	headerTenant := strings.TrimSpace(r.Header.Get("X-Tenant-ID"))
	queryTenant := strings.TrimSpace(r.URL.Query().Get("tenant"))
	if queryTenant == "" {
		queryTenant = strings.TrimSpace(r.URL.Query().Get("tenant_id"))
	}

	if headerTenant != "" && queryTenant != "" && headerTenant != queryTenant {
		return "", fmt.Errorf("conflicting tenant in header (%s) and query (%s)", headerTenant, queryTenant)
	}
	tenant := headerTenant
	if tenant == "" {
		tenant = queryTenant
	}
	if err := validateTenant(tenant); err != nil {
		return "", err
	}
	return tenant, nil
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

	pruneTicker := time.NewTicker(5 * time.Minute)
	defer pruneTicker.Stop()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-pruneTicker.C:
				pruned := mgr.PruneExpired(24 * time.Hour)
				if pruned > 0 {
					slog.Info("periodic background prune completed", "pruned", pruned)
				}
			}
		}
	}()

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

	healthOptionsHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	}
	mux.HandleFunc("OPTIONS /health", healthOptionsHandler)
	mux.HandleFunc("OPTIONS /healthz", healthOptionsHandler)
	mux.HandleFunc("OPTIONS /readyz", healthOptionsHandler)
	mux.HandleFunc("OPTIONS /livez", healthOptionsHandler)

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
	mux.HandleFunc("GET /livez", healthHandler)
	mux.HandleFunc("HEAD /livez", healthHandler)

	mux.HandleFunc("OPTIONS /workspaces", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "GET, HEAD, POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /workspaces", func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		defer func() {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
		}()

		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}

		var req WorkspaceRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
			return
		}

		if err := validatePVC(req.PVC); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := validateUser(req.User); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := validateBranch(req.Branch); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		req.TenantID = strings.TrimSpace(req.TenantID)
		if err := validateTenant(req.TenantID); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		if tenant != "" {
			if req.TenantID != "" && req.TenantID != tenant {
				writeError(w, http.StatusForbidden, fmt.Sprintf("cross-tenant operation forbidden: authenticated tenant %q cannot operate on %q", tenant, req.TenantID))
				return
			}
			req.TenantID = tenant
		} else if req.TenantID == "" {
			req.TenantID = "default"
		}

		ws, err := mgr.Create(req)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(ws)
	})

	mux.HandleFunc("OPTIONS /workspaces/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "prune" {
			w.Header().Set("Allow", "POST, OPTIONS")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.Header().Set("Allow", "GET, HEAD, DELETE, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	getWorkspaceHandler := func(w http.ResponseWriter, r *http.Request) {
		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}

		id := r.PathValue("id")
		if id == "prune" {
			w.Header().Set("Allow", "POST")
			writeError(w, http.StatusMethodNotAllowed, "method not allowed on /workspaces/prune")
			return
		}
		ws, ok := mgr.Get(id, tenant)
		if !ok {
			writeError(w, http.StatusNotFound, "workspace not found: "+id)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		json.NewEncoder(w).Encode(ws)
	}
	mux.HandleFunc("GET /workspaces/{id}", getWorkspaceHandler)
	mux.HandleFunc("HEAD /workspaces/{id}", getWorkspaceHandler)

	mux.HandleFunc("DELETE /workspaces/{id}", func(w http.ResponseWriter, r *http.Request) {
		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}

		id := r.PathValue("id")
		if id == "prune" {
			w.Header().Set("Allow", "POST")
			writeError(w, http.StatusMethodNotAllowed, "method not allowed on /workspaces/prune")
			return
		}
		deleted, delErr := mgr.Delete(id, tenant)
		if delErr != nil {
			writeError(w, http.StatusForbidden, delErr.Error())
			return
		}
		if !deleted {
			writeError(w, http.StatusNotFound, "workspace not found: "+id)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("OPTIONS /workspaces/{id}/teardown", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /workspaces/{id}/teardown", func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		defer func() {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
		}()

		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}

		id := r.PathValue("id")
		ws, tearErr := mgr.Teardown(id, tenant)
		if tearErr != nil {
			if strings.Contains(tearErr.Error(), "not found") {
				writeError(w, http.StatusNotFound, tearErr.Error())
				return
			}
			if strings.Contains(tearErr.Error(), "forbidden") {
				writeError(w, http.StatusForbidden, tearErr.Error())
				return
			}
			writeError(w, http.StatusInternalServerError, tearErr.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(ws)
	})

	mux.HandleFunc("OPTIONS /workspaces/prune", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("POST /workspaces/prune", func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		defer func() {
			_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 4096))
		}()

		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}
		ttl := 1 * time.Hour
		if rawTTL := r.URL.Query().Get("ttl"); rawTTL != "" {
			if parsed, err := time.ParseDuration(rawTTL); err == nil && parsed > 0 {
				ttl = parsed
			}
		}
		pruned := mgr.PruneExpired(ttl, tenant)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]int{"pruned": pruned})
	})

	listWorkspacesHandler := func(w http.ResponseWriter, r *http.Request) {
		tenant, err := extractTenant(r)
		if err != nil {
			writeError(w, http.StatusForbidden, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		json.NewEncoder(w).Encode(mgr.List(tenant))
	}
	mux.HandleFunc("GET /workspaces", listWorkspacesHandler)
	mux.HandleFunc("HEAD /workspaces", listWorkspacesHandler)

	return headBodySuppressingMiddleware(mux)
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

// maxWorkspaces bounds total concurrent workspace allocations in memory.
const maxWorkspaces = 500

func cloneWorkspace(ws *WorkspaceResponse) *WorkspaceResponse {
	if ws == nil {
		return nil
	}
	clone := *ws
	return &clone
}

// Create provisions a new workspace. In production this creates a K8s pod
// from the workspace-pod-template; in the demo it records the workspace
// metadata and generates synthetic endpoints.
func (m *WorkspaceManager) Create(req WorkspaceRequest) (*WorkspaceResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if len(m.workspaces) >= maxWorkspaces {
		return nil, errors.New("workspace capacity exceeded")
	}

	id := uuid.New().String()[:8]
	podName := fmt.Sprintf("daytona-ws-%s", id)

	tenantID := req.TenantID
	if tenantID == "" {
		tenantID = "default"
	}

	ws := &WorkspaceResponse{
		WorkspaceID:    id,
		TenantID:       tenantID,
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
		"tenant_id", tenantID,
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
		if ws, ok := m.workspaces[id]; ok && ws.Status == "provisioning" {
			ws.Status = "running"
			slog.Info("workspace running", "workspace_id", id)
		}
		m.mu.Unlock()
	}()

	return cloneWorkspace(ws), nil
}

// Get returns a workspace by ID, ensuring tenant isolation.
func (m *WorkspaceManager) Get(id, tenant string) (*WorkspaceResponse, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	ws, ok := m.workspaces[id]
	if !ok {
		return nil, false
	}
	if tenant != "" && tenant != "*" && ws.TenantID != "" && ws.TenantID != tenant {
		return nil, false
	}
	return cloneWorkspace(ws), true
}

// Delete removes a workspace, ensuring tenant isolation.
func (m *WorkspaceManager) Delete(id, tenant string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ws, ok := m.workspaces[id]
	if !ok {
		return false, nil
	}
	if tenant != "" && tenant != "*" && ws.TenantID != "" && ws.TenantID != tenant {
		return false, fmt.Errorf("cross-tenant delete forbidden: authenticated tenant %q cannot delete workspace belonging to %q", tenant, ws.TenantID)
	}
	delete(m.workspaces, id)
	slog.Info("workspace deleted", "workspace_id", id, "tenant_id", ws.TenantID)
	return true, nil
}

// Teardown marks a workspace as terminated or tears down its resources, ensuring tenant isolation.
func (m *WorkspaceManager) Teardown(id, tenant string) (*WorkspaceResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ws, ok := m.workspaces[id]
	if !ok {
		return nil, errors.New("workspace not found: " + id)
	}
	if tenant != "" && tenant != "*" && ws.TenantID != "" && ws.TenantID != tenant {
		return nil, fmt.Errorf("cross-tenant teardown forbidden: authenticated tenant %q cannot teardown workspace belonging to %q", tenant, ws.TenantID)
	}
	ws.Status = "terminated"
	slog.Info("workspace torn down", "workspace_id", id, "tenant_id", ws.TenantID)
	return cloneWorkspace(ws), nil
}

// List returns active workspaces filtered by tenant if provided.
func (m *WorkspaceManager) List(tenant string) []*WorkspaceResponse {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]*WorkspaceResponse, 0, len(m.workspaces))
	for _, ws := range m.workspaces {
		if tenant == "" || tenant == "*" || ws.TenantID == tenant {
			result = append(result, cloneWorkspace(ws))
		}
	}
	return result
}

// PruneExpired removes workspaces older than ttl, filtered by tenant if provided, and returns the count pruned.
func (m *WorkspaceManager) PruneExpired(ttl time.Duration, tenant ...string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	targetTenant := ""
	if len(tenant) > 0 {
		targetTenant = tenant[0]
	}
	now := time.Now().UTC()
	pruned := 0
	for id, ws := range m.workspaces {
		if targetTenant != "" && targetTenant != "*" && ws.TenantID != targetTenant {
			continue
		}
		if ws.CreatedAt != "" {
			if t, err := time.Parse(time.RFC3339, ws.CreatedAt); err == nil {
				if now.Sub(t) > ttl {
					delete(m.workspaces, id)
					pruned++
					slog.Info("workspace pruned due to expiry", "workspace_id", id, "tenant_id", ws.TenantID, "age", now.Sub(t))
				}
			}
		}
	}
	return pruned
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if _, ok := w.(*headResponseWriter); ok {
		return
	}
	_ = json.NewEncoder(w).Encode(ErrorResponse{Error: msg})
}
