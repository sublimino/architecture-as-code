package telemetry

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The rule these tests defend: 0.000 mCPU / FROZEN only when two distinct
// cAdvisor samples show no CPU work. A first sample, a repeated sample, an
// upstream failure or an unknown pod must never read as a freeze.

const (
	testNS  = "fe-signalloom-agents"
	testPod = "kusari-agent-77d9c-abcde"
	t0ms    = int64(1790755040000)
)

type scrapeOpt struct {
	ns, pod, container, rss string
}

func scrape(cpu string, tsMs int64, opts ...scrapeOpt) string {
	o := scrapeOpt{ns: testNS, pod: testPod, container: "kusari-agent", rss: "104857600"}
	if len(opts) > 0 {
		if opts[0].ns != "" {
			o.ns = opts[0].ns
		}
		if opts[0].pod != "" {
			o.pod = opts[0].pod
		}
		if opts[0].container != "" {
			o.container = opts[0].container
		}
		if opts[0].rss != "" {
			o.rss = opts[0].rss
		}
	}
	labels := fmt.Sprintf(`container=%q,namespace=%q,pod=%q`, o.container, o.ns, o.pod)
	return fmt.Sprintf("container_cpu_usage_seconds_total{%s} %s %d\ncontainer_memory_rss{%s} %s %d\n",
		labels, cpu, tsMs, labels, o.rss, tsMs)
}

type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time { return f.t }

func newTestCollector() (*CadvisorCollector, *fakeClock) {
	c := NewCadvisorCollector(nil, nil, "test-node", 2*time.Second)
	clk := &fakeClock{t: time.UnixMilli(t0ms)}
	c.now = clk.now
	return c, clk
}

func collect(t *testing.T, c *CadvisorCollector, body string) {
	t.Helper()
	c.SetScrapeOverride(func(context.Context) ([]byte, error) { return []byte(body), nil })
	if err := c.CollectOnce(context.Background()); err != nil {
		t.Fatalf("CollectOnce: %v", err)
	}
}

func podTelemetry(t *testing.T, c *CadvisorCollector, pod, ns string) AgentTelemetry {
	t.Helper()
	for _, a := range c.FindTelemetry(pod) {
		if a.Namespace == ns {
			return a
		}
	}
	t.Fatalf("no telemetry for %s/%s", ns, pod)
	return AgentTelemetry{}
}

func millicores(t *testing.T, a AgentTelemetry) float64 {
	t.Helper()
	if a.Millicores == nil {
		t.Fatalf("%s: millicores is null (status %s), want a rate", a.PodName, a.Status)
	}
	return *a.Millicores
}

// ---------------------------------------------------------------- rate engine

func TestComputeRate_SharedVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/rate_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var table struct {
		Vectors []struct {
			Name, Prev, Curr, Dt string
			Want                 *float64
		}
	}
	if err := json.Unmarshal(raw, &table); err != nil {
		t.Fatal(err)
	}
	f := func(s string) float64 {
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			t.Fatalf("vector value %q: %v", s, err)
		}
		return v
	}
	for _, v := range table.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			got, ok := ComputeRate(MetricSample{CpuSecondsTotal: f(v.Curr)}, MetricSample{CpuSecondsTotal: f(v.Prev)}, f(v.Dt))
			switch {
			case v.Want == nil:
				if ok {
					t.Fatalf("want no rate, got %v", got)
				}
			case !ok:
				t.Fatalf("want %v, got no rate", *v.Want)
			case *v.Want == 0:
				if got != 0 || math.Signbit(got) {
					t.Fatalf("want +0.000, got %v (signbit %v)", got, math.Signbit(got))
				}
			case math.Abs(got-*v.Want) > 1e-9:
				t.Fatalf("want %v, got %v", *v.Want, got)
			}
		})
	}
}

// ---------------------------------------------------------------- parser

func TestParse_KeepsAgentContainersOnly(t *testing.T) {
	body := scrape("12.345", t0ms) +
		fmt.Sprintf("container_cpu_usage_seconds_total{container=\"POD\",namespace=%q,pod=%q} 0.001 %d\n", testNS, testPod, t0ms) +
		fmt.Sprintf("container_cpu_usage_seconds_total{container=\"\",namespace=%q,pod=%q} 9 %d\n", testNS, testPod, t0ms) +
		fmt.Sprintf("container_cpu_usage_seconds_total{container=\"coredns\",namespace=\"kube-system\",pod=\"c\"} 9 %d\n", t0ms)
	got, err := ParsePrometheusMetrics([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	want := ContainerKey{testNS, testPod, "kusari-agent"}
	if len(got) != 1 {
		t.Fatalf("want only %v, got %v", want, got)
	}
	s := got[want]
	if s.CpuSecondsTotal != 12.345 || s.MemoryRssBytes != 104857600 || !s.Timestamp.Equal(time.UnixMilli(t0ms)) {
		t.Fatalf("sample = %+v", s)
	}
}

func TestParse_DropsSeriesWithoutCPUCounter(t *testing.T) {
	body := fmt.Sprintf("container_memory_rss{container=\"kusari-agent\",namespace=%q,pod=%q} 1048576 %d\n", testNS, testPod, t0ms)
	got, err := ParsePrometheusMetrics([]byte(body))
	if err != nil || len(got) != 0 {
		t.Fatalf("want no samples, got %v err %v", got, err)
	}
}

func TestParse_DropsNonFiniteOrNegativeCPU(t *testing.T) {
	for _, bad := range []string{"NaN", "+Inf", "-Inf", "-1"} {
		t.Run(bad, func(t *testing.T) {
			got, err := ParsePrometheusMetrics([]byte(scrape(bad, t0ms)))
			if err != nil || len(got) != 0 {
				t.Fatalf("want no samples, got %v err %v", got, err)
			}
		})
	}
}

func TestParse_RejectsBodyWithoutSamples(t *testing.T) {
	for name, body := range map[string]string{"empty": "", "html": "<html><body>Unauthorized</body></html>\n", "comments only": "# HELP x y\n"} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParsePrometheusMetrics([]byte(body)); err == nil {
				t.Fatal("want an error for a body with no samples")
			}
		})
	}
}

// ---------------------------------------------------------------- collector state machine

func TestCollect_FirstSampleIsPendingNotFrozen(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("12.345", t0ms))
	a := podTelemetry(t, c, testPod, testNS)
	if a.Millicores != nil || a.Status != "PENDING" {
		t.Fatalf("first sample: millicores %v status %s, want null PENDING", a.Millicores, a.Status)
	}
	b, _ := json.Marshal(a)
	if !strings.Contains(string(b), `"millicores":null`) {
		t.Fatalf("pending sample must serialise millicores as null: %s", b)
	}
}

func TestCollect_SecondDistinctSampleIsActiveRate(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("12.345", t0ms))
	collect(t, c, scrape("12.545", t0ms+2000))
	a := podTelemetry(t, c, testPod, testNS)
	if got := millicores(t, a); math.Abs(got-100) > 1e-9 || a.Status != "ACTIVE" {
		t.Fatalf("got %v %s, want 100 ACTIVE", got, a.Status)
	}
}

func TestCollect_ZeroDeltaIsExactFrozenZero(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("13.820", t0ms))
	collect(t, c, scrape("13.820", t0ms+15000))
	a := podTelemetry(t, c, testPod, testNS)
	if got := millicores(t, a); got != 0 || math.Signbit(got) || a.Status != "FROZEN" {
		t.Fatalf("got %v %s, want +0 FROZEN", got, a.Status)
	}
	b, _ := json.Marshal(a)
	if !strings.Contains(string(b), `"millicores":0,`) {
		t.Fatalf("frozen sample must serialise as 0: %s", b)
	}
}

func TestCollect_UnrefreshedSampleKeepsPreviousRate(t *testing.T) {
	// cAdvisor re-samples every ~15 s; a 2 s poll mostly sees the same sample.
	c, _ := newTestCollector()
	collect(t, c, scrape("12.345", t0ms))
	collect(t, c, scrape("12.545", t0ms+2000))
	collect(t, c, scrape("12.545", t0ms+2000))
	if a := podTelemetry(t, c, testPod, testNS); a.Status != "ACTIVE" || math.Abs(millicores(t, a)-100) > 1e-9 {
		t.Fatalf("repeated sample changed the reading: %+v", a)
	}
	collect(t, c, scrape("12.745", t0ms+4000))
	if got := millicores(t, podTelemetry(t, c, testPod, testNS)); math.Abs(got-100) > 1e-9 {
		t.Fatalf("baseline moved on a repeated sample: rate %v", got)
	}
}

func TestCollect_TimestampRegressionIsPending(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("12.345", t0ms))
	collect(t, c, scrape("12.545", t0ms+2000))
	collect(t, c, scrape("12.600", t0ms-5000))
	if a := podTelemetry(t, c, testPod, testNS); a.Status != "PENDING" {
		t.Fatalf("clock regression: %+v, want PENDING", a)
	}
}

func TestCollect_PodRateIsSumOfContainers(t *testing.T) {
	c, _ := newTestCollector()
	envoy := scrapeOpt{container: "envoy", rss: "1048576"}
	collect(t, c, scrape("10", t0ms)+scrape("5", t0ms, envoy))
	collect(t, c, scrape("10.2", t0ms+2000)+scrape("5", t0ms+2000, envoy))
	a := podTelemetry(t, c, testPod, testNS)
	if got := millicores(t, a); math.Abs(got-100) > 1e-9 || math.Abs(a.MemoryRssMB-101) > 1e-9 {
		t.Fatalf("pod = %v mCPU %v MiB, want 100 and 101", got, a.MemoryRssMB)
	}
}

func TestCollect_SamePodNameInTwoNamespacesKeptApart(t *testing.T) {
	c, _ := newTestCollector()
	a, b := scrapeOpt{ns: "tenant-a", pod: "kusari-agent-0"}, scrapeOpt{ns: "tenant-b", pod: "kusari-agent-0"}
	collect(t, c, scrape("1", t0ms, a)+scrape("9", t0ms, b))
	collect(t, c, scrape("1", t0ms+2000, a)+scrape("9.2", t0ms+2000, b))
	if got := podTelemetry(t, c, "kusari-agent-0", "tenant-a"); got.Status != "FROZEN" {
		t.Fatalf("tenant-a = %+v, want FROZEN", got)
	}
	if got := millicores(t, podTelemetry(t, c, "kusari-agent-0", "tenant-b")); math.Abs(got-100) > 1e-9 {
		t.Fatalf("tenant-b = %v, want 100", got)
	}
}

func TestCollect_EvictsVanishedPod(t *testing.T) {
	c, clk := newTestCollector()
	collect(t, c, scrape("1", t0ms))
	clk.t = clk.t.Add(DefaultTTL + time.Second)
	collect(t, c, scrape("1", t0ms, scrapeOpt{pod: "other-pod"}))
	if got := c.FindTelemetry(testPod); len(got) != 0 {
		t.Fatalf("vanished pod still reported: %+v", got)
	}
}

func TestCollect_FailedScrapeMarksUnhealthy(t *testing.T) {
	cases := map[string]func(context.Context) ([]byte, error){
		"kubelet error": func(context.Context) ([]byte, error) { return nil, errors.New("the server has asked for the client to provide credentials (401)") },
		"malformed":     func(context.Context) ([]byte, error) { return []byte("<html>login</html>"), nil },
	}
	for name, fn := range cases {
		t.Run(name, func(t *testing.T) {
			c, _ := newTestCollector()
			c.SetScrapeOverride(fn)
			if err := c.CollectOnce(context.Background()); err == nil {
				t.Fatal("want an error")
			}
			if c.Healthy() || c.LastError() == nil {
				t.Fatalf("healthy=%v lastErr=%v, want unhealthy with an error", c.Healthy(), c.LastError())
			}
		})
	}
}

func TestCollector_HealthyUntilStale(t *testing.T) {
	c, clk := newTestCollector()
	collect(t, c, scrape("1", t0ms))
	if !c.Healthy() {
		t.Fatal("want healthy right after a scrape")
	}
	clk.t = clk.t.Add(DefaultStaleAfter + time.Millisecond)
	if c.Healthy() {
		t.Fatal("want unhealthy once the last scrape is older than DefaultStaleAfter")
	}
}

func TestStart_ReturnsPromptlyWhenCancelledDuringBackoff(t *testing.T) {
	c := NewCadvisorCollector(nil, nil, "test-node", 10*time.Millisecond)
	c.SetScrapeOverride(func(context.Context) ([]byte, error) { return nil, errors.New("refused") })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Start(ctx); close(done) }()
	time.Sleep(30 * time.Millisecond) // inside the first 500 ms backoff
	cancel()
	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("Start did not return within 200 ms of cancel: the backoff sleep ignores ctx")
	}
}

// ---------------------------------------------------------------- HTTP handler

func newTestServerMux(c *CadvisorCollector) *http.ServeMux {
	mux := http.NewServeMux()
	NewTelemetryHandler(c).RegisterRoutes(mux)
	return mux
}

func errorCode(t *testing.T, rr *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct{ Code, Message string }
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body is not JSON: %q", rr.Body.String())
	}
	return body.Error.Code
}

func TestHandler_ErrorStatuses(t *testing.T) {
	twoNS := scrape("1", t0ms, scrapeOpt{ns: "tenant-a", pod: "kusari-agent-0"}) + scrape("1", t0ms, scrapeOpt{ns: "tenant-b", pod: "kusari-agent-0"})
	cases := []struct {
		name, method, path, body string
		stale                    bool
		wantStatus               int
		wantCode                 string
	}{
		{"POST pod", http.MethodPost, "/api/telemetry/agents/" + testPod, scrape("1", t0ms), false, 405, "method_not_allowed"},
		{"DELETE list", http.MethodDelete, "/api/v1/telemetry/agents", scrape("1", t0ms), false, 405, "method_not_allowed"},
		{"never scraped pod", http.MethodGet, "/api/telemetry/agents/" + testPod, "", false, 503, "telemetry_unavailable"},
		{"never scraped list", http.MethodGet, "/api/telemetry/agents", "", false, 503, "telemetry_unavailable"},
		{"never scraped stream", http.MethodGet, "/api/telemetry/agents/" + testPod + "?stream=true", "", false, 503, "telemetry_unavailable"},
		{"stale", http.MethodGet, "/api/telemetry/agents/" + testPod, scrape("1", t0ms), true, 503, "telemetry_unavailable"},
		{"unknown pod", http.MethodGet, "/api/telemetry/agents/no-such-pod", scrape("1", t0ms), false, 404, "telemetry_not_found"},
		{"ambiguous pod", http.MethodGet, "/api/telemetry/agents/kusari-agent-0", twoNS, false, 409, "telemetry_ambiguous_pod"},
		{"namespace filters to nothing", http.MethodGet, "/api/telemetry/agents/" + testPod + "?namespace=other", scrape("1", t0ms), false, 404, "telemetry_not_found"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, clk := newTestCollector()
			if tc.body != "" {
				collect(t, c, tc.body)
			}
			if tc.stale {
				clk.t = clk.t.Add(time.Hour)
			}
			rr := httptest.NewRecorder()
			newTestServerMux(c).ServeHTTP(rr, httptest.NewRequest(tc.method, tc.path, nil))
			if rr.Code != tc.wantStatus {
				t.Fatalf("status %d, want %d: %s", rr.Code, tc.wantStatus, rr.Body.String())
			}
			if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
				t.Fatalf("Content-Type %q", ct)
			}
			if got := errorCode(t, rr); got != tc.wantCode {
				t.Fatalf("error.code %q, want %q", got, tc.wantCode)
			}
			if tc.wantStatus == 405 && rr.Header().Get("Allow") != http.MethodGet {
				t.Fatalf("405 without Allow: GET")
			}
		})
	}
}

func TestHandler_KnownPodReturnsTelemetry(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("12.345", t0ms))
	collect(t, c, scrape("12.545", t0ms+2000))
	rr := httptest.NewRecorder()
	newTestServerMux(c).ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/agents/"+testPod, nil))
	if rr.Code != 200 {
		t.Fatalf("status %d: %s", rr.Code, rr.Body.String())
	}
	var got AgentTelemetry
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.PodName != testPod || got.Namespace != testNS || got.Status != "ACTIVE" || math.Abs(millicores(t, got)-100) > 1e-9 {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestHandler_NamespaceDisambiguatesAndListIsKeyedByNamespacePod(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("1", t0ms, scrapeOpt{ns: "tenant-a", pod: "kusari-agent-0"})+scrape("1", t0ms, scrapeOpt{ns: "tenant-b", pod: "kusari-agent-0"}))
	mux := newTestServerMux(c)

	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/telemetry/agents/kusari-agent-0?namespace=tenant-b", nil))
	var one AgentTelemetry
	if rr.Code != 200 || json.Unmarshal(rr.Body.Bytes(), &one) != nil || one.Namespace != "tenant-b" {
		t.Fatalf("namespace=tenant-b: %d %s", rr.Code, rr.Body.String())
	}

	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/telemetry/agents", nil))
	var all map[string]AgentTelemetry
	if err := json.Unmarshal(rr.Body.Bytes(), &all); err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 || all["tenant-a/kusari-agent-0"].Namespace != "tenant-a" || all["tenant-b/kusari-agent-0"].Namespace != "tenant-b" {
		t.Fatalf("list = %s", rr.Body.String())
	}
}

func TestHandler_SSEStreamsCurrentStateAndReleasesOnDisconnect(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("1", t0ms))
	srv := httptest.NewServer(newTestServerMux(c))
	defer srv.Close()
	baseline := runtime.NumGoroutine()

	for i := 0; i < 20; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/telemetry/agents/"+testPod, nil)
		req.Header.Set("Accept", "text/event-stream")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
			t.Fatalf("Content-Type %q", ct)
		}
		line, err := bufio.NewReader(resp.Body).ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		var ev AgentTelemetry
		if !strings.HasPrefix(line, "data: ") || json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &ev) != nil || ev.PodName != testPod {
			t.Fatalf("first frame %q", line)
		}
		cancel()
		resp.Body.Close()
	}

	deadline := time.Now().Add(2 * time.Second)
	for c.SubscriberCount(testPod) != 0 || runtime.NumGoroutine() > baseline+2 {
		if time.Now().After(deadline) {
			t.Fatalf("after 20 disconnects: %d subscribers, %d goroutines (baseline %d)", c.SubscriberCount(testPod), runtime.NumGoroutine(), baseline)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestHandler_SSEFlushesHeadersBeforeAnyEvent(t *testing.T) {
	c, _ := newTestCollector()
	collect(t, c, scrape("1", t0ms))
	srv := httptest.NewServer(newTestServerMux(c))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/api/telemetry/agents/not-yet-scraped?stream=true", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("headers never arrived for an idle stream: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("status %d Cache-Control %q", resp.StatusCode, resp.Header.Get("Cache-Control"))
	}
}
