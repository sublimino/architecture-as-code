package telemetry

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestComputeRate_IdleDeltas(t *testing.T) {
	prev := MetricSample{
		Timestamp:       time.Unix(1000, 0),
		CpuSecondsTotal: 50.123456,
		MemoryRssBytes:  100 * 1024 * 1024,
	}
	// Tiny delta below FreezeEpsilon (0.0001s)
	curr := MetricSample{
		Timestamp:       time.Unix(1002, 0),
		CpuSecondsTotal: 50.123480, // delta = 0.000024 < 0.0001
		MemoryRssBytes:  100 * 1024 * 1024,
	}

	rate := ComputeRate(curr, prev, 2.0)
	if rate != 0.0 {
		t.Fatalf("expected exact 0.000 mCPU for idle/sub-epsilon delta, got %f", rate)
	}
}

func TestComputeRate_ActiveLoadSpike(t *testing.T) {
	prev := MetricSample{
		Timestamp:       time.Unix(1000, 0),
		CpuSecondsTotal: 10.0,
		MemoryRssBytes:  64 * 1024 * 1024,
	}
	curr := MetricSample{
		Timestamp:       time.Unix(1002, 0),
		CpuSecondsTotal: 10.2, // delta = 0.2s
		MemoryRssBytes:  64 * 1024 * 1024,
	}

	rate := ComputeRate(curr, prev, 2.0)
	expectedRate := 100.0 // (0.2 / 2.0) * 1000 = 100 mCPU
	if math.Abs(rate-expectedRate) > 0.001 {
		t.Fatalf("expected rate %f mCPU, got %f", expectedRate, rate)
	}
}

func TestComputeRate_ZeroDelta_FrozenPod(t *testing.T) {
	prev := MetricSample{
		Timestamp:       time.Unix(1000, 0),
		CpuSecondsTotal: 42.0,
		MemoryRssBytes:  128 * 1024 * 1024,
	}
	curr := MetricSample{
		Timestamp:       time.Unix(1002, 0),
		CpuSecondsTotal: 42.0, // delta = 0.0s
		MemoryRssBytes:  128 * 1024 * 1024,
	}

	rate := ComputeRate(curr, prev, 2.0)
	if rate != 0.0 {
		t.Fatalf("expected exact 0.000 mCPU for frozen pod, got %f", rate)
	}
}

func TestComputeRate_ContainerRestartRollover(t *testing.T) {
	prev := MetricSample{
		Timestamp:       time.Unix(1000, 0),
		CpuSecondsTotal: 125.5,
		MemoryRssBytes:  64 * 1024 * 1024,
	}
	// Container restarted, counter reset to 0.4s
	curr := MetricSample{
		Timestamp:       time.Unix(1002, 0),
		CpuSecondsTotal: 0.4,
		MemoryRssBytes:  64 * 1024 * 1024,
	}

	rate := ComputeRate(curr, prev, 2.0)
	expectedRate := (0.4 / 2.0) * 1000.0 // 200 mCPU
	if math.Abs(rate-expectedRate) > 0.001 {
		t.Fatalf("expected rate %f mCPU on rollover, got %f", expectedRate, rate)
	}
	if rate < 0.0 {
		t.Fatalf("rate must never be negative, got %f", rate)
	}
}

func TestComputeRate_ZeroOrNegativeDeltaSec(t *testing.T) {
	prev := MetricSample{CpuSecondsTotal: 10.0}
	curr := MetricSample{CpuSecondsTotal: 12.0}

	rateZero := ComputeRate(curr, prev, 0.0)
	if rateZero != 0.0 || math.IsNaN(rateZero) || math.IsInf(rateZero, 0) {
		t.Fatalf("expected 0.0 on deltaSec=0, got %f", rateZero)
	}

	rateNeg := ComputeRate(curr, prev, -2.0)
	if rateNeg != 0.0 || math.IsNaN(rateNeg) || math.IsInf(rateNeg, 0) {
		t.Fatalf("expected 0.0 on deltaSec<0, got %f", rateNeg)
	}
}

const samplePromData = `# HELP container_cpu_usage_seconds_total Cumulative cpu time consumed in seconds.
# TYPE container_cpu_usage_seconds_total counter
container_cpu_usage_seconds_total{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 12.345 1790755040000
container_cpu_usage_seconds_total{container="POD",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 0.001 1790755040000
container_cpu_usage_seconds_total{container="",namespace="kube-system",pod="kube-proxy-abcde"} 45.678 1790755040000
# HELP container_memory_rss Size of RSS in bytes.
# TYPE container_memory_rss gauge
container_memory_rss{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 104857600 1790755040000
# HELP container_cpu_cfs_throttled_periods_total Number of throttled period intervals.
# TYPE container_cpu_cfs_throttled_periods_total counter
container_cpu_cfs_throttled_periods_total{container="kusari-agent",namespace="fe-signalloom-agents",pod="kusari-agent-77d9c-abcde"} 3 1790755040000
`

func TestParsePrometheusMetrics(t *testing.T) {
	samples, err := ParsePrometheusMetrics([]byte(samplePromData))
	if err != nil {
		t.Fatalf("ParsePrometheusMetrics failed: %v", err)
	}

	targetKey := ContainerKey{
		Namespace: "fe-signalloom-agents",
		Pod:       "kusari-agent-77d9c-abcde",
		Container: "kusari-agent",
	}

	s, ok := samples[targetKey]
	if !ok {
		t.Fatalf("expected sample for key %s, found none", targetKey)
	}

	if math.Abs(s.CpuSecondsTotal-12.345) > 0.0001 {
		t.Errorf("expected CpuSecondsTotal 12.345, got %f", s.CpuSecondsTotal)
	}
	if s.MemoryRssBytes != 104857600 {
		t.Errorf("expected MemoryRssBytes 104857600, got %d", s.MemoryRssBytes)
	}
	if s.ThrottleCount != 3 {
		t.Errorf("expected ThrottleCount 3, got %d", s.ThrottleCount)
	}

	// Verify non-agent / POD containers were discarded
	for k := range samples {
		if k.Container == "POD" || k.Container == "" || k.Namespace == "kube-system" {
			t.Errorf("non-agent container was not discarded: %+v", k)
		}
	}
}

func TestCadvisorCollector_EndToEndCollection(t *testing.T) {
	collector := NewCadvisorCollector(nil, nil, "test-node", 2*time.Second)

	// Step 1: First scrape
	collector.SetScrapeOverride(func(ctx context.Context) ([]byte, error) {
		return []byte(samplePromData), nil
	})

	err := collector.CollectOnce(context.Background())
	if err != nil {
		t.Fatalf("first CollectOnce failed: %v", err)
	}

	telemetry, ok := collector.GetLatestTelemetry("kusari-agent-77d9c-abcde")
	if !ok {
		t.Fatalf("expected telemetry for pod kusari-agent-77d9c-abcde")
	}
	if telemetry.Millicores != 0.0 {
		t.Errorf("first sample rate should be 0.0, got %f", telemetry.Millicores)
	}
	if math.Abs(telemetry.MemoryRssMB-100.0) > 0.01 { // 104857600 / 1024 / 1024 = 100 MB
		t.Errorf("expected MemoryRssMB ~100.0, got %f", telemetry.MemoryRssMB)
	}

	// Step 2: Second scrape with CPU increase (0.2s increase over 2s = 100 mCPU)
	samplePromData2 := strings.Replace(samplePromData, "12.345", "12.545", 1)
	samplePromData2 = strings.Replace(samplePromData2, "1790755040000", "1790755042000", -1)

	collector.SetScrapeOverride(func(ctx context.Context) ([]byte, error) {
		return []byte(samplePromData2), nil
	})

	err = collector.CollectOnce(context.Background())
	if err != nil {
		t.Fatalf("second CollectOnce failed: %v", err)
	}

	telemetry2, ok := collector.GetLatestTelemetry("kusari-agent-77d9c-abcde")
	if !ok {
		t.Fatalf("expected telemetry for pod kusari-agent-77d9c-abcde on second scrape")
	}
	if math.Abs(telemetry2.Millicores-100.0) > 0.1 {
		t.Errorf("expected Millicores ~100.0, got %f", telemetry2.Millicores)
	}
	if telemetry2.Status != "ACTIVE" {
		t.Errorf("expected Status ACTIVE, got %s", telemetry2.Status)
	}

	// Step 3: Third scrape frozen (0 delta)
	samplePromData3 := strings.Replace(samplePromData2, "1790755042000", "1790755044000", -1)
	collector.SetScrapeOverride(func(ctx context.Context) ([]byte, error) {
		return []byte(samplePromData3), nil
	})

	err = collector.CollectOnce(context.Background())
	if err != nil {
		t.Fatalf("third CollectOnce failed: %v", err)
	}

	telemetry3, _ := collector.GetLatestTelemetry("kusari-agent-77d9c-abcde")
	if telemetry3.Millicores != 0.0 {
		t.Errorf("expected Millicores exactly 0.0 for frozen pod, got %f", telemetry3.Millicores)
	}
	if telemetry3.Status != "FROZEN" {
		t.Errorf("expected Status FROZEN for zero CPU rate, got %s", telemetry3.Status)
	}
}

func TestTelemetryHandler_RESTAndSSE(t *testing.T) {
	collector := NewCadvisorCollector(nil, nil, "test-node", 2*time.Second)
	collector.SetScrapeOverride(func(ctx context.Context) ([]byte, error) {
		return []byte(samplePromData), nil
	})
	_ = collector.CollectOnce(context.Background())

	handler := NewTelemetryHandler(collector)
	mux := http.NewServeMux()
	handler.RegisterRoutes(mux)

	// Test 1: JSON GET
	req := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/agents/kusari-agent-77d9c-abcde", nil)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var resp AgentTelemetry
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode JSON response: %v", err)
	}
	if resp.PodName != "kusari-agent-77d9c-abcde" {
		t.Errorf("expected PodName kusari-agent-77d9c-abcde, got %s", resp.PodName)
	}

	// Test 2: SSE subscription and unsubscribe on disconnect
	podName := "kusari-agent-77d9c-abcde"
	ctx, cancel := context.WithCancel(context.Background())
	sseReq := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/agents/"+podName+"?stream=true", nil).WithContext(ctx)
	sseReq.Header.Set("Accept", "text/event-stream")

	sseRec := httptest.NewRecorder()

	go func() {
		mux.ServeHTTP(sseRec, sseReq)
	}()

	time.Sleep(50 * time.Millisecond)
	if collector.SubscriberCount(podName) != 1 {
		t.Errorf("expected subscriber count 1, got %d", collector.SubscriberCount(podName))
	}

	// Cancel context to simulate browser disconnect
	cancel()
	time.Sleep(50 * time.Millisecond)

	if collector.SubscriberCount(podName) != 0 {
		t.Errorf("expected subscriber count 0 after disconnect, got %d", collector.SubscriberCount(podName))
	}
}

func BenchmarkComputeRate(b *testing.B) {
	prev := MetricSample{
		Timestamp:       time.Unix(1000, 0),
		CpuSecondsTotal: 10.0,
		MemoryRssBytes:  64 * 1024 * 1024,
	}
	curr := MetricSample{
		Timestamp:       time.Unix(1002, 0),
		CpuSecondsTotal: 10.2,
		MemoryRssBytes:  64 * 1024 * 1024,
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeRate(curr, prev, 2.0)
	}
}

func BenchmarkParsePrometheusMetrics(b *testing.B) {
	data := []byte(samplePromData)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = ParsePrometheusMetrics(data)
	}
}
