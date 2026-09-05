// Package audit implements the Kubernetes Dynamic Audit Webhook Receiver.
package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultBufferCapacity is the size of the lock-free audit event ring buffer (64k events).
const DefaultBufferCapacity = 65536

// MaxAuditPayloadBytes limits request body size (16 MB).
const MaxAuditPayloadBytes = 16 * 1024 * 1024

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
	UID      string   `json:"uid"`
	Groups   []string `json:"groups"`
}

// K8sObjRef references target Kubernetes resource.
type K8sObjRef struct {
	Resource    string `json:"resource"`
	Namespace   string `json:"namespace"`
	Name        string `json:"name"`
	APIGroup    string `json:"apiGroup"`
	APIVersion  string `json:"apiVersion"`
	Subresource string `json:"subresource,omitempty"`
}

// K8sRespStat represents HTTP response status code.
type K8sRespStat struct {
	Code    int32  `json:"code"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// IngestionSink is the consumer interface that receives drained observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
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

	r.startWorkers()
	return r
}

func (r *WebhookReceiver) startWorkers() {
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
}

// Close gracefully terminates receiver workers.
func (r *WebhookReceiver) Close() {
	r.closeOnce.Do(func() {
		r.cancel()
		close(r.buffer)
		r.wg.Wait()
	})
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

	var accepted uint32
	var dropped uint32

	for _, event := range eventList.Items {
		obs := r.convertToObservation(&event)
		
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

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":   "ok",
		"accepted": accepted,
		"dropped":  dropped,
	})
}

// convertToObservation maps a K8sEvent to a Signal Loom model.Observation.
func (r *WebhookReceiver) convertToObservation(e *K8sEvent) *model.Observation {
	ts := e.StageTimestamp
	if ts.IsZero() {
		ts = e.RequestReceived
	}
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

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

	labels := map[string]string{
		"audit_id":    e.AuditID,
		"stage":       e.Stage,
		"verb":        e.Verb,
		"user":        e.User.Username,
		"namespace":   namespace,
		"resource":    resource,
		"name":        name,
		"api_group":   apiGroup,
		"status_code": statusCode,
		"request_uri": e.RequestURI,
		"user_agent":  e.UserAgent,
	}

	return &model.Observation{
		ID:             e.AuditID,
		Timestamp:      ts,
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityDefinitive,
		Source:         "k8s-apiserver-audit",
		Confidence:     1.0,
		ActorHint:      e.User.Username,
		RawEvidenceRef: fmt.Sprintf("k8s-audit://%s/%s/%s", namespace, resource, name),
		Labels:         labels,
		Description:    fmt.Sprintf("K8s audit: %s %s/%s by %s", e.Verb, namespace, resource, e.User.Username),
	}
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
