package telemetry

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"net/http"
	"strings"
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
	// DefaultStaleAfter: no successful scrape for this long and the API answers
	// 503 rather than presenting old numbers as current.
	DefaultStaleAfter = 15 * time.Second
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

	mu sync.RWMutex
	// containers: per container, the baseline sample and the last honest rate.
	containers map[string]containerState
	lastSeen   map[string]time.Time
	// telemetryCache: per pod, keyed "namespace/pod".
	telemetryCache map[string]AgentTelemetry
	lastSuccess    time.Time
	lastErr        error
	staleAfter     time.Duration
	now            func() time.Time

	subMu       sync.RWMutex
	subscribers map[string][]chan AgentTelemetry

	// For testing / direct metric injection
	scrapeOverride func(ctx context.Context) ([]byte, error)
}

type containerState struct {
	sample  MetricSample
	rate    float64
	hasRate bool
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
		containers:     make(map[string]containerState),
		lastSeen:       make(map[string]time.Time),
		telemetryCache: make(map[string]AgentTelemetry),
		staleAfter:     DefaultStaleAfter,
		now:            time.Now,
		subscribers:    make(map[string][]chan AgentTelemetry),
	}
}

// SetScrapeOverride allows mocking metric scrapes in tests.
func (c *CadvisorCollector) SetScrapeOverride(fn func(ctx context.Context) ([]byte, error)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.scrapeOverride = fn
}

// ComputeRate calculates CPU consumption in millicores and enforces the freeze
// flatline invariant. ok is false when the samples cannot honestly yield a
// rate - no elapsed time, a clock running backwards, a non-finite or negative
// counter - which is "no reading", never 0.000.
func ComputeRate(curr, prev MetricSample, deltaSec float64) (millicores float64, ok bool) {
	for _, v := range []float64{curr.CpuSecondsTotal, prev.CpuSecondsTotal, deltaSec} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return 0, false
		}
	}
	if deltaSec <= 0.0 || curr.CpuSecondsTotal < 0.0 || prev.CpuSecondsTotal < 0.0 {
		return 0, false
	}

	deltaCPU := curr.CpuSecondsTotal - prev.CpuSecondsTotal

	// Counter rollover protection on container restart
	if deltaCPU < 0.0 {
		deltaCPU = curr.CpuSecondsTotal
	}

	// Freeze flatline invariant: delta CPU below threshold outputs exact 0.000 mCPU
	if deltaCPU < FreezeEpsilon {
		return 0.0, true
	}

	return (deltaCPU / deltaSec) * 1000.0, true
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

	sampleCount := 0
	for _, family := range metricFamilies {
		sampleCount += len(family.GetMetric())
	}
	if sampleCount == 0 {
		return nil, fmt.Errorf("cadvisor body carried no Prometheus samples")
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
			} else {
				continue
			}
			if math.IsNaN(cpuVal) || math.IsInf(cpuVal, 0) || cpuVal < 0 {
				continue
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

			s, hasCPU := samples[key]
			if !hasCPU {
				continue
			}
			var memVal uint64
			if m.GetGauge() != nil {
				memVal = uint64(m.GetGauge().GetValue())
			} else if m.GetUntyped() != nil {
				memVal = uint64(m.GetUntyped().GetValue())
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

			s, hasCPU := samples[key]
			if !hasCPU {
				continue
			}
			var throttleVal uint64
			if m.GetCounter() != nil {
				throttleVal = uint64(m.GetCounter().GetValue())
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
	samples, err := c.scrapeAndParse(ctx)
	if err != nil {
		c.mu.Lock()
		c.lastErr = err
		c.mu.Unlock()
		return err
	}

	c.mu.Lock()
	now := c.now()
	type podKey struct{ ns, pod string }
	type part struct {
		sample  MetricSample
		rate    float64
		hasRate bool
	}
	pods := make(map[podKey][]part)
	for key, curr := range samples {
		keyStr := key.String()
		c.lastSeen[keyStr] = now
		prev, seen := c.containers[keyStr]
		var st containerState
		switch {
		case !seen:
			st = containerState{sample: curr}
		case curr.Timestamp.Equal(prev.sample.Timestamp):
			// cAdvisor has not re-sampled (it refreshes every ~15 s): no new
			// information, so the previous rate stands and so does the baseline.
			st = prev
		default:
			rate, ok := ComputeRate(curr, prev.sample, curr.Timestamp.Sub(prev.sample.Timestamp).Seconds())
			st = containerState{sample: curr, rate: rate, hasRate: ok}
		}
		c.containers[keyStr] = st
		pk := podKey{key.Namespace, key.Pod}
		pods[pk] = append(pods[pk], part{curr, st.rate, st.hasRate})
	}

	var updates []AgentTelemetry
	for pk, parts := range pods {
		var sum float64
		var rss uint64
		complete := true
		latest := parts[0].sample.Timestamp
		for _, p := range parts {
			complete = complete && p.hasRate
			sum += p.rate
			rss += p.sample.MemoryRssBytes
			if p.sample.Timestamp.After(latest) {
				latest = p.sample.Timestamp
			}
		}
		t := AgentTelemetry{
			PodName:     pk.pod,
			Namespace:   pk.ns,
			MemoryRssMB: float64(rss) / (1024.0 * 1024.0),
			Status:      "PENDING",
			LastUpdated: latest,
		}
		if complete {
			mc := sum
			t.Millicores = &mc
			t.Status = "ACTIVE"
			if mc == 0 {
				*t.Millicores = 0 // never -0
				t.Status = "FROZEN"
			}
		}
		c.telemetryCache[pk.ns+"/"+pk.pod] = t
		updates = append(updates, t)
	}

	// TTL eviction for stale containers, then for pods with no live container.
	livePods := make(map[string]bool)
	for keyStr, seen := range c.lastSeen {
		if now.Sub(seen) > DefaultTTL {
			delete(c.containers, keyStr)
			delete(c.lastSeen, keyStr)
			continue
		}
		livePods[keyStr[:strings.LastIndex(keyStr, "/")]] = true
	}
	for podKeyStr := range c.telemetryCache {
		if !livePods[podKeyStr] {
			delete(c.telemetryCache, podKeyStr)
		}
	}
	c.lastSuccess = now
	c.lastErr = nil
	c.mu.Unlock()

	// Broadcast updates to active subscribers
	for _, t := range updates {
		c.broadcast(t)
	}

	return nil
}

func (c *CadvisorCollector) scrapeAndParse(ctx context.Context) (map[ContainerKey]MetricSample, error) {
	raw, err := c.Scrape(ctx)
	if err != nil {
		return nil, fmt.Errorf("scrape cadvisor failed: %w", err)
	}
	samples, err := ParsePrometheusMetrics(raw)
	if err != nil {
		return nil, fmt.Errorf("parse cadvisor metrics failed: %w", err)
	}
	return samples, nil
}

// Healthy reports whether a scrape succeeded recently enough that the cache
// describes the present.
func (c *CadvisorCollector) Healthy() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return !c.lastSuccess.IsZero() && c.now().Sub(c.lastSuccess) <= c.staleAfter
}

// LastError is the most recent scrape failure, nil after a success.
func (c *CadvisorCollector) LastError() error {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.lastErr
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
				select {
				case <-ctx.Done():
					return
				case <-time.After(backoff):
				}
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

// FindTelemetry returns the telemetry of every monitored pod with this name,
// across namespaces.
func (c *CadvisorCollector) FindTelemetry(podName string) []AgentTelemetry {
	c.mu.RLock()
	defer c.mu.RUnlock()
	var res []AgentTelemetry
	for _, t := range c.telemetryCache {
		if t.PodName == podName {
			res = append(res, t)
		}
	}
	return res
}

// GetAllTelemetry returns a snapshot of all current agent telemetry, keyed "namespace/pod".
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
	for _, initial := range c.FindTelemetry(podName) {
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
