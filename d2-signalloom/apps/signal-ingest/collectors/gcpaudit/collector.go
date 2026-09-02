// Package gcpaudit implements the GCP Cloud Audit Log streaming collector.
package gcpaudit

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// DefaultDeduplicationTTL is the window to remember insertIds for at-least-once delivery (15 mins).
const DefaultDeduplicationTTL = 15 * time.Minute

// GCPLogEntry mirrors Google Cloud Logging LogEntry JSON.
type GCPLogEntry struct {
	InsertID         string                 `json:"insertId"`
	LogName          string                 `json:"logName"`
	Resource         GCPMonitoredResource   `json:"resource"`
	Timestamp        time.Time              `json:"timestamp"`
	ReceiveTimestamp time.Time              `json:"receiveTimestamp"`
	Severity         string                 `json:"severity"`
	ProtoPayload     *GCPAuditLogPayload    `json:"protoPayload,omitempty"`
	JSONPayload      map[string]interface{} `json:"jsonPayload,omitempty"`
	Labels           map[string]string      `json:"labels,omitempty"`
}

// GCPMonitoredResource describes the monitored GCP resource.
type GCPMonitoredResource struct {
	Type   string            `json:"type"`
	Labels map[string]string `json:"labels"`
}

// GCPAuditLogPayload represents type.googleapis.com/google.cloud.audit.AuditLog.
type GCPAuditLogPayload struct {
	Type                   string                 `json:"@type"`
	ServiceName            string                 `json:"serviceName"`
	MethodName             string                 `json:"methodName"`
	ResourceName           string                 `json:"resourceName"`
	NumResponseItems       int64                  `json:"numResponseItems,omitempty"`
	AuthenticationInfo     GCPAuthInfo            `json:"authenticationInfo"`
	RequestMetadata        GCPRequestMetadata     `json:"requestMetadata"`
	ServiceData            map[string]interface{} `json:"serviceData,omitempty"`
	Status                 *GCPStatus             `json:"status,omitempty"`
	AuthorizationInfo      []GCPAuthzInfo         `json:"authorizationInfo,omitempty"`
}

// GCPAuthInfo identifies the principal executing the call.
type GCPAuthInfo struct {
	PrincipalEmail             string   `json:"principalEmail"`
	AuthoritySelector          string   `json:"authoritySelector,omitempty"`
	ServiceAccountKeyName      string   `json:"serviceAccountKeyName,omitempty"`
	PrincipalSubject           string   `json:"principalSubject,omitempty"`
	ServiceAccountDelegation   []string `json:"serviceAccountDelegationInfo,omitempty"`
}

// GCPRequestMetadata provides network and client context.
type GCPRequestMetadata struct {
	CallerIP                string `json:"callerIp"`
	CallerSuppliedUserAgent string `json:"callerSuppliedUserAgent"`
	CallerNetwork           string `json:"callerNetwork,omitempty"`
}

// GCPStatus indicates RPC result code.
type GCPStatus struct {
	Code    int32  `json:"code"`
	Message string `json:"message"`
}

// GCPAuthzInfo details permissions checked.
type GCPAuthzInfo struct {
	Resource   string `json:"resource"`
	Permission string `json:"permission"`
	Granted    bool   `json:"granted"`
}

// IngestionSink receives converted observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// Collector processes streaming GCP Cloud Audit Logs with insertID deduplication.
type Collector struct {
	sink          IngestionSink
	dedupCache    map[string]time.Time
	dedupMu       sync.RWMutex
	dedupTTL      time.Duration
	receivedCount uint64
	dedupCount    uint64
	ingestedCount uint64
	ctx           context.Context
	cancel        context.CancelFunc
}

// NewCollector instantiates a new GCP Cloud Audit Log streaming collector.
func NewCollector(ctx context.Context, sink IngestionSink, dedupTTL time.Duration) *Collector {
	if dedupTTL <= 0 {
		dedupTTL = DefaultDeduplicationTTL
	}
	cctx, cancel := context.WithCancel(ctx)
	c := &Collector{
		sink:       sink,
		dedupCache: make(map[string]time.Time),
		dedupTTL:   dedupTTL,
		ctx:        cctx,
		cancel:     cancel,
	}

	go c.startEvictionLoop()
	return c
}

// Close gracefully stops the collector.
func (c *Collector) Close() {
	c.cancel()
}

// IngestLogEntry processes a single GCP Cloud Audit LogEntry.
func (c *Collector) IngestLogEntry(ctx context.Context, entry *GCPLogEntry) error {
	atomic.AddUint64(&c.receivedCount, 1)

	if entry.InsertID != "" {
		if c.isDuplicate(entry.InsertID) {
			atomic.AddUint64(&c.dedupCount, 1)
			return nil // Safely ignored as duplicate
		}
		c.recordSeen(entry.InsertID)
	}

	obs := c.convertToObservation(entry)
	if c.sink != nil {
		if err := c.sink.IngestObservation(ctx, obs); err != nil {
			return fmt.Errorf("sink ingestion failed: %w", err)
		}
	}

	atomic.AddUint64(&c.ingestedCount, 1)
	return nil
}

// IngestJSONBytes deserializes raw JSON and processes the LogEntry.
func (c *Collector) IngestJSONBytes(ctx context.Context, raw []byte) error {
	var entry GCPLogEntry
	if err := json.Unmarshal(raw, &entry); err != nil {
		return fmt.Errorf("invalid GCP LogEntry JSON: %w", err)
	}
	return c.IngestLogEntry(ctx, &entry)
}

func (c *Collector) isDuplicate(insertID string) bool {
	c.dedupMu.RLock()
	defer c.dedupMu.RUnlock()
	expiry, exists := c.dedupCache[insertID]
	if !exists {
		return false
	}
	return time.Now().Before(expiry)
}

func (c *Collector) recordSeen(insertID string) {
	c.dedupMu.Lock()
	defer c.dedupMu.Unlock()
	c.dedupCache[insertID] = time.Now().Add(c.dedupTTL)
}

func (c *Collector) startEvictionLoop() {
	ticker := time.NewTicker(2 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			now := time.Now()
			c.dedupMu.Lock()
			for k, expiry := range c.dedupCache {
				if now.After(expiry) {
					delete(c.dedupCache, k)
				}
			}
			c.dedupMu.Unlock()
		}
	}
}

func (c *Collector) convertToObservation(e *GCPLogEntry) *model.Observation {
	ts := e.Timestamp
	if ts.IsZero() {
		ts = e.ReceiveTimestamp
	}
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	serviceName := "unknown"
	methodName := "unknown"
	principal := "unknown"
	callerIP := ""
	resourceName := ""
	statusCode := "0"

	if e.ProtoPayload != nil {
		serviceName = e.ProtoPayload.ServiceName
		methodName = e.ProtoPayload.MethodName
		resourceName = e.ProtoPayload.ResourceName
		principal = e.ProtoPayload.AuthenticationInfo.PrincipalEmail
		if principal == "" {
			principal = e.ProtoPayload.AuthenticationInfo.PrincipalSubject
		}
		callerIP = e.ProtoPayload.RequestMetadata.CallerIP
		if e.ProtoPayload.Status != nil {
			statusCode = fmt.Sprintf("%d", e.ProtoPayload.Status.Code)
		}
	}

	projectID := e.Resource.Labels["project_id"]
	if projectID == "" {
		projectID = e.Labels["project_id"]
	}

	labels := map[string]string{
		"insert_id":       e.InsertID,
		"service_name":    serviceName,
		"method_name":     methodName,
		"resource_name":   resourceName,
		"principal_email": principal,
		"caller_ip":       callerIP,
		"project_id":      projectID,
		"status_code":     statusCode,
		"severity":        e.Severity,
		"log_name":        e.LogName,
	}

	id := e.InsertID
	if id == "" {
		id = fmt.Sprintf("gcp-%d-%s", ts.UnixNano(), methodName)
	}

	return &model.Observation{
		ID:             id,
		Timestamp:      ts,
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityDefinitive,
		Source:         "gcp-cloud-audit",
		Confidence:     1.0,
		ActorHint:      principal,
		RawEvidenceRef: fmt.Sprintf("gcp-audit://%s/%s", projectID, resourceName),
		Labels:         labels,
		Description:    fmt.Sprintf("GCP Audit: %s called %s on %s", principal, methodName, resourceName),
	}
}

// Metrics returns runtime telemetry counters.
func (c *Collector) Metrics() map[string]interface{} {
	c.dedupMu.RLock()
	cacheSize := len(c.dedupCache)
	c.dedupMu.RUnlock()

	return map[string]interface{}{
		"received":   atomic.LoadUint64(&c.receivedCount),
		"dedup_drop": atomic.LoadUint64(&c.dedupCount),
		"ingested":   atomic.LoadUint64(&c.ingestedCount),
		"cache_size": cacheSize,
	}
}
