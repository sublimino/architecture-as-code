package webhook

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
)

// Metrics counters
var (
	RejectionsTotal uint64
	AdmissionsTotal uint64
)

// AdmissionReview mimics standard k8s admission/v1 AdmissionReview
type AdmissionReview struct {
	APIVersion string            `json:"apiVersion,omitempty"`
	Kind       string            `json:"kind,omitempty"`
	Request    *AdmissionRequest  `json:"request,omitempty"`
	Response   *AdmissionResponse `json:"response,omitempty"`
}

type AdmissionRequest struct {
	UID       string          `json:"uid"`
	Kind      GroupVersionKind `json:"kind"`
	Resource  GroupVersionResource `json:"resource"`
	Namespace string          `json:"namespace,omitempty"`
	Name      string          `json:"name,omitempty"`
	Object    json.RawMessage `json:"object,omitempty"`
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

// Minimal Pod definition for inspection
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
	NodeSelector map[string]string `json:"nodeSelector"`
	NodeName     string            `json:"nodeName"`
}

// ValidatePod evaluates kernel containment scheduling rules for an agent pod
func ValidatePod(pod *Pod) (bool, string) {
	if pod == nil {
		return true, ""
	}

	isAgent := false
	if pod.Metadata.Labels != nil {
		if pod.Metadata.Labels["signalloom.ai/agent"] == "true" ||
			pod.Metadata.Labels["signalloom.ai/role"] == "agent" ||
			pod.Metadata.Labels["app.kubernetes.io/component"] == "agent" {
			isAgent = true
		}
	}

	if !isAgent {
		return true, "non-agent pod allowed unconditionally"
	}

	// For agent pods, fail-closed unless node capabilities are explicitly targeted
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
		return false, "agent pod rejected: scheduling requires node with active kernel containment (cgroup-v2=true, landlock=true)"
	}

	return true, "agent pod verified with kernel containment requirements"
}

// HandleValidate handles admission webhook requests
func HandleValidate(w http.ResponseWriter, r *http.Request) {
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

	allowed, msg := ValidatePod(&pod)
	resp := &AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: allowed,
	}

	if !allowed {
		atomic.AddUint64(&RejectionsTotal, 1)
		resp.Result = &Status{
			Code:    http.StatusForbidden,
			Reason:  "Forbidden",
			Message: fmt.Sprintf("admission webhook \"node-capability-guard.signalloom.ai\" denied the request: %s", msg),
		}
	} else {
		atomic.AddUint64(&AdmissionsTotal, 1)
		resp.Result = &Status{
			Code:    http.StatusOK,
			Message: msg,
		}
	}

	review.Response = resp
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(review)
}

// HandleMetrics outputs Prometheus metrics
func HandleMetrics(w http.ResponseWriter, r *http.Request) {
	rejections := atomic.LoadUint64(&RejectionsTotal)
	admissions := atomic.LoadUint64(&AdmissionsTotal)

	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintf(w, "# HELP node_capability_rejections_total Total number of agent pods rejected due to missing node containment capabilities\n")
	fmt.Fprintf(w, "# TYPE node_capability_rejections_total counter\n")
	fmt.Fprintf(w, "node_capability_rejections_total %d\n\n", rejections)
	fmt.Fprintf(w, "# HELP node_capability_admissions_total Total number of agent pods admitted with valid containment capabilities\n")
	fmt.Fprintf(w, "# TYPE node_capability_admissions_total counter\n")
	fmt.Fprintf(w, "node_capability_admissions_total %d\n", admissions)
}

// HandleHealthz responds with health status
func HandleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}
