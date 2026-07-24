// tenant-app is a synthetic "managed application", one of the workloads Olly
// observes (inventory-service, payments-api, customer-portal). Each runs as a
// real Deployment so Eye in the Sky has genuine per-tenant telemetry:
//
//   - real pod CPU/memory (cAdvisor/kube-state scrape the container for free);
//   - real application metrics served at /metrics (request rate, error rate,
//     and a latency histogram), driven by an internal traffic generator so the
//     series are live without any external load;
//   - a Trivy scan target (it runs in olly-replica, already in scope), so the
//     Aqua pane shows vulnerabilities attributed to each tenant app.
//
// One image, deployed once per app_id (APP_ID env). Dependency-free: the
// Prometheus exposition is hand-rolled so the image builds under the shared
// apps/Dockerfile with no go.mod changes. A /fault endpoint lets a demo spike
// the error rate and latency for a window so a tenant visibly goes unhealthy.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

// latencyBuckets are the cumulative histogram upper bounds (seconds). Chosen to
// straddle a ~40-120ms healthy latency and a multi-hundred-ms degraded tail so
// histogram_quantile reads cleanly in Grafana.
var latencyBuckets = []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

// metrics holds the app's counters/histogram. All access is mutex-guarded; the
// traffic generator writes and /metrics reads. app_id is a constant label.
type metrics struct {
	mu           sync.Mutex
	appID        string
	requests     map[string]uint64 // code ("200"/"500") -> count
	bucketCounts []uint64          // per latencyBuckets, non-cumulative
	inf          uint64            // observations above the last bound
	sum          float64
	count        uint64
}

func newMetrics(appID string) *metrics {
	return &metrics{
		appID:        appID,
		requests:     map[string]uint64{"200": 0, "500": 0},
		bucketCounts: make([]uint64, len(latencyBuckets)),
	}
}

func (m *metrics) observe(latency float64, ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ok {
		m.requests["200"]++
	} else {
		m.requests["500"]++
	}
	m.count++
	m.sum += latency
	placed := false
	for i, b := range latencyBuckets {
		if latency <= b {
			m.bucketCounts[i]++
			placed = true
			break
		}
	}
	if !placed {
		m.inf++
	}
}

// render writes the Prometheus text exposition format (v0.0.4).
func (m *metrics) render(w http.ResponseWriter) {
	m.mu.Lock()
	defer m.mu.Unlock()
	lbl := func(extra string) string {
		if extra == "" {
			return fmt.Sprintf(`{app_id=%q}`, m.appID)
		}
		return fmt.Sprintf(`{app_id=%q,%s}`, m.appID, extra)
	}

	fmt.Fprintf(w, "# HELP tenant_app_requests_total Total application requests handled.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_requests_total counter\n")
	codes := make([]string, 0, len(m.requests))
	for c := range m.requests {
		codes = append(codes, c)
	}
	sort.Strings(codes)
	for _, c := range codes {
		fmt.Fprintf(w, "tenant_app_requests_total%s %d\n", lbl(fmt.Sprintf("code=%q", c)), m.requests[c])
	}

	fmt.Fprintf(w, "# HELP tenant_app_request_duration_seconds Request latency in seconds.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_request_duration_seconds histogram\n")
	var cum uint64
	for i, b := range latencyBuckets {
		cum += m.bucketCounts[i]
		fmt.Fprintf(w, "tenant_app_request_duration_seconds_bucket%s %d\n",
			lbl(fmt.Sprintf("le=%q", strconv.FormatFloat(b, 'g', -1, 64))), cum)
	}
	cum += m.inf
	fmt.Fprintf(w, "tenant_app_request_duration_seconds_bucket%s %d\n", lbl(`le="+Inf"`), cum)
	fmt.Fprintf(w, "tenant_app_request_duration_seconds_sum%s %s\n", lbl(""), strconv.FormatFloat(m.sum, 'g', -1, 64))
	fmt.Fprintf(w, "tenant_app_request_duration_seconds_count%s %d\n", lbl(""), m.count)

	fmt.Fprintf(w, "# HELP tenant_app_up 1 when the application is serving.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_up gauge\n")
	fmt.Fprintf(w, "tenant_app_up%s 1\n", lbl(""))
}

// maxInflight bounds the traffic generator's concurrency. Each simulated
// request makes real downstream calls, so without a bound a slow upstream
// would let ticks pile up unboundedly.
const maxInflight = 16

func main() {
	appID := env("APP_ID", "inventory-service")
	listen := env("LISTEN", ":8080")
	rps := envFloat("RPS", 8)                    // internal traffic rate
	baseErr := envFloat("ERROR_RATE", 0.02)      // steady-state error fraction
	baseLatency := envFloat("LATENCY_MS", 45)    // healthy median latency (ms)
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	m := newMetrics(appID)

	// Real dependency edges. UPSTREAMS declares this app's downstream services,
	// called on the request path so a fault in a leaf service degrades
	// everything above it. DATASTORE declares a backing store (a database) that
	// is health-probed but not called per request, so a base service still
	// reports upstream health rather than reading as a dependency-less leaf.
	edges := append(parseUpstreams(env("UPSTREAMS", ""), ":8080"),
		parseDataStores(env("DATASTORE", ""))...)
	ustats := newUpstreamStats(appID, edges)
	sink := newSpanSink(appID)
	go sink.ensureTraceIndex()
	client := &http.Client{Timeout: 5 * time.Second}
	go probeUpstreams(client, ustats, edges, 15*time.Second,
		env("ELASTIC_USER", "elastic"), os.Getenv("ELASTIC_PASSWORD"))

	// callEdges performs this app's downstream service calls under one trace and
	// reports whether every dependency answered. Datastore upstreams are
	// health-probed elsewhere, not called here.
	callEdges := func(traceID, parentSpan string) (time.Duration, bool) {
		start := time.Now()
		ok := true
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		for _, e := range edges {
			if e.probeOnly {
				continue
			}
			if !callUpstream(ctx, client, ustats, sink, appID, e, traceID, parentSpan) {
				ok = false
			}
		}
		return time.Since(start), ok
	}

	// faultUntil raises error rate + latency until the deadline (demo lever).
	var faultMu sync.Mutex
	var faultUntil time.Time
	inFault := func() bool {
		faultMu.Lock()
		defer faultMu.Unlock()
		return time.Now().Before(faultUntil)
	}

	// simulate one request: local work plus this app's real dependency calls.
	// A failing upstream fails the request, so upstream health shows up in
	// this app's own error rate.
	simulate := func() {
		errRate, latMs := baseErr, baseLatency
		if inFault() {
			errRate, latMs = 0.35, baseLatency*4
		}
		// jittered local latency: base * exp(N(0,0.4)), floored at 1ms.
		latency := math.Max(0.001, (latMs/1000.0)*math.Exp(rng.NormFloat64()*0.4))
		ok := rng.Float64() >= errRate

		traceID, rootSpan := randHex(16), randHex(8)
		upTook, upOK := callEdges(traceID, rootSpan)
		latency += upTook.Seconds()
		if !upOK {
			ok = false
		}
		m.observe(latency, ok)
		sink.emit(span{
			Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
			TraceID:    traceID,
			SpanID:     rootSpan,
			AppID:      appID,
			Service:    appID,
			Operation:  "internal /work",
			DurationMS: latency * 1000,
			StatusCode: map[bool]string{true: "200", false: "500"}[ok],
			Error:      !ok,
		})
	}

	// internal traffic generator so metrics move without external callers.
	// Each tick performs real network calls, so concurrency is bounded and
	// a slow dependency sheds load.
	go func() {
		if rps <= 0 {
			return
		}
		tick := time.Duration(float64(time.Second) / rps)
		if tick < time.Millisecond {
			tick = time.Millisecond
		}
		t := time.NewTicker(tick)
		defer t.Stop()
		sem := make(chan struct{}, maxInflight)
		for range t.C {
			select {
			case sem <- struct{}{}:
				go func() { defer func() { <-sem }(); simulate() }()
			default: // saturated: drop this tick
			}
		}
	}()

	mux := http.NewServeMux()
	// /work handles a real inbound request: it does local work, then calls this
	// app's own declared dependencies, continuing the caller's trace. A failing
	// dependency returns 500 here, so a fault injected into a leaf service
	// propagates up the graph.
	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		traceID, parentSpan := parseTraceparent(r.Header.Get("traceparent"))
		if traceID == "" {
			traceID, parentSpan = randHex(16), ""
		}
		selfSpan := randHex(8)

		ok := rng.Float64() >= baseErr && !inFault()
		time.Sleep(time.Duration(baseLatency) * time.Millisecond)
		if _, upOK := callEdges(traceID, selfSpan); !upOK {
			ok = false
		}

		elapsed := time.Since(start)
		m.observe(elapsed.Seconds(), ok)
		code := "200"
		if !ok {
			code = "500"
		}
		sink.emit(span{
			Timestamp:    time.Now().UTC().Format(time.RFC3339Nano),
			TraceID:      traceID,
			SpanID:       selfSpan,
			ParentSpanID: parentSpan,
			AppID:        appID,
			Service:      appID,
			Operation:    "GET /work",
			DurationMS:   float64(elapsed.Microseconds()) / 1000.0,
			StatusCode:   code,
			Error:        !ok,
		})
		if !ok {
			http.Error(w, "request failed: local fault or failing dependency", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte("ok"))
	})
	// /topology reports this app's declared dependency edges. The CMDB MCP tool
	// reads this as the authoritative source: the graph reflects whatever the
	// apps actually call.
	mux.HandleFunc("/topology", func(w http.ResponseWriter, _ *http.Request) {
		type edge struct {
			Upstream string `json:"upstream"`
			URL      string `json:"url"`
			Up       bool   `json:"up"`
		}
		out := struct {
			AppID string `json:"app_id"`
			CI    string `json:"ci"`
			Edges []edge `json:"edges"`
		}{AppID: appID, CI: ciFor(appID), Edges: []edge{}}
		ustats.mu.Lock()
		for _, e := range edges {
			out.Edges = append(out.Edges, edge{Upstream: e.name, URL: e.url, Up: ustats.up[e.name]})
		}
		ustats.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})
	// /fault?seconds=N spikes error rate + latency for N seconds (demo lever).
	mux.HandleFunc("/fault", func(w http.ResponseWriter, r *http.Request) {
		secs := 120
		if v := r.URL.Query().Get("seconds"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				secs = n
			}
		}
		faultMu.Lock()
		faultUntil = time.Now().Add(time.Duration(secs) * time.Second)
		faultMu.Unlock()
		log.Printf("%s entering fault mode for %ds", appID, secs)
		fmt.Fprintf(w, "fault mode for %ds\n", secs)
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		m.render(w)
		ustats.render(w)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	upNames := make([]string, 0, len(edges))
	for _, e := range edges {
		upNames = append(upNames, e.name)
	}
	log.Printf("tenant-app %q (ci=%s) listening on %s (rps=%.1f base_error=%.3f base_latency=%.0fms upstreams=[%s] tracing=%t)",
		appID, ciFor(appID), listen, rps, baseErr, baseLatency, strings.Join(upNames, " "), sink != nil)
	log.Fatal(http.ListenAndServe(listen, mux))
}
