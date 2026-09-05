// Package audit provides the GKE Cloud Logging adapter for Kubernetes APIServer audit records.
package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// GKELogEntry mirrors a Google Cloud Logging LogEntry JSON record containing a Kubernetes AuditLog.
type GKELogEntry struct {
	InsertID         string                 `json:"insertId,omitempty"`
	LogName          string                 `json:"logName,omitempty"`
	Timestamp        time.Time              `json:"timestamp"`
	ReceiveTimestamp time.Time              `json:"receiveTimestamp,omitempty"`
	Severity         string                 `json:"severity,omitempty"`
	ProtoPayload     *GKEAuditLogPayload    `json:"protoPayload,omitempty"`
	JSONPayload      map[string]interface{} `json:"jsonPayload,omitempty"`
	Resource         *GKEResource           `json:"resource,omitempty"`
	Labels           map[string]string      `json:"labels,omitempty"`
}

// GKEResource describes the monitored GCP resource descriptor.
type GKEResource struct {
	Type   string            `json:"type,omitempty"`
	Labels map[string]string `json:"labels,omitempty"`
}

// GKEAuditLogPayload represents type.googleapis.com/google.cloud.audit.AuditLog from GKE.
type GKEAuditLogPayload struct {
	Type               string                 `json:"@type,omitempty"`
	ServiceName        string                 `json:"serviceName,omitempty"`
	MethodName         string                 `json:"methodName,omitempty"`
	ResourceName       string                 `json:"resourceName,omitempty"`
	AuthenticationInfo GKEAuthInfo            `json:"authenticationInfo"`
	RequestMetadata    *GKERequestMetadata    `json:"requestMetadata,omitempty"`
	Status             *GKEStatus             `json:"status,omitempty"`
	ServiceData        map[string]interface{} `json:"serviceData,omitempty"`
	AuthorizationInfo  []GKEAuthzInfo         `json:"authorizationInfo,omitempty"`
}

// GKEAuthInfo identifies the principal executing the call on GKE.
type GKEAuthInfo struct {
	PrincipalEmail             string   `json:"principalEmail,omitempty"`
	PrincipalSubject           string   `json:"principalSubject,omitempty"`
	AuthoritySelector          string   `json:"authoritySelector,omitempty"`
	ServiceAccountDelegation   []string `json:"serviceAccountDelegationInfo,omitempty"`
	ImpersonatedUser           string   `json:"impersonatedUser,omitempty"`
}

// GKERequestMetadata provides caller network and client information.
type GKERequestMetadata struct {
	CallerIP                string `json:"callerIp,omitempty"`
	CallerSuppliedUserAgent string `json:"callerSuppliedUserAgent,omitempty"`
	CallerNetwork           string `json:"callerNetwork,omitempty"`
}

// GKEStatus indicates the RPC/HTTP status in Cloud Audit.
type GKEStatus struct {
	Code    int32  `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// GKEAuthzInfo describes RBAC authorization checks.
type GKEAuthzInfo struct {
	Resource   string `json:"resource,omitempty"`
	Permission string `json:"permission,omitempty"`
	Granted    bool   `json:"granted,omitempty"`
}

// ExtractVerbFromGKEMethod derives the Kubernetes action verb from a GKE methodName.
// Examples:
//   "io.k8s.core.v1.namespaces.secrets.get" -> "get"
//   "io.k8s.apps.v1.namespaces.deployments.create" -> "create"
//   "create" -> "create"
func ExtractVerbFromGKEMethod(methodName string) string {
	if methodName == "" {
		return "unknown"
	}
	parts := strings.Split(methodName, ".")
	verb := strings.ToLower(parts[len(parts)-1])
	switch verb {
	case "get", "list", "watch", "create", "update", "patch", "delete", "deletecollection":
		return verb
	default:
		return verb
	}
}

// ParseGKEResourceName parses a GKE Kubernetes resourceName into APIGroup, APIVersion, Namespace, Resource, Name.
// Handles formats:
//   "namespaces/default/secrets/vault-token" -> ("", "v1", "default", "secrets", "vault-token")
//   "core/v1/namespaces/default/secrets/vault-token" -> ("", "v1", "default", "secrets", "vault-token")
//   "api/v1/namespaces/default/secrets/vault-token" -> ("", "v1", "default", "secrets", "vault-token")
//   "apis/apps/v1/namespaces/prod/deployments/web" -> ("apps", "v1", "prod", "deployments", "web")
//   "apis/rbac.authorization.k8s.io/v1/clusterroles/admin" -> ("rbac.authorization.k8s.io", "v1", "", "clusterroles", "admin")
//   "secrets/vault-token" -> ("", "v1", "", "secrets", "vault-token")
func ParseGKEResourceName(resourceName string) (apiGroup, apiVersion, namespace, resource, name string) {
	s := strings.TrimPrefix(resourceName, "/")

	// Strip GCP cluster resource prefix if present:
	// "projects/proj/locations/loc/clusters/clust/k8s/..."
	if idx := strings.Index(s, "/k8s/"); idx != -1 {
		s = s[idx+5:]
	}

	parts := strings.Split(s, "/")
	if len(parts) == 0 || s == "" {
		return "", "v1", "", "", ""
	}

	// 1. apis/<group>/<version>/namespaces/<ns>/<resource>/<name> or apis/<group>/<version>/<resource>/<name>
	if parts[0] == "apis" && len(parts) >= 5 {
		apiGroup = parts[1]
		apiVersion = parts[2]
		if parts[3] == "namespaces" && len(parts) >= 7 {
			namespace = parts[4]
			resource = parts[5]
			name = strings.Join(parts[6:], "/")
			return
		}
		// apis/<group>/<version>/<resource>/<name> (cluster-scoped)
		resource = parts[3]
		name = strings.Join(parts[4:], "/")
		return
	}

	// 2. core/<version>/namespaces/<ns>/<resource>/<name> or api/<version>/namespaces/<ns>/...
	if (parts[0] == "core" || parts[0] == "api") && len(parts) >= 5 {
		apiVersion = parts[1]
		if parts[2] == "namespaces" && len(parts) >= 6 {
			namespace = parts[3]
			resource = parts[4]
			name = strings.Join(parts[5:], "/")
			return
		}
		resource = parts[2]
		name = strings.Join(parts[3:], "/")
		return
	}

	// 3. namespaces/<ns>/<resource>/<name>
	if parts[0] == "namespaces" && len(parts) >= 4 {
		apiVersion = "v1"
		namespace = parts[1]
		resource = parts[2]
		name = strings.Join(parts[3:], "/")
		return
	}

	// 4. <resource>/<name> (e.g. "nodes/node-1" or "namespaces/default")
	if len(parts) == 2 {
		apiVersion = "v1"
		resource = parts[0]
		name = parts[1]
		return
	}

	// Fallback
	apiVersion = "v1"
	resource = parts[0]
	if len(parts) > 1 {
		name = strings.Join(parts[1:], "/")
	}
	return
}

// ConvertGKELogEntryToK8sEvent converts a GKE Cloud Logging entry into a canonical K8sEvent.
// This guarantees that both the webhook receiver and GKE adapter share the exact same
// normalization and convertToObservation logic.
func ConvertGKELogEntryToK8sEvent(entry *GKELogEntry) *K8sEvent {
	ts := entry.Timestamp
	if ts.IsZero() {
		ts = entry.ReceiveTimestamp
	}
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	auditID := entry.InsertID
	if auditID == "" {
		auditID = fmt.Sprintf("gke-audit-%d", ts.UnixNano())
	}

	verb := "get"
	principal := "unknown"
	var impersonated *K8sUserInfo
	var objectRef *K8sObjRef
	var respStatus *K8sRespStat
	var sourceIPs []string
	userAgent := ""
	requestURI := ""

	if entry.ProtoPayload != nil {
		p := entry.ProtoPayload
		verb = ExtractVerbFromGKEMethod(p.MethodName)

		// Principal extraction
		if p.AuthenticationInfo.PrincipalEmail != "" {
			principal = p.AuthenticationInfo.PrincipalEmail
		} else if p.AuthenticationInfo.PrincipalSubject != "" {
			principal = p.AuthenticationInfo.PrincipalSubject
		}

		// Impersonation detection
		impersonatedUsername := p.AuthenticationInfo.ImpersonatedUser
		if impersonatedUsername == "" && p.ServiceData != nil {
			if imp, ok := p.ServiceData["impersonatedUser"].(string); ok && imp != "" {
				impersonatedUsername = imp
			} else if impMap, ok := p.ServiceData["impersonatedUser"].(map[string]interface{}); ok {
				if uname, ok := impMap["username"].(string); ok && uname != "" {
					impersonatedUsername = uname
				}
			}
		}
		if impersonatedUsername != "" {
			impersonated = &K8sUserInfo{Username: impersonatedUsername}
		}

		// Resource extraction
		if p.ResourceName != "" {
			apiGroup, apiVer, ns, res, n := ParseGKEResourceName(p.ResourceName)
			objectRef = &K8sObjRef{
				APIGroup:   apiGroup,
				APIVersion: apiVer,
				Namespace:  ns,
				Resource:   res,
				Name:       n,
			}
			if ns != "" {
				requestURI = fmt.Sprintf("/api/%s/namespaces/%s/%s/%s", apiVer, ns, res, n)
			} else {
				requestURI = fmt.Sprintf("/api/%s/%s/%s", apiVer, res, n)
			}
		}

		// Caller metadata
		if p.RequestMetadata != nil {
			if p.RequestMetadata.CallerIP != "" {
				sourceIPs = []string{p.RequestMetadata.CallerIP}
			}
			userAgent = p.RequestMetadata.CallerSuppliedUserAgent
		}

		// Status
		if p.Status != nil {
			respStatus = &K8sRespStat{
				Code:    p.Status.Code,
				Message: p.Status.Message,
			}
		}
	}

	return &K8sEvent{
		AuditID:          auditID,
		Stage:            "ResponseComplete",
		RequestURI:       requestURI,
		Verb:             verb,
		User:             K8sUserInfo{Username: principal},
		ImpersonatedUser: impersonated,
		SourceIPs:        sourceIPs,
		UserAgent:        userAgent,
		ObjectRef:        objectRef,
		ResponseStatus:   respStatus,
		StageTimestamp:   ts,
		RequestReceived:  entry.ReceiveTimestamp,
	}
}

// IngestGKELogEntry processes a single GKE LogEntry through the shared K8sEvent conversion
// and feeds the non-blocking buffer fail-open.
func (r *WebhookReceiver) IngestGKELogEntry(entry *GKELogEntry) bool {
	if entry == nil {
		return false
	}
	k8sEvent := ConvertGKELogEntryToK8sEvent(entry)
	obs := r.ConvertToObservation(k8sEvent)

	select {
	case r.buffer <- obs:
		atomic.AddUint64(&r.receivedCount, 1)
		return true
	default:
		atomic.AddUint64(&r.droppedCount, 1)
		return false
	}
}

// IngestGKEJSONBytes unmarshals raw JSON (single GKELogEntry or array) and pushes to the buffer.
func (r *WebhookReceiver) IngestGKEJSONBytes(ctx context.Context, raw []byte) error {
	// Try single entry first
	var single GKELogEntry
	if err := json.Unmarshal(raw, &single); err == nil && (single.ProtoPayload != nil || single.InsertID != "") {
		r.IngestGKELogEntry(&single)
		return nil
	}

	// Try array of entries
	var entries []GKELogEntry
	if err := json.Unmarshal(raw, &entries); err == nil {
		for i := range entries {
			r.IngestGKELogEntry(&entries[i])
		}
		return nil
	}

	return fmt.Errorf("invalid GKE Cloud Logging JSON payload")
}

// HandleGKECloudLogging handles incoming HTTP POST requests containing GKE Cloud Logging audit records.
func (r *WebhookReceiver) HandleGKECloudLogging(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(req.Body, MaxAuditPayloadBytes))
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to read payload: %v", err), http.StatusBadRequest)
		return
	}
	defer req.Body.Close()

	if err := r.IngestGKEJSONBytes(req.Context(), body); err != nil {
		http.Error(w, fmt.Sprintf("Failed to decode GKE audit JSON: %v", err), http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "ok",
	})
}
