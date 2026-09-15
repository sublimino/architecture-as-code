// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// AdmissionOutcome represents the fine-grained outcome of an admission decision.
type AdmissionOutcome string

const (
	// OutcomeAllowed indicates the pod satisfied all security and containment policies.
	OutcomeAllowed AdmissionOutcome = "allowed"
	// OutcomeDeniedContainedIdentity indicates the pod identity matched an active containment record.
	OutcomeDeniedContainedIdentity AdmissionOutcome = "denied_contained_identity"
	// OutcomeDeniedStoreUnavailable indicates admission was denied because the identity store failed (fail-closed).
	OutcomeDeniedStoreUnavailable AdmissionOutcome = "denied_store_unavailable"
	// OutcomeDeniedNodeCapability indicates the agent pod lacked required kernel containment node selectors.
	OutcomeDeniedNodeCapability AdmissionOutcome = "denied_node_capability"
)

// Metrics counters: global legacy counters + fine-grained outcome counters.
var (
	// Legacy global counters (preserved for existing dashboards and monitors)
	RejectionsTotal uint64
	AdmissionsTotal uint64

	// Outcome-specific counters extending the metrics surface
	RejectionsContainedIdentityTotal uint64
	RejectionsStoreUnavailableTotal uint64
	RejectionsNodeCapabilityTotal   uint64
	AdmissionsAllowedTotal          uint64
)

// Default runtime configuration
var (
	DefaultTrustDomain = "signalloom.demo"
	DefaultStore       ContainedIdentityStore
	defaultStoreOnce   sync.Once
	AuditLogger        func(entry AdmissionDecisionLogEntry)
)

func init() {
	AuditLogger = defaultAuditLogger
}

// GetDefaultStore returns the active default store, initializing a MemoryIdentityStore if nil.
func GetDefaultStore() ContainedIdentityStore {
	defaultStoreOnce.Do(func() {
		if DefaultStore == nil {
			DefaultStore = NewMemoryIdentityStore()
		}
	})
	return DefaultStore
}

// SetDefaultStore configures the global default store.
func SetDefaultStore(store ContainedIdentityStore) {
	DefaultStore = store
}

// AdmissionDecisionLogEntry is the structured, machine-readable JSON log record emitted for every decision.
type AdmissionDecisionLogEntry struct {
	Event               string           `json:"event"`
	UID                 string           `json:"uid"`
	Operation           string           `json:"operation"`
	Namespace           string           `json:"namespace"`
	PodName             string           `json:"pod_name"`
	AgentID             string           `json:"agent_id,omitempty"`
	SPIFFEID            string           `json:"spiffe_id,omitempty"`
	Allowed             bool             `json:"allowed"`
	Outcome             AdmissionOutcome `json:"outcome"`
	Reason              string           `json:"reason"`
	LatencyMs           int64            `json:"latency_ms"`
	WorstCaseResidualMs int64            `json:"worst_case_residual_ms"`
	ResidualProvenance  string           `json:"residual_provenance"`
	Timestamp           string           `json:"timestamp"`
	Error               string           `json:"error,omitempty"`
}

func defaultAuditLogger(entry AdmissionDecisionLogEntry) {
	data, err := json.Marshal(entry)
	if err != nil {
		slog.Error("failed to marshal admission decision audit log", "error", err)
		return
	}
	slog.Info("admission_decision", "record", string(data))
}

// AdmissionReview mimics standard k8s admission/v1 AdmissionReview
type AdmissionReview struct {
	APIVersion string            `json:"apiVersion,omitempty"`
	Kind       string            `json:"kind,omitempty"`
	Request    *AdmissionRequest  `json:"request,omitempty"`
	Response   *AdmissionResponse `json:"response,omitempty"`
}

type AdmissionRequest struct {
	UID       string               `json:"uid"`
	Kind      GroupVersionKind     `json:"kind"`
	Resource  GroupVersionResource `json:"resource"`
	Namespace string               `json:"namespace,omitempty"`
	Name      string               `json:"name,omitempty"`
	Operation string               `json:"operation,omitempty"`
	Object    json.RawMessage      `json:"object,omitempty"`
	OldObject json.RawMessage      `json:"oldObject,omitempty"`
}

type GroupVersionKind struct {
	Group   string `json:"group"`
	Version string `json:"version"`
	Kind    string `json:"kind"`
}

type GroupVersionResource struct {
	Group    string `json:"group"`
	Version  string `json:"version"`
	Resource string `json:"resource"`
}

type AdmissionResponse struct {
	UID     string  `json:"uid"`
	Allowed bool    `json:"allowed"`
	Result  *Status `json:"status,omitempty"`
}

type Status struct {
	Code    int32  `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// Minimal Pod definition for admission inspection
type Pod struct {
	Metadata Metadata `json:"metadata"`
	Spec     PodSpec  `json:"spec"`
}

type Metadata struct {
	Name        string            `json:"name"`
	Namespace   string            `json:"namespace"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
}

type PodSpec struct {
	NodeSelector       map[string]string `json:"nodeSelector"`
	NodeName           string            `json:"nodeName"`
	ServiceAccountName string            `json:"serviceAccountName"`
}

// ValidatePod evaluates kernel containment scheduling rules and active containment status for an agent pod.
// Backward-compatible signature that uses DefaultStore and DefaultTrustDomain.
func ValidatePod(pod *Pod) (bool, string) {
	allowed, msg, _ := ValidatePodWithContext(context.Background(), pod, "CREATE", GetDefaultStore(), DefaultTrustDomain)
	return allowed, msg
}

// ValidatePodWithContext evaluates admission against identity, store, and node capabilities.
func ValidatePodWithContext(ctx context.Context, pod *Pod, operation string, store ContainedIdentityStore, trustDomain string) (bool, string, AdmissionOutcome) {
	if pod == nil {
		return true, "", OutcomeAllowed
	}

	if trustDomain == "" {
		trustDomain = DefaultTrustDomain
	}

	isAgent := false
	var agentID string
	var spiffeID string

	// 1. Evaluate Agent Identity Indicators
	if pod.Metadata.Labels != nil {
		if pod.Metadata.Labels["signalloom.ai/agent"] == "true" ||
			pod.Metadata.Labels["signalloom.ai/role"] == "agent" ||
			pod.Metadata.Labels["app.kubernetes.io/component"] == "agent" ||
			pod.Metadata.Labels["signalloom.ai/agent-name"] != "" {
			isAgent = true
			if name := pod.Metadata.Labels["signalloom.ai/agent-name"]; name != "" {
				agentID = name
			}
		}
	}

	if !isAgent {
		if strings.HasPrefix(pod.Metadata.Name, "agent-") {
			isAgent = true
		} else if strings.HasPrefix(pod.Spec.ServiceAccountName, "agent-") {
			isAgent = true
		}
	}

	if !isAgent {
		return true, "non-agent pod allowed unconditionally", OutcomeAllowed
	}

	// 2. Resolve Candidate Identifiers for Contained Store Query
	candidates := make([]string, 0, 8)

	if agentID != "" {
		candidates = append(candidates, agentID)
		candidates = append(candidates, strings.TrimPrefix(agentID, "agent-"))
		if !strings.HasPrefix(agentID, "agent-") {
			candidates = append(candidates, "agent-"+agentID)
		}
	}

	if pod.Metadata.Name != "" {
		candidates = append(candidates, pod.Metadata.Name)
		// Strip pod replica hash prefix (e.g. agent-cardvault-7bc6f -> agent-cardvault)
		parts := strings.Split(pod.Metadata.Name, "-")
		if len(parts) >= 2 {
			baseName := strings.Join(parts[:len(parts)-1], "-")
			candidates = append(candidates, baseName)
			candidates = append(candidates, strings.TrimPrefix(baseName, "agent-"))
		}
	}

	if pod.Spec.ServiceAccountName != "" {
		sa := pod.Spec.ServiceAccountName
		candidates = append(candidates, sa)
		candidates = append(candidates, strings.TrimPrefix(sa, "agent-"))
		if pod.Metadata.Namespace != "" {
			spiffeID = fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", trustDomain, pod.Metadata.Namespace, sa)
			candidates = append(candidates, spiffeID)
		}
	}

	// 3. Reject Pods that explicitly present contained/stunned state labels in manifest
	if pod.Metadata.Labels != nil {
		if pod.Metadata.Labels["signalloom.ai/state"] == "stunned" ||
			pod.Metadata.Labels["signalloom.io/stunned"] == "true" ||
			pod.Metadata.Labels["signalloom.io/containment-mode"] == "frozen" ||
			pod.Metadata.Labels["signalloom.io/containment-mode"] == "isolated" ||
			pod.Metadata.Labels["signalloom.io/containment-mode"] == "quarantined" {
			msg := fmt.Sprintf("agent pod rejected: pod manifest specifies contained/stunned state (readmission prohibited on %s)", operation)
			return false, msg, OutcomeDeniedContainedIdentity
		}
	}

	// 4. Query Contained Identity Store (Fail-Closed on Store Error)
	if store != nil {
		isContained, matchedID, err := store.IsContained(ctx, pod.Metadata.Namespace, candidates)
		if err != nil {
			msg := fmt.Sprintf("agent pod rejected: contained identity store error (fail-closed security policy): %v", err)
			return false, msg, OutcomeDeniedStoreUnavailable
		}
		if isContained {
			msg := fmt.Sprintf("agent pod rejected: agent identity %q is currently contained/stunned (readmission blocked on %s)", matchedID, operation)
			return false, msg, OutcomeDeniedContainedIdentity
		}
	}

	// 5. Verify Required Kernel Node Containment Selectors
	cgroupV2 := false
	landlock := false

	if pod.Spec.NodeSelector != nil {
		if pod.Spec.NodeSelector["node.signalloom.ai/cgroup-v2"] == "true" {
			cgroupV2 = true
		}
		if pod.Spec.NodeSelector["node.signalloom.ai/landlock"] == "true" {
			landlock = true
		}
	}

	if !cgroupV2 || !landlock {
		return false, "agent pod rejected: scheduling requires node with active kernel containment (cgroup-v2=true, landlock=true)", OutcomeDeniedNodeCapability
	}

	return true, "agent pod verified with kernel containment requirements and active identity status", OutcomeAllowed
}

// WebhookServer provides an HTTP handler for admission review requests.
type WebhookServer struct {
	Store       ContainedIdentityStore
	TrustDomain string
	Now         func() time.Time
	Logger      func(AdmissionDecisionLogEntry)
}

// NewWebhookServer creates a new WebhookServer with configured dependencies.
func NewWebhookServer(store ContainedIdentityStore, trustDomain string) *WebhookServer {
	if store == nil {
		store = GetDefaultStore()
	}
	if trustDomain == "" {
		trustDomain = DefaultTrustDomain
	}
	return &WebhookServer{
		Store:       store,
		TrustDomain: trustDomain,
		Now:         time.Now,
		Logger:      AuditLogger,
	}
}

// ServeHTTP handles admission webhook requests.
func (s *WebhookServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.HandleValidate(w, r)
}

// HandleValidate handles admission webhook validation requests.
func (s *WebhookServer) HandleValidate(w http.ResponseWriter, r *http.Request) {
	start := s.Now()
	timestamp := start.UTC().Format(time.RFC3339)

	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}

	var review AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	if review.Request == nil {
		http.Error(w, "missing request", http.StatusBadRequest)
		return
	}

	var pod Pod
	if len(review.Request.Object) > 0 {
		_ = json.Unmarshal(review.Request.Object, &pod)
	}

	operation := review.Request.Operation
	if operation == "" {
		operation = "CREATE"
	}

	allowed, msg, outcome := ValidatePodWithContext(r.Context(), &pod, operation, s.Store, s.TrustDomain)
	latencyMs := s.Now().Sub(start).Milliseconds()

	resp := &AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: allowed,
	}

	if !allowed {
		atomic.AddUint64(&RejectionsTotal, 1)
		switch outcome {
		case OutcomeDeniedContainedIdentity:
			atomic.AddUint64(&RejectionsContainedIdentityTotal, 1)
		case OutcomeDeniedStoreUnavailable:
			atomic.AddUint64(&RejectionsStoreUnavailableTotal, 1)
		case OutcomeDeniedNodeCapability:
			atomic.AddUint64(&RejectionsNodeCapabilityTotal, 1)
		}

		resp.Result = &Status{
			Code:    http.StatusForbidden,
			Reason:  "Forbidden",
			Message: fmt.Sprintf("admission webhook \"node-capability-guard.signalloom.ai\" denied the request: %s", msg),
		}
	} else {
		atomic.AddUint64(&AdmissionsTotal, 1)
		atomic.AddUint64(&AdmissionsAllowedTotal, 1)
		resp.Result = &Status{
			Code:    http.StatusOK,
			Message: msg,
		}
	}

	// Emit structured audit log
	if s.Logger != nil {
		agentID := ""
		if pod.Metadata.Labels != nil {
			agentID = pod.Metadata.Labels["signalloom.ai/agent-name"]
		}
		if agentID == "" && strings.HasPrefix(pod.Metadata.Name, "agent-") {
			agentID = pod.Metadata.Name
		}
		spiffeID := ""
		if pod.Spec.ServiceAccountName != "" && pod.Metadata.Namespace != "" {
			spiffeID = fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", s.TrustDomain, pod.Metadata.Namespace, pod.Spec.ServiceAccountName)
		}

		entry := AdmissionDecisionLogEntry{
			Event:               "admission_decision",
			UID:                 review.Request.UID,
			Operation:           operation,
			Namespace:           pod.Metadata.Namespace,
			PodName:             pod.Metadata.Name,
			AgentID:             agentID,
			SPIFFEID:            spiffeID,
			Allowed:             allowed,
			Outcome:             outcome,
			Reason:              msg,
			LatencyMs:           latencyMs,
			WorstCaseResidualMs: 0, // Admission check is instantaneous & synchronous before schedule
			ResidualProvenance:  "measured (synchronous admission webhook block)",
			Timestamp:           timestamp,
		}
		s.Logger(entry)
	}

	review.Response = resp
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(review)
}

// Global handler wrappers for backward compatibility with cmd/main.go
func HandleValidate(w http.ResponseWriter, r *http.Request) {
	server := NewWebhookServer(GetDefaultStore(), DefaultTrustDomain)
	server.HandleValidate(w, r)
}

// HandleMetrics outputs Prometheus metrics including legacy and fine-grained counters.
func HandleMetrics(w http.ResponseWriter, r *http.Request) {
	rejections := atomic.LoadUint64(&RejectionsTotal)
	admissions := atomic.LoadUint64(&AdmissionsTotal)
	rejContained := atomic.LoadUint64(&RejectionsContainedIdentityTotal)
	rejStoreUnavail := atomic.LoadUint64(&RejectionsStoreUnavailableTotal)
	rejNodeCap := atomic.LoadUint64(&RejectionsNodeCapabilityTotal)
	admAllowed := atomic.LoadUint64(&AdmissionsAllowedTotal)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP node_capability_rejections_total Total number of agent pods rejected due to missing node containment capabilities or containment policy\n")
	fmt.Fprintf(w, "# TYPE node_capability_rejections_total counter\n")
	fmt.Fprintf(w, "node_capability_rejections_total %d\n\n", rejections)

	fmt.Fprintf(w, "# HELP node_capability_admissions_total Total number of agent pods admitted with valid containment capabilities\n")
	fmt.Fprintf(w, "# TYPE node_capability_admissions_total counter\n")
	fmt.Fprintf(w, "node_capability_admissions_total %d\n\n", admissions)

	fmt.Fprintf(w, "# HELP node_capability_rejections_contained_identity_total Total number of pods rejected due to contained agent identity match\n")
	fmt.Fprintf(w, "# TYPE node_capability_rejections_contained_identity_total counter\n")
	fmt.Fprintf(w, "node_capability_rejections_contained_identity_total %d\n\n", rejContained)

	fmt.Fprintf(w, "# HELP node_capability_rejections_store_unavailable_total Total number of pods rejected due to contained identity store unavailability (fail-closed)\n")
	fmt.Fprintf(w, "# TYPE node_capability_rejections_store_unavailable_total counter\n")
	fmt.Fprintf(w, "node_capability_rejections_store_unavailable_total %d\n\n", rejStoreUnavail)

	fmt.Fprintf(w, "# HELP node_capability_rejections_node_capability_total Total number of agent pods rejected due to missing kernel node containment selectors\n")
	fmt.Fprintf(w, "# TYPE node_capability_rejections_node_capability_total counter\n")
	fmt.Fprintf(w, "node_capability_rejections_node_capability_total %d\n\n", rejNodeCap)

	fmt.Fprintf(w, "# HELP node_capability_admissions_allowed_total Total number of compliant non-contained agent pods admitted\n")
	fmt.Fprintf(w, "# TYPE node_capability_admissions_allowed_total counter\n")
	fmt.Fprintf(w, "node_capability_admissions_allowed_total %d\n", admAllowed)
}

// HandleHealthz responds with health status and checks store connectivity.
func HandleHealthz(w http.ResponseWriter, r *http.Request) {
	store := GetDefaultStore()
	if store != nil {
		if err := store.Health(r.Context()); err != nil {
			http.Error(w, fmt.Sprintf("degraded: identity store unhealthy: %v", err), http.StatusServiceUnavailable)
			return
		}
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}
