// Olly MCP read-only tool surface.
//
// The enriched flow queries seven sources in parallel at step 5. This file
// implements five observability tools plus the ServiceNow knowledge tool. Each
// has an EEMS scope, server-side caps, and an audit line, the same controls
// elk_search_logs enforces in main.go.
//
// Each tool reads a source that exists in the cluster:
//
//	grafana_query_metrics -> Prometheus (tenant_app_* / olly_* series)
//	observr_traces        -> the traces-* data stream the tenant apps emit
//	cmdb_lookup_ci        -> each app's live /topology (the graph it really calls)
//	io_events_query       -> the mapping service's decision history
//	drift_changes         -> change records in audit-logs-*, classified
//	servicenow_inc_chg    -> the mapping service's ticket store
//
// No tool here writes or holds a write entitlement. A tool whose backing source
// is unreachable returns an explicit error, so a broken dependency is not
// mistaken for "no evidence".
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
)

// scopeFor maps each tool to the EEMS scope that gates it. The sentinel checks
// its own entitlement before calling; this server checks the scope again on
// arrival, independent of the client-side check.
var scopeFor = map[string]string{
	"elk_search_logs":       "elk.logs.read",
	"grafana_query_metrics": "grafana.dashboards.read",
	"observr_traces":        "observr.traces.read",
	"cmdb_lookup_ci":        "cmdb.topology.read",
	"io_events_query":       "io.events.read",
	"drift_changes":         "drift.changes.read",
	"servicenow_inc_chg":    "servicenow.incidents.read",
}

func audit(tool, decision string, extra string) {
	log.Printf(`AUDIT {"tool":%q,"scope":%q,"decision":%q,%s}`,
		tool, scopeFor[tool], decision, extra)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// decodeReq is the shared request envelope. Not every tool uses every field.
type toolRequest struct {
	AppID            string `json:"app_id"`
	CI               string `json:"ci"`
	Query            string `json:"query"`
	TraceID          string `json:"trace_id"`
	Size             int    `json:"size"`
	TimeRangeMinutes int    `json:"time_range_minutes"`
	CorrelationID    string `json:"correlation_id"`
}

func decodeReq(w http.ResponseWriter, r *http.Request) (toolRequest, bool) {
	var req toolRequest
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return req, false
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return req, false
	}
	return req, true
}

// appIDPattern bounds what can be interpolated into a downstream query. The
// app_id arrives on an untrusted event payload, so it is validated as a
// DNS-style label before it reaches PromQL, Lucene, or a URL.
var appIDPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$`)

func validAppID(s string) bool { return s != "" && appIDPattern.MatchString(s) }

// --- grafana_query_metrics ------------------------------------------------

// MetricPoint is one instant-vector sample returned to the agent.
type MetricPoint struct {
	Metric string            `json:"metric"`
	Labels map[string]string `json:"labels"`
	Value  float64           `json:"value"`
}

// metricQueries are the fixed, reviewed PromQL expressions this tool will run,
// keyed by a short name. The agent selects a name; the PromQL comes from this
// map. That keeps an untrusted event payload out of the query language and
// bounds the tool's cost and output shape.
var metricQueries = map[string]string{
	"error_rate_pct": `100 * sum by (app_id) (rate(tenant_app_requests_total{code="500",app_id="%s"}[5m])) / clamp_min(sum by (app_id) (rate(tenant_app_requests_total{app_id="%s"}[5m])), 0.001)`,
	"latency_p95_s":  `histogram_quantile(0.95, sum by (app_id, le) (rate(tenant_app_request_duration_seconds_bucket{app_id="%s"}[5m])))`,
	"latency_avg_s":  `sum by (app_id) (rate(tenant_app_request_duration_seconds_sum{app_id="%s"}[5m])) / clamp_min(sum by (app_id) (rate(tenant_app_request_duration_seconds_count{app_id="%s"}[5m])), 0.001)`,
	"up":             `tenant_app_up{app_id="%s"}`,
	"upstream_up":    `tenant_app_upstream_up{app_id="%s"}`,
	"upstream_error_rate_pct": `100 * sum by (upstream) (rate(tenant_app_upstream_requests_total{code="500",app_id="%s"}[5m])) / clamp_min(sum by (upstream) (rate(tenant_app_upstream_requests_total{app_id="%s"}[5m])), 0.001)`,
}

func (s *server) grafanaMetrics(w http.ResponseWriter, r *http.Request) {
	const tool = "grafana_query_metrics"
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	if !validAppID(req.AppID) {
		audit(tool, "deny", fmt.Sprintf(`"reason":"invalid app_id","app_id":%q`, req.AppID))
		http.Error(w, "app_id must be a DNS-style label", http.StatusBadRequest)
		return
	}

	out := []MetricPoint{}
	names := make([]string, 0, len(metricQueries))
	for n := range metricQueries {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, name := range names {
		tmpl := metricQueries[name]
		q := tmpl
		// Each template takes app_id either once or twice.
		if strings.Count(tmpl, "%s") == 2 {
			q = fmt.Sprintf(tmpl, req.AppID, req.AppID)
		} else {
			q = fmt.Sprintf(tmpl, req.AppID)
		}
		pts, err := s.promInstant(r, name, q)
		if err != nil {
			audit(tool, "error", fmt.Sprintf(`"metric":%q,"error":%q`, name, err.Error()))
			continue
		}
		out = append(out, pts...)
	}
	audit(tool, "allow", fmt.Sprintf(`"app_id":%q,"series":%d`, req.AppID, len(out)))
	writeJSON(w, map[string]any{"app_id": req.AppID, "points": out})
}

func (s *server) promInstant(r *http.Request, name, promQL string) ([]MetricPoint, error) {
	u := fmt.Sprintf("%s/api/v1/query?query=%s", s.promURL, url.QueryEscape(promQL))
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("prometheus unreachable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("prometheus returned %d", resp.StatusCode)
	}
	var pr struct {
		Data struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Value  []any             `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, err
	}
	out := make([]MetricPoint, 0, len(pr.Data.Result))
	for _, res := range pr.Data.Result {
		if len(res.Value) != 2 {
			continue
		}
		str, _ := res.Value[1].(string)
		var f float64
		if _, err := fmt.Sscanf(str, "%g", &f); err != nil {
			continue
		}
		out = append(out, MetricPoint{Metric: name, Labels: res.Metric, Value: f})
	}
	return out, nil
}

// --- observr_traces -------------------------------------------------------

// TraceSpan is one span returned to the agent.
type TraceSpan struct {
	Timestamp  string  `json:"timestamp"`
	TraceID    string  `json:"trace_id"`
	Service    string  `json:"service"`
	Operation  string  `json:"operation"`
	Upstream   string  `json:"upstream,omitempty"`
	DurationMS float64 `json:"duration_ms"`
	StatusCode string  `json:"status_code"`
	Error      bool    `json:"error"`
}

func (s *server) observrTraces(w http.ResponseWriter, r *http.Request) {
	const tool = "observr_traces"
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	if req.TraceID == "" && !validAppID(req.AppID) {
		audit(tool, "deny", `"reason":"one of trace_id or a valid app_id is required"`)
		http.Error(w, "provide trace_id or a valid app_id", http.StatusBadRequest)
		return
	}
	size := req.Size
	if size <= 0 || size > s.maxDocs {
		size = s.maxDocs
	}
	mins := req.TimeRangeMinutes
	if mins <= 0 || mins > s.maxRange {
		mins = s.maxRange
	}

	// Errors first: a trace query during an incident wants the failing spans,
	// and the doc cap would otherwise fill with healthy ones.
	must := []any{}
	if req.TraceID != "" {
		must = append(must, map[string]any{"term": map[string]any{"trace_id": req.TraceID}})
	} else {
		must = append(must, map[string]any{"term": map[string]any{"app_id": req.AppID}})
	}
	query := map[string]any{
		"size": size,
		"sort": []any{
			map[string]any{"error": map[string]any{"order": "desc"}},
			map[string]any{"@timestamp": map[string]any{"order": "desc"}},
		},
		"query": map[string]any{"bool": map[string]any{
			"must": must,
			"filter": []any{map[string]any{"range": map[string]any{"@timestamp": map[string]any{
				"gte": fmt.Sprintf("now-%dm", mins),
			}}}},
		}},
	}

	var esResp struct {
		Hits struct {
			Total struct {
				Value int `json:"value"`
			} `json:"total"`
			Hits []struct {
				Source struct {
					Timestamp  string  `json:"@timestamp"`
					TraceID    string  `json:"trace_id"`
					Service    string  `json:"service"`
					Operation  string  `json:"operation"`
					Upstream   string  `json:"upstream"`
					DurationMS float64 `json:"duration_ms"`
					StatusCode string  `json:"status_code"`
					Error      bool    `json:"error"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := s.esSearch(r, s.tracesIndex, query, &esResp); err != nil {
		audit(tool, "error", fmt.Sprintf(`"error":%q`, err.Error()))
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	spans := make([]TraceSpan, 0, len(esResp.Hits.Hits))
	errCount := 0
	for _, h := range esResp.Hits.Hits {
		src := h.Source
		if src.Error {
			errCount++
		}
		spans = append(spans, TraceSpan{
			Timestamp: src.Timestamp, TraceID: src.TraceID, Service: src.Service,
			Operation: src.Operation, Upstream: src.Upstream, DurationMS: src.DurationMS,
			StatusCode: src.StatusCode, Error: src.Error,
		})
	}
	audit(tool, "allow", fmt.Sprintf(`"app_id":%q,"trace_id":%q,"doc_count":%d,"error_spans":%d`,
		req.AppID, req.TraceID, esResp.Hits.Total.Value, errCount))
	writeJSON(w, map[string]any{
		"doc_count": esResp.Hits.Total.Value, "error_spans": errCount, "spans": spans,
	})
}

// --- drift_changes --------------------------------------------------------

// DriftRecord is a configuration change observed in the audit log, classified
// by whether it carries an approved change reference.
type DriftRecord struct {
	Timestamp string `json:"timestamp"`
	AppID     string `json:"app_id"`
	Message   string `json:"message"`
	ChangeRef string `json:"change_ref,omitempty"`
	Approved  bool   `json:"approved"`
}

// changeRefPattern recovers a ServiceNow change number from an audit line. A
// change record carrying one was raised through the change process; one
// without a change number is unapproved drift, the DRIFT signal the enriched
// flow correlates against an error burst.
var changeRefPattern = regexp.MustCompile(`\b(CHG\d{5,})\b`)

func (s *server) driftChanges(w http.ResponseWriter, r *http.Request) {
	const tool = "drift_changes"
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	if !validAppID(req.AppID) {
		audit(tool, "deny", fmt.Sprintf(`"reason":"invalid app_id","app_id":%q`, req.AppID))
		http.Error(w, "app_id must be a DNS-style label", http.StatusBadRequest)
		return
	}
	size := req.Size
	if size <= 0 || size > s.maxDocs {
		size = s.maxDocs
	}
	mins := req.TimeRangeMinutes
	if mins <= 0 || mins > s.maxRange {
		mins = s.maxRange
	}

	query := map[string]any{
		"size": size,
		"sort": []any{map[string]any{"@timestamp": map[string]any{"order": "desc"}}},
		"query": map[string]any{"bool": map[string]any{
			"must": []any{
				map[string]any{"term": map[string]any{"app_id": req.AppID}},
				map[string]any{"query_string": map[string]any{
					"query": "message:(*config* OR *change* OR *deploy* OR *rollout* OR *drift*)",
				}},
			},
			"filter": []any{map[string]any{"range": map[string]any{"@timestamp": map[string]any{
				"gte": fmt.Sprintf("now-%dm", mins),
			}}}},
		}},
	}

	var esResp struct {
		Hits struct {
			Total struct {
				Value int `json:"value"`
			} `json:"total"`
			Hits []struct {
				Source struct {
					Timestamp string `json:"@timestamp"`
					AppID     string `json:"app_id"`
					Message   string `json:"message"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := s.esSearch(r, "audit-logs-*", query, &esResp); err != nil {
		audit(tool, "error", fmt.Sprintf(`"error":%q`, err.Error()))
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	records := make([]DriftRecord, 0, len(esResp.Hits.Hits))
	unapproved := 0
	for _, h := range esResp.Hits.Hits {
		ref := ""
		if m := changeRefPattern.FindStringSubmatch(h.Source.Message); m != nil {
			ref = m[1]
		}
		if ref == "" {
			unapproved++
		}
		records = append(records, DriftRecord{
			Timestamp: h.Source.Timestamp, AppID: h.Source.AppID,
			Message: h.Source.Message, ChangeRef: ref, Approved: ref != "",
		})
	}
	audit(tool, "allow", fmt.Sprintf(`"app_id":%q,"doc_count":%d,"unapproved":%d`,
		req.AppID, esResp.Hits.Total.Value, unapproved))
	writeJSON(w, map[string]any{
		"doc_count": esResp.Hits.Total.Value, "unapproved_count": unapproved, "changes": records,
	})
}

// --- cmdb_lookup_ci -------------------------------------------------------

// CIRecord is a configuration item and its live dependency edges.
type CIRecord struct {
	AppID string   `json:"app_id"`
	CI    string   `json:"ci"`
	Edges []CIEdge `json:"edges"`
}

type CIEdge struct {
	Upstream string `json:"upstream"`
	CI       string `json:"ci"`
	Up       bool   `json:"up"`
}

// cmdbLookup resolves an app to its CI and blast radius by asking the services
// themselves what they call. The graph is observed live from the services, so
// it reflects the current dependencies.
func (s *server) cmdbLookup(w http.ResponseWriter, r *http.Request) {
	const tool = "cmdb_lookup_ci"
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	if !validAppID(req.AppID) {
		audit(tool, "deny", fmt.Sprintf(`"reason":"invalid app_id","app_id":%q`, req.AppID))
		http.Error(w, "app_id must be a DNS-style label", http.StatusBadRequest)
		return
	}

	type topo struct {
		AppID string `json:"app_id"`
		CI    string `json:"ci"`
		Edges []struct {
			Upstream string `json:"upstream"`
			Up       bool   `json:"up"`
		} `json:"edges"`
	}
	fetch := func(app string) (topo, error) {
		var t topo
		u := fmt.Sprintf("http://%s%s/topology", app, s.tenantPort)
		hr, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u, nil)
		if err != nil {
			return t, err
		}
		resp, err := s.client.Do(hr)
		if err != nil {
			return t, fmt.Errorf("topology for %s unreachable: %w", app, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return t, fmt.Errorf("topology for %s returned %d", app, resp.StatusCode)
		}
		err = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&t)
		return t, err
	}

	self, err := fetch(req.AppID)
	if err != nil {
		audit(tool, "error", fmt.Sprintf(`"app_id":%q,"error":%q`, req.AppID, err.Error()))
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	rec := CIRecord{AppID: self.AppID, CI: self.CI, Edges: []CIEdge{}}
	for _, e := range self.Edges {
		ci := ""
		if t, err := fetch(e.Upstream); err == nil {
			ci = t.CI
		}
		rec.Edges = append(rec.Edges, CIEdge{Upstream: e.Upstream, CI: ci, Up: e.Up})
	}
	audit(tool, "allow", fmt.Sprintf(`"app_id":%q,"ci":%q,"edges":%d`, req.AppID, rec.CI, len(rec.Edges)))
	writeJSON(w, rec)
}

// --- io_events_query / servicenow_inc_chg ---------------------------------

// proxyMapping performs a read-only GET against the mapping service and
// forwards the decoded JSON. Used by the two tools whose source of truth is
// the IO Mapping Service: its orchestration decisions and its ticket store.
func (s *server) proxyMapping(w http.ResponseWriter, r *http.Request, tool, path string, req toolRequest) {
	u := s.mappingURL + path
	if validAppID(req.AppID) {
		u += "?app_id=" + url.QueryEscape(req.AppID)
	}
	hr, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	resp, err := s.client.Do(hr)
	if err != nil {
		audit(tool, "error", fmt.Sprintf(`"error":%q`, err.Error()))
		http.Error(w, "mapping service unreachable: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		audit(tool, "error", fmt.Sprintf(`"status":%d`, resp.StatusCode))
		http.Error(w, fmt.Sprintf("mapping service returned %d", resp.StatusCode), http.StatusBadGateway)
		return
	}
	var payload any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&payload); err != nil {
		http.Error(w, "decode mapping response: "+err.Error(), http.StatusBadGateway)
		return
	}
	n := 0
	if arr, ok := payload.([]any); ok {
		n = len(arr)
	}
	audit(tool, "allow", fmt.Sprintf(`"app_id":%q,"records":%d`, req.AppID, n))
	writeJSON(w, map[string]any{"app_id": req.AppID, "records": payload, "count": n})
}

func (s *server) ioEvents(w http.ResponseWriter, r *http.Request) {
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	s.proxyMapping(w, r, "io_events_query", "/events", req)
}

func (s *server) serviceNow(w http.ResponseWriter, r *http.Request) {
	req, ok := decodeReq(w, r)
	if !ok {
		return
	}
	s.proxyMapping(w, r, "servicenow_inc_chg", "/incidents", req)
}

// --- shared ES helper -----------------------------------------------------

// esSearch runs a search against an index pattern with the scoped API key and
// decodes into out. Access is bounded by the key's privileges: a pattern the
// key does not cover fails at Elasticsearch.
func (s *server) esSearch(r *http.Request, indexPattern string, query map[string]any, out any) error {
	body, err := json.Marshal(query)
	if err != nil {
		return err
	}
	esReq, err := http.NewRequestWithContext(r.Context(), http.MethodPost,
		fmt.Sprintf("%s/%s/_search", s.esURL, indexPattern), strings.NewReader(string(body)))
	if err != nil {
		return err
	}
	esReq.Header.Set("Content-Type", "application/json")
	esReq.Header.Set("Authorization", "ApiKey "+s.apiKey)
	resp, err := s.client.Do(esReq)
	if err != nil {
		return fmt.Errorf("elasticsearch unreachable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("elasticsearch returned %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// registerTools wires the tool handlers onto the mux.
func (s *server) registerTools(mux *http.ServeMux) {
	mux.HandleFunc("/tools/grafana_query_metrics", s.grafanaMetrics)
	mux.HandleFunc("/tools/observr_traces", s.observrTraces)
	mux.HandleFunc("/tools/drift_changes", s.driftChanges)
	mux.HandleFunc("/tools/cmdb_lookup_ci", s.cmdbLookup)
	mux.HandleFunc("/tools/io_events_query", s.ioEvents)
	mux.HandleFunc("/tools/servicenow_inc_chg", s.serviceNow)
	// Tool discovery: what this gateway offers and under which scope.
	mux.HandleFunc("/tools", func(w http.ResponseWriter, _ *http.Request) {
		names := make([]string, 0, len(scopeFor))
		for n := range scopeFor {
			names = append(names, n)
		}
		sort.Strings(names)
		list := make([]map[string]string, 0, len(names))
		for _, n := range names {
			list = append(list, map[string]string{"tool": n, "scope": scopeFor[n]})
		}
		writeJSON(w, map[string]any{"tools": list})
	})
}
