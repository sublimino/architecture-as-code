// Real service-to-service dependencies for the tenant apps.
//
// The three managed applications form a dependency graph:
//
//	customer-portal --> payments-api --> inventory-service
//	customer-portal --> inventory-service
//
// Each app probes its declared upstreams for liveness and calls them on the
// request path, so a fault injected into inventory-service degrades
// payments-api and then customer-portal. The graph produces four measured
// signals:
//
//   - tenant_app_upstream_up / _requests_total  -> upstream health
//   - the declared edge set                     -> CMDB topology
//   - the emitted spans                         -> Observr traces
//   - a genuine cascade                         -> the dependency fault domain
//
// Spans are written to the traces-* Elasticsearch data stream in the same
// shape the log indices use, so the read-only MCP surface queries them exactly
// as it queries logs. Emission is best-effort and does not block a request.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// ciNames maps an app_id to its CMDB configuration item. The CI is the
// identifier the client's CMDB and ServiceNow use, separate from the
// Kubernetes service name the estate runs under. The enriched flow's
// "identify CI + topology in CMDB" step resolves the service name to this CI.
// Overridable per-deployment with CI.
var ciNames = map[string]string{
	"inventory-service": "INVENTORY-APP-01",
	"payments-api":      "PAYMENTS-APP-07",
	"customer-portal":   "PORTAL-APP-03",
}

func ciFor(appID string) string {
	if v := os.Getenv("CI"); v != "" {
		return v
	}
	if v, ok := ciNames[appID]; ok {
		return v
	}
	return strings.ToUpper(appID) + "-APP-01"
}

// upstream is one declared dependency edge of this app. A probeOnly upstream is
// a backing store (a database) that is health-checked but not called on the
// request path; auth means the health probe carries the Elasticsearch basic
// credential the app already holds.
type upstream struct {
	name      string
	url       string
	probeOnly bool
	auth      bool
}

// parseDataStores reads the DATASTORE env: name=healthURL pairs for backing
// stores the app depends on but does not call per request (its ledger DB). They
// are health-probed with the app's Elasticsearch credential and surface as
// upstream health, so a base service is not shown as a dependency-less leaf.
func parseDataStores(spec string) []upstream {
	var out []upstream
	for _, raw := range strings.Split(spec, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		i := strings.Index(raw, "=")
		if i <= 0 {
			continue
		}
		out = append(out, upstream{
			name: strings.TrimSpace(raw[:i]), url: strings.TrimSpace(raw[i+1:]),
			probeOnly: true, auth: true,
		})
	}
	return out
}

// upstreamStats accumulates per-edge health and call outcomes. Mirrors the
// mutex-guarded style of the inbound `metrics` struct.
type upstreamStats struct {
	mu       sync.Mutex
	appID    string
	edges    []upstream
	up       map[string]bool
	requests map[string]map[string]uint64 // upstream -> code -> count
	sum      map[string]float64           // upstream -> total seconds
	count    map[string]uint64
}

func newUpstreamStats(appID string, edges []upstream) *upstreamStats {
	s := &upstreamStats{
		appID:    appID,
		edges:    edges,
		up:       map[string]bool{},
		requests: map[string]map[string]uint64{},
		sum:      map[string]float64{},
		count:    map[string]uint64{},
	}
	// Pre-create every child so the series exist at 0 before the first call.
	for _, e := range edges {
		s.up[e.name] = false
		s.requests[e.name] = map[string]uint64{"200": 0, "500": 0}
	}
	return s
}

func (s *upstreamStats) setUp(name string, up bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.up[name] = up
}

func (s *upstreamStats) observe(name, code string, seconds float64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.requests[name] == nil {
		s.requests[name] = map[string]uint64{}
	}
	s.requests[name][code]++
	s.sum[name] += seconds
	s.count[name]++
}

// render appends the upstream metric families to the exposition output.
func (s *upstreamStats) render(w io.Writer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.edges) == 0 {
		return
	}
	names := make([]string, 0, len(s.edges))
	for _, e := range s.edges {
		names = append(names, e.name)
	}
	sort.Strings(names)

	fmt.Fprintf(w, "# HELP tenant_app_upstream_up 1 when the declared upstream answered its last liveness probe.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_upstream_up gauge\n")
	for _, n := range names {
		v := 0
		if s.up[n] {
			v = 1
		}
		fmt.Fprintf(w, "tenant_app_upstream_up{app_id=%q,upstream=%q} %d\n", s.appID, n, v)
	}

	fmt.Fprintf(w, "# HELP tenant_app_upstream_requests_total Calls this app made to a declared upstream.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_upstream_requests_total counter\n")
	for _, n := range names {
		codes := make([]string, 0, len(s.requests[n]))
		for c := range s.requests[n] {
			codes = append(codes, c)
		}
		sort.Strings(codes)
		for _, c := range codes {
			fmt.Fprintf(w, "tenant_app_upstream_requests_total{app_id=%q,upstream=%q,code=%q} %d\n",
				s.appID, n, c, s.requests[n][c])
		}
	}

	fmt.Fprintf(w, "# HELP tenant_app_upstream_duration_seconds_sum Total seconds spent calling a declared upstream.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_upstream_duration_seconds_sum counter\n")
	for _, n := range names {
		fmt.Fprintf(w, "tenant_app_upstream_duration_seconds_sum{app_id=%q,upstream=%q} %g\n", s.appID, n, s.sum[n])
	}
	fmt.Fprintf(w, "# HELP tenant_app_upstream_duration_seconds_count Calls counted into the duration sum.\n")
	fmt.Fprintf(w, "# TYPE tenant_app_upstream_duration_seconds_count counter\n")
	for _, n := range names {
		fmt.Fprintf(w, "tenant_app_upstream_duration_seconds_count{app_id=%q,upstream=%q} %d\n", s.appID, n, s.count[n])
	}
}

// parseUpstreams reads the UPSTREAMS env: a comma-separated list of service
// names, or name=url pairs when the address is not the in-cluster default.
func parseUpstreams(spec, defaultPort string) []upstream {
	var out []upstream
	for _, raw := range strings.Split(spec, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		name, url := raw, ""
		if i := strings.Index(raw, "="); i > 0 {
			name, url = strings.TrimSpace(raw[:i]), strings.TrimSpace(raw[i+1:])
		}
		if url == "" {
			url = "http://" + name + defaultPort
		}
		out = append(out, upstream{name: name, url: strings.TrimRight(url, "/")})
	}
	return out
}

// --- Tracing --------------------------------------------------------------

// span is one operation in a distributed trace, written to the traces-* data
// stream. Field names mirror OpenTelemetry's semantics so the shape reads as
// a real trace.
type span struct {
	Timestamp    string  `json:"@timestamp"`
	TraceID      string  `json:"trace_id"`
	SpanID       string  `json:"span_id"`
	ParentSpanID string  `json:"parent_span_id,omitempty"`
	AppID        string  `json:"app_id"`
	Service      string  `json:"service"`
	Operation    string  `json:"operation"`
	Upstream     string  `json:"upstream,omitempty"`
	DurationMS   float64 `json:"duration_ms"`
	StatusCode   string  `json:"status_code"`
	Error        bool    `json:"error"`
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return strings.Repeat("0", n*2)
	}
	return hex.EncodeToString(b)
}

// traceparent renders the W3C header so a trace stitches across the three
// apps.
func traceparent(traceID, spanID string) string {
	return "00-" + traceID + "-" + spanID + "-01"
}

// parseTraceparent recovers the trace and parent span from an inbound header.
// Returns empty strings when absent or malformed, in which case the caller
// starts a fresh trace.
func parseTraceparent(h string) (traceID, parentSpanID string) {
	parts := strings.Split(strings.TrimSpace(h), "-")
	if len(parts) != 4 || len(parts[1]) != 32 || len(parts[2]) != 16 {
		return "", ""
	}
	return parts[1], parts[2]
}

// spanSink batches spans into Elasticsearch. Best-effort and non-blocking:
// a full buffer drops spans so the request path stays fast, and an ES
// outage is logged once per flush.
type spanSink struct {
	ch      chan span
	esURL   string
	user    string
	pass    string
	index   string
	client  *http.Client
	dropped uint64
	mu      sync.Mutex
}

func newSpanSink(appID string) *spanSink {
	pass := os.Getenv("ELASTIC_PASSWORD")
	if pass == "" {
		return nil // no credential mounted; tracing stays off
	}
	s := &spanSink{
		ch:     make(chan span, 512),
		esURL:  strings.TrimRight(env("ELASTIC_URL", "http://olly-es-http:9200"), "/"),
		user:   env("ELASTIC_USER", "elastic"),
		pass:   pass,
		index:  env("TRACES_INDEX", "traces-synthetic"),
		client: &http.Client{Timeout: 10 * time.Second},
	}
	go s.run()
	return s
}

func (s *spanSink) emit(sp span) {
	if s == nil {
		return
	}
	select {
	case s.ch <- sp:
	default:
		s.mu.Lock()
		s.dropped++
		s.mu.Unlock()
	}
}

func (s *spanSink) run() {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	batch := make([]span, 0, 128)
	for {
		select {
		case sp := <-s.ch:
			batch = append(batch, sp)
			if len(batch) >= 128 {
				s.flush(batch)
				batch = batch[:0]
			}
		case <-tick.C:
			if len(batch) > 0 {
				s.flush(batch)
				batch = batch[:0]
			}
		}
	}
}

func (s *spanSink) flush(batch []span) {
	var buf bytes.Buffer
	for _, sp := range batch {
		buf.WriteString(`{"create":{}}` + "\n")
		line, err := json.Marshal(sp)
		if err != nil {
			continue
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}
	req, err := http.NewRequest(http.MethodPost, s.esURL+"/"+s.index+"/_bulk", &buf)
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/x-ndjson")
	req.SetBasicAuth(s.user, s.pass)
	resp, err := s.client.Do(req)
	if err != nil {
		log.Printf("span flush failed (%d spans, continuing): %v", len(batch), err)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 2048))
	if resp.StatusCode >= 300 {
		log.Printf("span flush -> %d (%d spans)", resp.StatusCode, len(batch))
	}
}

// ensureTraceIndex installs an index template so traces-* is created as a
// data stream with 0 replicas, matching the convention the log seed uses
// (single-node ES cannot allocate a replica and would sit yellow).
func (s *spanSink) ensureTraceIndex() {
	if s == nil {
		return
	}
	body := fmt.Sprintf(`{
	  "index_patterns": [%q],
	  "data_stream": {},
	  "priority": 200,
	  "template": {
	    "settings": {"number_of_replicas": 0},
	    "mappings": {"properties": {
	      "@timestamp": {"type": "date"},
	      "trace_id": {"type": "keyword"},
	      "span_id": {"type": "keyword"},
	      "parent_span_id": {"type": "keyword"},
	      "app_id": {"type": "keyword"},
	      "service": {"type": "keyword"},
	      "operation": {"type": "keyword"},
	      "upstream": {"type": "keyword"},
	      "duration_ms": {"type": "double"},
	      "status_code": {"type": "keyword"},
	      "error": {"type": "boolean"}
	    }}
	  }
	}`, s.index+"*")
	for i := 0; i < 20; i++ {
		req, err := http.NewRequest(http.MethodPut,
			s.esURL+"/_index_template/"+s.index, strings.NewReader(body))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.SetBasicAuth(s.user, s.pass)
		resp, err := s.client.Do(req)
		if err == nil {
			io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
			code := resp.StatusCode
			resp.Body.Close()
			if code < 300 {
				s.forceZeroReplicas()
				return
			}
		}
		time.Sleep(3 * time.Second)
	}
}

// forceZeroReplicas drops replicas to 0 on the trace index when it already
// exists as a plain index created before the data-stream template registered
// (an early write can race ahead of the template). On a single-node cluster a
// replica shard stays unassigned and the cluster sits yellow, so this keeps it
// green. A 404 (no such index yet) is harmless.
func (s *spanSink) forceZeroReplicas() {
	req, err := http.NewRequest(http.MethodPut,
		s.esURL+"/"+s.index+"/_settings", strings.NewReader(`{"index":{"number_of_replicas":0}}`))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(s.user, s.pass)
	if resp, err := s.client.Do(req); err == nil {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
		resp.Body.Close()
	}
}

// --- Calling upstreams ----------------------------------------------------

// callUpstream performs one real request to a declared dependency, records
// the edge metrics, and emits a child span. Returns true when the upstream
// answered successfully; the caller propagates failure so a fault cascades
// through the graph.
func callUpstream(ctx context.Context, client *http.Client, stats *upstreamStats,
	sink *spanSink, appID string, up upstream, traceID, parentSpanID string) bool {

	start := time.Now()
	spanID := randHex(8)
	code := "500"
	ok := false

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, up.url+"/work", nil)
	if err == nil {
		if traceID != "" {
			req.Header.Set("traceparent", traceparent(traceID, spanID))
		}
		resp, rerr := client.Do(req)
		if rerr == nil {
			io.Copy(io.Discard, io.LimitReader(resp.Body, 1024))
			resp.Body.Close()
			code = fmt.Sprintf("%d", resp.StatusCode)
			ok = resp.StatusCode < 400
		}
	}

	elapsed := time.Since(start)
	stats.observe(up.name, code, elapsed.Seconds())
	sink.emit(span{
		Timestamp:    time.Now().UTC().Format(time.RFC3339Nano),
		TraceID:      traceID,
		SpanID:       spanID,
		ParentSpanID: parentSpanID,
		AppID:        appID,
		Service:      appID,
		Operation:    "GET " + up.name + "/work",
		Upstream:     up.name,
		DurationMS:   float64(elapsed.Microseconds()) / 1000.0,
		StatusCode:   code,
		Error:        !ok,
	})
	return ok
}

// probeUpstreams keeps tenant_app_upstream_up current by polling each declared
// dependency. A service upstream is probed at its /healthz; a datastore
// (probeOnly) upstream is probed at its full URL with the Elasticsearch
// credential the app holds.
func probeUpstreams(client *http.Client, stats *upstreamStats, edges []upstream, every time.Duration, esUser, esPass string) {
	if len(edges) == 0 {
		return
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		for _, e := range edges {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			target := e.url + "/healthz"
			if e.probeOnly {
				target = e.url
			}
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
			up := false
			if err == nil {
				if e.auth && esPass != "" {
					req.SetBasicAuth(esUser, esPass)
				}
				if resp, rerr := client.Do(req); rerr == nil {
					io.Copy(io.Discard, io.LimitReader(resp.Body, 256))
					resp.Body.Close()
					up = resp.StatusCode < 400
				}
			}
			cancel()
			stats.setUp(e.name, up)
		}
		<-t.C
	}
}
