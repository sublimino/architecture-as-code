package telemetry

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	DefaultPollInterval = 2 * time.Second
	FreezeEpsilon       = 0.0001 // 0.1 ms threshold for freeze flatline invariant
	DefaultTTL          = 60 * time.Second
)

// ContainerKey uniquely identifies a container instance.
type ContainerKey struct {
	Namespace string
	Pod       string
	Container string
}

func (k ContainerKey) String() string {
	return fmt.Sprintf("%s/%s/%s", k.Namespace, k.Pod, k.Container)
}

// CadvisorCollector manages scraping Kubelet cAdvisor proxy metrics and computing real-time rates.
type CadvisorCollector struct {
	clientset    kubernetes.Interface
	restClient   rest.Interface
	nodeName     string
	pollInterval time.Duration
	httpClient   *http.Client

	mu             sync.RWMutex
	sampleCache    map[string]MetricSample
	lastSeen       map[string]time.Time
	telemetryCache map[string]AgentTelemetry

	subMu       sync.RWMutex
	subscribers map[string][]chan AgentTelemetry

	// For testing / direct metric injection
	scrapeOverride func(ctx context.Context) ([]byte, error)
}

// NewCadvisorCollector creates a new CadvisorCollector instance.
func NewCadvisorCollector(clientset kubernetes.Interface, restClient rest.Interface, nodeName string, pollInterval time.Duration) *CadvisorCollector {
	if pollInterval <= 0 {
		pollInterval = DefaultPollInterval
	}

	transport := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 10,
		IdleConnTimeout:     90 * time.Second,
		DisableKeepAlives:   false,
	}

	return &CadvisorCollector{
		clientset:      clientset,
		restClient:     restClient,
		nodeName:       nodeName,
		pollInterval:   pollInterval,
		httpClient:     &http.Client{Transport: transport, Timeout: 10 * time.Second},
		sampleCache:    make(map[string]MetricSample),
		lastSeen:       make(map[string]time.Time),
		telemetryCache: make(map[string]AgentTelemetry),
		subscribers:    make(map[string][]chan AgentTelemetry),
	}
}

// SetScrapeOverride allows mocking metric scrapes in tests.
func (c *CadvisorCollector) SetScrapeOverride(fn func(ctx context.Context) ([]byte, error)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.scrapeOverride = fn
}

// ComputeRate calculates CPU consumption in millicores using rate differentials and enforces freeze flatline invariant.
func ComputeRate(curr, prev MetricSample, deltaSec float64) float64 {
	if deltaSec <= 0.0 {
		return 0.0
	}

	deltaCPU := curr.CpuSecondsTotal - prev.CpuSecondsTotal

	// Counter rollover protection on container restart
	if deltaCPU < 0.0 {
		deltaCPU = curr.CpuSecondsTotal
	}

	// Freeze flatline invariant: delta CPU below threshold outputs exact 0.000 mCPU
	if deltaCPU < FreezeEpsilon {
		return 0.0
	}

	return (deltaCPU / deltaSec) * 1000.0
}

// Scrape fetches raw cAdvisor metrics from the Kubelet proxy endpoint.
func (c *CadvisorCollector) Scrape(ctx context.Context) ([]byte, error) {
	c.mu.RLock()
	override := c.scrapeOverride
	c.mu.RUnlock()

	if override != nil {
		return override(ctx)
	}

	if c.restClient != nil {
		path := fmt.Sprintf("/api/v1/nodes/%s/proxy/metrics/cadvisor", c.nodeName)
		return c.restClient.Get().AbsPath(path).DoRaw(ctx)
	}

	if c.clientset != nil && c.clientset.CoreV1() != nil && c.clientset.CoreV1().RESTClient() != nil {
		path := fmt.Sprintf("/api/v1/nodes/%s/proxy/metrics/cadvisor", c.nodeName)
		return c.clientset.CoreV1().RESTClient().Get().AbsPath(path).DoRaw(ctx)
	}

	return nil, fmt.Errorf("no kubernetes REST client configured for cadvisor scrape")
}

// ParsePrometheusMetrics parses Prometheus text exposition and extracts filtered agent samples.
func ParsePrometheusMetrics(data []byte) (map[ContainerKey]MetricSample, error) {
	reader := bytes.NewReader(data)
	var parser expfmt.TextParser
	metricFamilies, err := parser.TextToMetricFamilies(reader)
	if err != nil {
		return nil, fmt.Errorf("failed to parse prometheus metrics: %w", err)
	}

	samples := make(map[ContainerKey]MetricSample)

	// Process CPU usage seconds total
	if cpuFamily, ok := metricFamilies["container_cpu_usage_seconds_total"]; ok {
		for _, m := range cpuFamily.GetMetric() {
			key, ok := extractTargetKey(m)
			if !ok {
				continue
			}

			ts := extractTimestamp(m)
			var cpuVal float64
			if m.GetCounter() != nil {
				cpuVal = m.GetCounter().GetValue()
			} else if m.GetUntyped() != nil {
				cpuVal = m.GetUntyped().GetValue()
			}

			s := samples[key]
			s.Timestamp = ts
			s.CpuSecondsTotal = cpuVal
			samples[key] = s
		}
	}

	// Process Memory RSS
	if memFamily, ok := metricFamilies["container_memory_rss"]; ok {
		for _, m := range memFamily.GetMetric() {
			key, ok := extractTargetKey(m)
			if !ok {
				continue
			}

			var memVal uint64
			if m.GetGauge() != nil {
				memVal = uint64(m.GetGauge().GetValue())
			} else if m.GetUntyped() != nil {
				memVal = uint64(m.GetUntyped().GetValue())
			}

			s := samples[key]
			if s.Timestamp.IsZero() {
				s.Timestamp = extractTimestamp(m)
			}
			s.MemoryRssBytes = memVal
			samples[key] = s
		}
	}

	// Process Throttle count
	if throttleFamily, ok := metricFamilies["container_cpu_cfs_throttled_periods_total"]; ok {
		for _, m := range throttleFamily.GetMetric() {
			key, ok := extractTargetKey(m)
			if !ok {
				continue
			}

			var throttleVal uint64
			if m.GetCounter() != nil {
				throttleVal = uint64(m.GetCounter().GetValue())
			}

			s := samples[key]
			if s.Timestamp.IsZero() {
				s.Timestamp = extractTimestamp(m)
			}
			s.ThrottleCount = throttleVal
			samples[key] = s
		}
	}

	return samples, nil
}

// extractTargetKey filters metrics for agent pods/containers and returns key.
func extractTargetKey(m *dto.Metric) (ContainerKey, bool) {
	var ns, pod, container string
	for _, label := range m.GetLabel() {
		switch label.GetName() {
		case "namespace":
			ns = label.GetValue()
		case "pod":
			pod = label.GetValue()
		case "container":
			container = label.GetValue()
		}
	}

	// Filter out non-agent containers immediately to conserve memory and avoid GC pressure
	if container == "" || container == "POD" {
		return ContainerKey{}, false
	}

	// Targeted filter: container == 'kusari-agent' or namespace == 'fe-signalloom-agents'
	isTargetNamespace := ns == "fe-signalloom-agents"
	isTargetContainer := container == "kusari-agent"
	if !isTargetNamespace && !isTargetContainer {
		return ContainerKey{}, false
	}

	return ContainerKey{
		Namespace: ns,
		Pod:       pod,
		Container: container,
	}, true
}

func extractTimestamp(m *dto.Metric) time.Time {
	if m.TimestampMs != nil && *m.TimestampMs > 0 {
		return time.UnixMilli(*m.TimestampMs)
	}
	return time.Now()
}

// CollectOnce executes a single scrape and rate transformation cycle.
func (c *CadvisorCollector) CollectOnce(ctx context.Context) error {
	raw, err := c.Scrape(ctx)
	if err != nil {
		return fmt.Errorf("scrape cadvisor failed: %w", err)
	}

	samples, err := ParsePrometheusMetrics(raw)
	if err != nil {
		return fmt.Errorf("parse cadvisor metrics failed: %w", err)
	}

	now := time.Now()
	var updates []AgentTelemetry

	c.mu.Lock()
	for key, curr := range samples {
		keyStr := key.String()
		c.lastSeen[keyStr] = now

		prev, hasPrev := c.sampleCache[keyStr]
		var millicores float64
		if hasPrev {
			deltaSec := curr.Timestamp.Sub(prev.Timestamp).Seconds()
			if deltaSec <= 0.0 {
				deltaSec = c.pollInterval.Seconds()
			}
			millicores = ComputeRate(curr, prev, deltaSec)
		} else {
			millicores = 0.0
		}

		c.sampleCache[keyStr] = curr

		memMB := float64(curr.MemoryRssBytes) / (1024.0 * 1024.0)
		status := "ACTIVE"
		if millicores == 0.0 {
			status = "FROZEN"
		}

		telemetry := AgentTelemetry{
			PodName:     key.Pod,
			Namespace:   key.Namespace,
			Millicores:  millicores,
			MemoryRssMB: memMB,
			Status:      status,
			LastUpdated: curr.Timestamp,
		}

		c.telemetryCache[key.Pod] = telemetry
		c.telemetryCache[keyStr] = telemetry
		updates = append(updates, telemetry)
	}

	// TTL eviction for stale containers
	for keyStr, seen := range c.lastSeen {
		if now.Sub(seen) > DefaultTTL {
			delete(c.sampleCache, keyStr)
			delete(c.lastSeen, keyStr)
		}
	}
	c.mu.Unlock()

	// Broadcast updates to active subscribers
	for _, t := range updates {
		c.broadcast(t)
	}

	return nil
}

// Start runs the collector polling loop until context is cancelled.
func (c *CadvisorCollector) Start(ctx context.Context) {
	ticker := time.NewTicker(c.pollInterval)
	defer ticker.Stop()

	// Initial collection on startup
	_ = c.CollectOnce(ctx)

	backoff := 500 * time.Millisecond
	maxBackoff := 8 * time.Second

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := c.CollectOnce(ctx); err != nil {
				time.Sleep(backoff)
				backoff *= 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
			} else {
				backoff = 500 * time.Millisecond
			}
		}
	}
}

// GetLatestTelemetry returns the most recent telemetry for a given pod name.
func (c *CadvisorCollector) GetLatestTelemetry(podName string) (AgentTelemetry, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	t, ok := c.telemetryCache[podName]
	return t, ok
}

// GetAllTelemetry returns snapshot of all current agent telemetry.
func (c *CadvisorCollector) GetAllTelemetry() map[string]AgentTelemetry {
	c.mu.RLock()
	defer c.mu.RUnlock()
	res := make(map[string]AgentTelemetry, len(c.telemetryCache))
	for k, v := range c.telemetryCache {
		res[k] = v
	}
	return res
}

// Subscribe registers a subscriber channel for real-time telemetry updates.
// Returns subscriber channel and an unsubscribe cleanup function.
func (c *CadvisorCollector) Subscribe(podName string) (<-chan AgentTelemetry, func()) {
	ch := make(chan AgentTelemetry, 10)
	c.subMu.Lock()
	c.subscribers[podName] = append(c.subscribers[podName], ch)
	c.subMu.Unlock()

	// If cached telemetry exists, send immediately as initial state
	if initial, ok := c.GetLatestTelemetry(podName); ok {
		select {
		case ch <- initial:
		default:
		}
	}

	unsubscribe := func() {
		c.subMu.Lock()
		defer c.subMu.Unlock()
		subs := c.subscribers[podName]
		for i, sub := range subs {
			if sub == ch {
				c.subscribers[podName] = append(subs[:i], subs[i+1:]...)
				close(ch)
				break
			}
		}
	}

	return ch, unsubscribe
}

// SubscriberCount returns active subscriber count for a pod.
func (c *CadvisorCollector) SubscriberCount(podName string) int {
	c.subMu.RLock()
	defer c.subMu.RUnlock()
	return len(c.subscribers[podName])
}

func (c *CadvisorCollector) broadcast(t AgentTelemetry) {
	c.subMu.RLock()
	defer c.subMu.RUnlock()

	// Broadcast to pod-specific subscribers
	if subs, ok := c.subscribers[t.PodName]; ok {
		for _, ch := range subs {
			select {
			case ch <- t:
			default:
				// Non-blocking drop if subscriber is slow
			}
		}
	}

	// Broadcast to wildcard subscribers
	if subs, ok := c.subscribers["*"]; ok {
		for _, ch := range subs {
			select {
			case ch <- t:
			default:
			}
		}
	}
}
