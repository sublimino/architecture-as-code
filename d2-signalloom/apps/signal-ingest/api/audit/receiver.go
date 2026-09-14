// Package audit implements the Kubernetes Dynamic Audit Webhook Receiver and GKE Cloud Logging adapter.
package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/transform"
)

// DefaultBufferCapacity is the size of the lock-free audit event ring buffer (64k events).
const DefaultBufferCapacity = 65536

// MaxAuditPayloadBytes limits request body size (16 MB).
const MaxAuditPayloadBytes = 16 * 1024 * 1024

// DefaultWebhookPath is the canonical route for APIServer audit webhooks.
const DefaultWebhookPath = "/api/v1/audit/webhook"

// WebhookPath is the exported stable HTTP path constant for audit webhook route.
const WebhookPath = "/api/v1/audit/webhook"

// GKEWebhookPath is the exported route for GKE Cloud Logging audit records.
const GKEWebhookPath = "/api/v1/audit/gke"

// DefaultTrustDomain is the standard SPIFFE trust domain for cluster service accounts.
const DefaultTrustDomain = "cluster.local"

// K8sEventList mirrors audit.k8s.io/v1 EventList.
type K8sEventList struct {
	Kind       string     `json:"kind"`
	APIVersion string     `json:"apiVersion"`
	Items      []K8sEvent `json:"items"`
}

// K8sEvent mirrors a single audit.k8s.io/v1 Event.
type K8sEvent struct {
	AuditID          string       `json:"auditID"`
	Stage            string       `json:"stage"`
	RequestURI       string       `json:"requestURI"`
	Verb             string       `json:"verb"`
	User             K8sUserInfo  `json:"user"`
	ImpersonatedUser *K8sUserInfo `json:"impersonatedUser,omitempty"`
	SourceIPs        []string     `json:"sourceIPs"`
	UserAgent        string       `json:"userAgent"`
	ObjectRef        *K8sObjRef   `json:"objectRef,omitempty"`
	ResponseStatus   *K8sRespStat `json:"responseStatus,omitempty"`
	StageTimestamp   time.Time    `json:"stageTimestamp"`
	RequestReceived  time.Time    `json:"requestReceivedTimestamp"`
}

// K8sUserInfo represents user identity in audit events.
type K8sUserInfo struct {
	Username string   `json:"username"`
	UID      string   `json:"uid,omitempty"`
	Groups   []string `json:"groups,omitempty"`
}

// K8sObjRef references target Kubernetes resource.
type K8sObjRef struct {
	Resource    string `json:"resource"`
	Namespace   string `json:"namespace,omitempty"`
	Name        string `json:"name,omitempty"`
	APIGroup    string `json:"apiGroup,omitempty"`
	APIVersion  string `json:"apiVersion,omitempty"`
	Subresource string `json:"subresource,omitempty"`
}

// K8sRespStat represents HTTP response status code.
type K8sRespStat struct {
	Code    int32  `json:"code"`
	Status  string `json:"status,omitempty"`
	Message string `json:"message,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// IngestionSink is the consumer interface that receives drained observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// IsServiceAccount returns true if username matches system:serviceaccount:<ns>:<name>.
func IsServiceAccount(username string) bool {
	if !strings.HasPrefix(username, "system:serviceaccount:") {
		return false
	}
	parts := strings.Split(username, ":")
	return len(parts) == 4 && parts[0] == "system" && parts[1] == "serviceaccount" && parts[2] != "" && parts[3] != ""
}

// MapSAToSPIFFE maps system:serviceaccount:<ns>:<name> to spiffe://cluster.local/ns/<ns>/sa/<name>.
// Human or non-service-account usernames are returned unmapped with false.
func MapSAToSPIFFE(username string) (string, bool) {
	if !IsServiceAccount(username) {
		return username, false
	}
	parts := strings.Split(username, ":")
	return fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", DefaultTrustDomain, parts[2], parts[3]), true
}

// WebhookReceiver receives APIServer audit webhooks with non-blocking fail-open resilience.
type WebhookReceiver struct {
	buffer         chan *model.Observation
	sink           IngestionSink
	capacity       int
	receivedCount  uint64
	droppedCount   uint64
	processedCount uint64
	workers        int
	wg             sync.WaitGroup
	ctx            context.Context
	cancel         context.CancelFunc
	closeOnce      sync.Once
	startOnce      sync.Once
}

// NewWebhookReceiver creates a new audit webhook receiver with bounded buffer and worker pool.
func NewWebhookReceiver(ctx context.Context, capacity int, workers int, sink IngestionSink) *WebhookReceiver {
	if capacity <= 0 {
		capacity = DefaultBufferCapacity
	}
	if workers <= 0 {
		workers = 4
	}

	cctx, cancel := context.WithCancel(ctx)
	r := &WebhookReceiver{
		buffer:   make(chan *model.Observation, capacity),
		sink:     sink,
		capacity: capacity,
		workers:  workers,
		ctx:      cctx,
		cancel:   cancel,
	}

	r.Start()
	return r
}

// Start initiates worker goroutines to drain the buffer to the sink.
func (r *WebhookReceiver) Start() {
	r.startOnce.Do(func() {
		for i := 0; i < r.workers; i++ {
			r.wg.Add(1)
			go func() {
				defer r.wg.Done()
				for {
					select {
					case <-r.ctx.Done():
						// Drain any remaining items in buffer before exiting
						for {
							select {
							case obs, ok := <-r.buffer:
								if !ok {
									return
								}
								if r.sink != nil && obs != nil {
									_ = r.sink.IngestObservation(context.Background(), obs)
								}
								atomic.AddUint64(&r.processedCount, 1)
							default:
								return
							}
						}
					case obs, ok := <-r.buffer:
						if !ok {
							return
						}
						if r.sink != nil && obs != nil {
							_ = r.sink.IngestObservation(r.ctx, obs)
						}
						atomic.AddUint64(&r.processedCount, 1)
					}
				}
			}()
		}
	})
}

// Close gracefully terminates receiver workers.
func (r *WebhookReceiver) Close() {
	r.closeOnce.Do(func() {
		r.cancel()
		close(r.buffer)
		r.wg.Wait()
	})
}

// IngestK8sEventList pushes items from a K8sEventList into the bounded buffer fail-open.
func (r *WebhookReceiver) IngestK8sEventList(eventList *K8sEventList) (accepted uint32, dropped uint32) {
	for _, event := range eventList.Items {
		obs := r.ConvertToObservation(&event)
		// Non-blocking fail-open push
		select {
		case r.buffer <- obs:
			atomic.AddUint64(&r.receivedCount, 1)
			accepted++
		default:
			// Buffer saturated: record drop and fail-open to never block APIServer
			atomic.AddUint64(&r.droppedCount, 1)
			dropped++
		}
	}
	return accepted, dropped
}

// HandleAuditWebhook handles incoming HTTP POST requests from Kubernetes APIServer.
func (r *WebhookReceiver) HandleAuditWebhook(w http.ResponseWriter, req *http.Request) {
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

	var eventList K8sEventList
	if err := json.Unmarshal(body, &eventList); err != nil {
		http.Error(w, fmt.Sprintf("Invalid K8s EventList JSON: %v", err), http.StatusBadRequest)
		return
	}

	accepted, dropped := r.IngestK8sEventList(&eventList)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":   "ok",
		"accepted": accepted,
		"dropped":  dropped,
	})
}

// ConvertToObservation maps a K8sEvent to a Signal Loom model.Observation with
// impersonation precedence, SA->SPIFFE mapping, and typed delegation edge.
func (r *WebhookReceiver) ConvertToObservation(e *K8sEvent) *model.Observation {
	ts := e.StageTimestamp
	if ts.IsZero() {
		ts = e.RequestReceived
	}
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	delegatorRaw := e.User.Username
	impersonatedRaw := ""
	if e.ImpersonatedUser != nil && e.ImpersonatedUser.Username != "" {
		impersonatedRaw = e.ImpersonatedUser.Username
	}

	// Acting principal precedence: impersonatedUser ?? user
	actingRaw := delegatorRaw
	isImpersonated := false
	if impersonatedRaw != "" {
		actingRaw = impersonatedRaw
		isImpersonated = true
	}

	// SA->SPIFFE mapping. The is-a-service-account flags previously selected whether to emit a
	// spiffe_id / delegator_spiffe_id label; those labels were removed by SLDP-P3-1 because a
	// SPIFFE ID is a direct identifier and a label becomes a Parquet column in an immutable segment.
	actingPrincipal, _ := MapSAToSPIFFE(actingRaw)
	delegatorPrincipal, _ := MapSAToSPIFFE(delegatorRaw)

	resource := ""
	namespace := ""
	name := ""
	apiGroup := ""
	if e.ObjectRef != nil {
		resource = e.ObjectRef.Resource
		namespace = e.ObjectRef.Namespace
		name = e.ObjectRef.Name
		apiGroup = e.ObjectRef.APIGroup
	}

	statusCode := "0"
	if e.ResponseStatus != nil {
		statusCode = fmt.Sprintf("%d", e.ResponseStatus.Code)
	}

	id := e.AuditID
	if id == "" {
		id = fmt.Sprintf("k8s-audit-%d-%s", ts.UnixNano(), e.Verb)
	}

	// SLDP-P3-1. This map previously carried seven direct identifiers — user, acting_principal,
	// delegator, spiffe_id, delegator_spiffe_id, impersonated_user and delegation — alongside
	// request_uri and user_agent.
	//
	// That mattered more than the static columns did. A label key is materialised verbatim as a
	// Parquet column `labels.<key>` in a signed, immutable segment, so removing identity from
	// actor_hint and impersonated_user while the same strings went on flowing through the label
	// space would have made the whole change cosmetic: the identifiers would simply have arrived
	// by a different column name, and a fixed-column privacy audit would never have looked.
	//
	// Nothing is lost that is not carried better elsewhere. The acting principal travels in
	// ActorHint / PrincipalID and the impersonated subject in ImpersonatedUser, all of which the
	// store now writes as keyed pseudonyms. request_uri is a URI whose components are already
	// present as namespace / resource / name. user_agent is a fingerprinting surface with no
	// consumer here.
	//
	// One genuine loss is recorded rather than papered over: the *delegator* identity has no
	// column of its own, so after this change it survives in the immutable store only through the
	// DelegationEdge contribution string, which is not a segment column. See
	// docs/signalloom/sldp-p3-1-proof.md.
	labels := map[string]string{
		"audit_id":    id,
		"stage":       e.Stage,
		"verb":        e.Verb,
		"namespace":   namespace,
		"resource":    resource,
		"name":        name,
		"api_group":   apiGroup,
		"status_code": statusCode,
	}

	var delegationEdge *model.EvidenceLink
	var impersonatedUserField string
	var delegationDepth int

	// Delegation edge emitted only when impersonatedUser is present and differs from user (no self-edge)
	if isImpersonated && impersonatedRaw != delegatorRaw && actingPrincipal != delegatorPrincipal {
		delegationEdge = &model.EvidenceLink{
			ObservationID: id,
			Layer:         model.LayerIdentityAuth,
			Fidelity:      model.FidelityDefinitive,
			Contribution:  fmt.Sprintf("delegation: %s -> %s (basis: impersonation)", delegatorPrincipal, actingPrincipal),
			Timestamp:     ts,
		}
		impersonatedUserField = actingPrincipal
		delegationDepth = 1

		// The identity half of this (impersonated_user, delegation) moved out of the label space in
		// SLDP-P3-1; only the non-identifying basis remains, so a query can still tell an
		// impersonated request from a direct one without the segment naming anyone.
		labels["delegation_basis"] = "impersonation"
	}

	return &model.Observation{
		ID:               id,
		Timestamp:        ts,
		Layer:            model.LayerIdentityAuth,
		Fidelity:         model.FidelityDefinitive,
		Source:           "k8s-apiserver-audit",
		Confidence:       1.0,
		ActorHint:        actingPrincipal,
		PrincipalID:      actingPrincipal,
		ImpersonatedUser: impersonatedUserField,
		DelegationDepth:  delegationDepth,
		DelegationEdge:   delegationEdge,
		RawEvidenceRef:   fmt.Sprintf("k8s-audit://%s/%s/%s", namespace, resource, name),
		Labels:           labels,
		// `description` is the one free-text column that survives into segment schema v2, and this
		// string interpolated the acting principal directly — so a subject name reached an
		// immutable segment through prose even once every identifier column was pseudonymised.
		//
		// This is also the call site that makes the SLDP-P3-1 redactor patterns real. Before this
		// line, transform.SecretRedactor and transform.CryptographicSecretScrubber had ZERO
		// production callers anywhere in the repository — `rg` for every constructor and method
		// found only their own tests, while eight production sites called store.Append directly.
		// Adding email / IP / username patterns to a redactor nothing invokes would have been a
		// control that cannot fail, which is precisely what this card is required not to ship.
		Description: descriptionRedactor.RedactText(
			fmt.Sprintf("K8s audit: %s %s/%s by %s", e.Verb, namespace, resource, actingPrincipal)),
	}
}

// descriptionRedactor scrubs direct identifiers out of the free-text description before it becomes
// a column in an immutable segment. It is stateless, so one package-level instance is safe to share.
var descriptionRedactor = transform.NewSecretRedactor()

// convertToObservation internal compatibility alias.
func (r *WebhookReceiver) convertToObservation(e *K8sEvent) *model.Observation {
	return r.ConvertToObservation(e)
}

// Metrics returns runtime telemetry counters.
func (r *WebhookReceiver) Metrics() map[string]interface{} {
	return map[string]interface{}{
		"received":  atomic.LoadUint64(&r.receivedCount),
		"dropped":   atomic.LoadUint64(&r.droppedCount),
		"processed": atomic.LoadUint64(&r.processedCount),
		"depth":     len(r.buffer),
		"capacity":  r.capacity,
	}
}
