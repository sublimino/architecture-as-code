// Package gcpaudit implements the GCP Cloud Audit Log streaming collector.
package gcpaudit

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
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
	Type               string                 `json:"@type"`
	ServiceName        string                 `json:"serviceName"`
	MethodName         string                 `json:"methodName"`
	ResourceName       string                 `json:"resourceName"`
	NumResponseItems   int64                  `json:"numResponseItems,omitempty"`
	AuthenticationInfo GCPAuthInfo            `json:"authenticationInfo"`
	RequestMetadata    GCPRequestMetadata     `json:"requestMetadata"`
	ServiceData        map[string]interface{} `json:"serviceData,omitempty"`
	Status             *GCPStatus             `json:"status,omitempty"`
	AuthorizationInfo  []GCPAuthzInfo         `json:"authorizationInfo,omitempty"`
}

// GCPAuthInfo identifies the principal executing the call.
type GCPAuthInfo struct {
	PrincipalEmail           string   `json:"principalEmail"`
	AuthoritySelector        string   `json:"authoritySelector,omitempty"`
	ServiceAccountKeyName    string   `json:"serviceAccountKeyName,omitempty"`
	PrincipalSubject         string   `json:"principalSubject,omitempty"`
	ServiceAccountDelegation []string `json:"serviceAccountDelegationInfo,omitempty"`
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

type pubSubPullRequest struct {
	MaxMessages int `json:"maxMessages"`
}

type pubSubPullResponse struct {
	ReceivedMessages []pubSubReceivedMessage `json:"receivedMessages"`
}

type pubSubReceivedMessage struct {
	AckID   string        `json:"ackId"`
	Message pubSubMessage `json:"message"`
}

type pubSubMessage struct {
	Data        string            `json:"data"`
	Attributes  map[string]string `json:"attributes,omitempty"`
	MessageID   string            `json:"messageId,omitempty"`
	PublishTime string            `json:"publishTime,omitempty"`
}

type pubSubAckRequest struct {
	AckIDs []string `json:"ackIds"`
}

// Collector processes streaming GCP Cloud Audit Logs with insertID deduplication.
type Collector struct {
	sink            IngestionSink
	dedupCache      map[string]time.Time
	dedupMu         sync.RWMutex
	dedupTTL        time.Duration
	receivedCount   uint64
	dedupCount      uint64
	ingestedCount   uint64
	parseErrorCount uint64
	pullErrorCount  uint64
	ctx             context.Context
	cancel          context.CancelFunc
	running         uint32
	wg              sync.WaitGroup

	// Configuration
	mode         string
	projectID    string
	subscription string
	endpoint     string
	pullInterval time.Duration
	httpClient   *http.Client
	pullFn       func(ctx context.Context) error
	ackFn        func(ctx context.Context, ackID string) error
	cannedJSON   []byte
}

// Option configures a Collector instance.
type Option func(*Collector)

// WithMode sets the operational mode ("live", "fixture", "off").
func WithMode(mode string) Option {
	return func(c *Collector) {
		c.mode = mode
	}
}

// WithProject sets the GCP project ID.
func WithProject(project string) Option {
	return func(c *Collector) {
		c.projectID = project
	}
}

// WithSubscription sets the GCP Pub/Sub subscription name.
func WithSubscription(sub string) Option {
	return func(c *Collector) {
		c.subscription = sub
	}
}

// WithEndpoint sets the Pub/Sub REST endpoint URL.
func WithEndpoint(endpoint string) Option {
	return func(c *Collector) {
		c.endpoint = endpoint
	}
}

// WithHTTPClient sets a custom HTTP client.
func WithHTTPClient(client *http.Client) Option {
	return func(c *Collector) {
		c.httpClient = client
	}
}

// WithPullInterval sets the polling interval for Pub/Sub pulls.
func WithPullInterval(interval time.Duration) Option {
	return func(c *Collector) {
		c.pullInterval = interval
	}
}

// WithCannedJSON sets custom canned JSON for fixture mode.
func WithCannedJSON(data []byte) Option {
	return func(c *Collector) {
		c.cannedJSON = data
	}
}

// WithPullFunc sets a custom pull function hook.
func WithPullFunc(fn func(ctx context.Context) error) Option {
	return func(c *Collector) {
		c.pullFn = fn
	}
}

// WithAckFunc sets a custom ack function hook.
func WithAckFunc(fn func(ctx context.Context, ackID string) error) Option {
	return func(c *Collector) {
		c.ackFn = fn
	}
}

// New instantiates a new GCP Cloud Audit Log streaming collector.
func New(ctx context.Context, sink IngestionSink, dedupTTL time.Duration, opts ...Option) *Collector {
	if dedupTTL <= 0 {
		dedupTTL = DefaultDeduplicationTTL
	}
	if ctx == nil {
		ctx = context.Background()
	}
	cctx, cancel := context.WithCancel(ctx)
	c := &Collector{
		sink:          sink,
		dedupCache:   make(map[string]time.Time),
		dedupTTL:     dedupTTL,
		ctx:          cctx,
		cancel:       cancel,
		mode:         resolveMode(),
		projectID:    resolveEnv("GCP_PROJECT_ID", "GCP_PROJECT"),
		subscription: resolveEnv("GCP_AUDIT_SUBSCRIPTION", "GCP_PUBSUB_SUBSCRIPTION", "PUBSUB_SUBSCRIPTION"),
		endpoint:     resolveEnv("GCP_PUBSUB_ENDPOINT", "PUBSUB_EMULATOR_HOST"),
		pullInterval: 500 * time.Millisecond,
		httpClient:   &http.Client{Timeout: 10 * time.Second},
	}

	for _, opt := range opts {
		opt(c)
	}

	go c.startEvictionLoop()
	return c
}

// NewCollector aliases New for backward compatibility.
func NewCollector(ctx context.Context, sink IngestionSink, dedupTTL time.Duration) *Collector {
	return New(ctx, sink, dedupTTL)
}

func resolveMode() string {
	for _, k := range []string{"COLLECTOR_GCPAUDIT_MODE", "SIGNAL_COLLECTOR_GCPAUDIT", "GCPAUDIT_MODE"} {
		if v := os.Getenv(k); v != "" {
			return strings.ToLower(strings.TrimSpace(v))
		}
	}
	return "off"
}

func resolveEnv(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// Name returns the collector identifier.
func (c *Collector) Name() string {
	return "gcpaudit"
}

// Mode returns the collector operational mode.
func (c *Collector) Mode() string {
	return c.mode
}

// Health checks collector health.
func (c *Collector) Health(ctx context.Context) error {
	if c.mode == "off" {
		return nil
	}
	if c.mode == "live" && atomic.LoadUint32(&c.running) == 0 {
		return fmt.Errorf("gcpaudit live collector is not running")
	}
	return nil
}

// Start initiates the collector based on its operational mode.
// In live mode: starts non-blocking Pub/Sub pull subscriber loop in a goroutine.
// In fixture mode: replays canned GCP LogEntry.
// In off mode: returns nil.
func (c *Collector) Start(ctx context.Context) error {
	if !atomic.CompareAndSwapUint32(&c.running, 0, 1) {
		return nil // already running
	}

	switch strings.ToLower(strings.TrimSpace(c.mode)) {
	case "off", "":
		return nil

	case "fixture":
		canned := c.cannedJSON
		if len(canned) == 0 {
			canned = CannedLogEntryJSON()
		}
		if err := c.IngestJSONBytes(ctx, canned); err != nil {
			return fmt.Errorf("failed to replay fixture gcp audit event: %w", err)
		}
		return nil

	case "live":
		c.wg.Add(1)
		go c.pullLoop()
		return nil

	default:
		return fmt.Errorf("unknown gcpaudit mode: %s", c.mode)
	}
}

// Close gracefully stops the collector.
func (c *Collector) Close() {
	if atomic.CompareAndSwapUint32(&c.running, 1, 0) {
		c.cancel()
		c.wg.Wait()
	} else {
		c.cancel()
	}
}

// Stop halts the collector.
func (c *Collector) Stop() {
	c.Close()
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
		atomic.AddUint64(&c.parseErrorCount, 1)
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

func (c *Collector) pullLoop() {
	defer c.wg.Done()

	ticker := time.NewTicker(c.pullInterval)
	defer ticker.Stop()

	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			if c.pullFn != nil {
				if err := c.pullFn(c.ctx); err != nil {
					atomic.AddUint64(&c.pullErrorCount, 1)
					slog.Debug("gcpaudit pull function error", "error", err)
				}
				continue
			}

			if c.subscription == "" {
				continue
			}

			if _, err := c.PullOnce(c.ctx); err != nil {
				atomic.AddUint64(&c.pullErrorCount, 1)
				slog.Debug("gcpaudit pull error", "subscription", c.subscription, "error", err)
			}
		}
	}
}

func (c *Collector) buildURL(action string) string {
	base := c.endpoint
	if base == "" {
		base = "https://pubsub.googleapis.com"
	}
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "https://" + base
	}
	base = strings.TrimRight(base, "/")

	sub := c.subscription
	if strings.HasPrefix(sub, "projects/") {
		return fmt.Sprintf("%s/v1/%s:%s", base, sub, action)
	}
	proj := c.projectID
	if proj == "" {
		proj = "default"
	}
	return fmt.Sprintf("%s/v1/projects/%s/subscriptions/%s:%s", base, proj, sub, action)
}

// PullOnce executes a single pull from the Pub/Sub subscription, processes and ingests
// valid messages, and acknowledges them upon successful ingestion.
func (c *Collector) PullOnce(ctx context.Context) (int, error) {
	if c.subscription == "" {
		return 0, fmt.Errorf("no pubsub subscription configured")
	}

	pullURL := c.buildURL("pull")
	reqBody, err := json.Marshal(pubSubPullRequest{MaxMessages: 10})
	if err != nil {
		return 0, fmt.Errorf("marshal pull request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, pullURL, bytes.NewReader(reqBody))
	if err != nil {
		return 0, fmt.Errorf("create pull request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token := resolveEnv("GCP_AUTH_TOKEN", "GCP_ACCESS_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("pubsub pull request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("pubsub pull returned status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var pullResp pubSubPullResponse
	if err := json.NewDecoder(resp.Body).Decode(&pullResp); err != nil {
		atomic.AddUint64(&c.parseErrorCount, 1)
		return 0, fmt.Errorf("failed to decode pubsub pull response: %w", err)
	}

	var ackIDs []string
	processedCount := 0

	for _, msg := range pullResp.ReceivedMessages {
		if msg.Message.Data == "" {
			atomic.AddUint64(&c.parseErrorCount, 1)
			continue
		}

		var payload []byte
		decoded, err := base64.StdEncoding.DecodeString(msg.Message.Data)
		if err == nil && len(decoded) > 0 {
			payload = decoded
		} else {
			payload = []byte(msg.Message.Data)
		}

		if err := c.IngestJSONBytes(ctx, payload); err != nil {
			// IngestJSONBytes incremented parseErrorCount if invalid JSON.
			// Do NOT acknowledge unparsed or failed messages.
			continue
		}

		if msg.AckID != "" {
			ackIDs = append(ackIDs, msg.AckID)
		}
		processedCount++
	}

	if len(ackIDs) > 0 {
		if err := c.AcknowledgeMessages(ctx, ackIDs); err != nil {
			slog.Warn("failed to acknowledge pubsub messages", "error", err, "count", len(ackIDs))
			return processedCount, fmt.Errorf("acknowledge messages failed: %w", err)
		}
	}

	return processedCount, nil
}

// AcknowledgeMessages sends an acknowledgement request for the specified ack IDs.
func (c *Collector) AcknowledgeMessages(ctx context.Context, ackIDs []string) error {
	if len(ackIDs) == 0 {
		return nil
	}
	if c.ackFn != nil {
		for _, id := range ackIDs {
			if err := c.ackFn(ctx, id); err != nil {
				return err
			}
		}
		return nil
	}

	ackURL := c.buildURL("acknowledge")
	reqBody, err := json.Marshal(pubSubAckRequest{AckIDs: ackIDs})
	if err != nil {
		return fmt.Errorf("marshal ack request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ackURL, bytes.NewReader(reqBody))
	if err != nil {
		return fmt.Errorf("create ack request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token := resolveEnv("GCP_AUTH_TOKEN", "GCP_ACCESS_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("pubsub acknowledge request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("pubsub acknowledge returned status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	return nil
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

// CannedLogEntryJSON returns a valid raw JSON representation of a GCP Cloud Audit LogEntry.
func CannedLogEntryJSON() []byte {
	return []byte(`{
		"insertId": "gcp-audit-canned-001",
		"logName": "projects/osramp-demo/logs/cloudaudit.googleapis.com%2Factivity",
		"timestamp": "2026-09-05T12:00:00Z",
		"severity": "NOTICE",
		"resource": {
			"type": "project",
			"labels": {
				"project_id": "osramp-demo"
			}
		},
		"protoPayload": {
			"@type": "type.googleapis.com/google.cloud.audit.AuditLog",
			"serviceName": "iam.googleapis.com",
			"methodName": "google.iam.admin.v1.CreateRole",
			"resourceName": "projects/osramp-demo/roles/custom.agentRunner",
			"authenticationInfo": {
				"principalEmail": "security-admin@controlplane.io"
			},
			"requestMetadata": {
				"callerIp": "198.51.100.42",
				"callerSuppliedUserAgent": "google-cloud-sdk"
			}
		}
	}`)
}

// Metrics returns runtime telemetry counters.
func (c *Collector) Metrics() map[string]interface{} {
	c.dedupMu.RLock()
	cacheSize := len(c.dedupCache)
	c.dedupMu.RUnlock()

	return map[string]interface{}{
		"received":     atomic.LoadUint64(&c.receivedCount),
		"dedup_drop":   atomic.LoadUint64(&c.dedupCount),
		"ingested":     atomic.LoadUint64(&c.ingestedCount),
		"parse_errors": atomic.LoadUint64(&c.parseErrorCount),
		"pull_errors":  atomic.LoadUint64(&c.pullErrorCount),
		"cache_size":   cacheSize,
	}
}

