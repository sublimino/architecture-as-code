// elk-search-mcp is the first read-only MCP tool of the replica: log search
// over the seeded Elasticsearch under scope elk.logs.read.
//
// Controls this server enforces:
//   - The server holds only a scoped API key, created by the pod's init
//     container.
//   - Index patterns outside the three allowed ones are refused.
//   - Query caps: max docs and max time range, enforced server-side.
//   - Every query is audit-logged.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/acme-co/osramp/olly-replica/apps/internal/model"
)

var allowedPatterns = []string{"app-logs-*", "infra-logs-*", "audit-logs-*"}

type server struct {
	esURL    string
	apiKey   string // the "encoded" form from the ES create-api-key response
	maxDocs  int
	maxRange int // minutes
	client   *http.Client

	// Backing sources for the rest of the tool surface (see tools.go).
	promURL     string
	mappingURL  string
	tracesIndex string
	tenantPort  string

	// COIN token validation on the /mcp transport (see authz.go).
	authzEnabled bool
	authzSecret  string
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	var v int
	if _, err := fmt.Sscanf(os.Getenv(key), "%d", &v); err == nil && v > 0 {
		return v
	}
	return def
}

func loadAPIKey(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var key struct {
		Encoded string `json:"encoded"`
	}
	if err := json.Unmarshal(raw, &key); err != nil {
		return "", fmt.Errorf("parse api key file: %w", err)
	}
	if key.Encoded == "" {
		return "", fmt.Errorf("api key file %s has no encoded key", path)
	}
	return key.Encoded, nil
}

func (s *server) search(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req model.SearchRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}

	allowed := false
	for _, p := range allowedPatterns {
		if req.IndexPattern == p {
			allowed = true
			break
		}
	}
	if !allowed {
		log.Printf(`AUDIT {"tool":"elk_search_logs","scope":"elk.logs.read","decision":"deny","reason":"index pattern not allowed","index_pattern":%q}`, req.IndexPattern)
		http.Error(w, fmt.Sprintf("index pattern %q is not allowed; allowed: %s", req.IndexPattern, strings.Join(allowedPatterns, ", ")), http.StatusForbidden)
		return
	}
	if req.Size <= 0 || req.Size > s.maxDocs {
		req.Size = s.maxDocs
	}
	if req.TimeRangeMinutes <= 0 || req.TimeRangeMinutes > s.maxRange {
		req.TimeRangeMinutes = s.maxRange
	}

	esQuery := map[string]any{
		"size": req.Size,
		"sort": []any{map[string]any{"@timestamp": map[string]any{"order": "desc"}}},
		"query": map[string]any{
			"bool": map[string]any{
				"must": []any{map[string]any{"query_string": map[string]any{"query": req.Query}}},
				"filter": []any{map[string]any{"range": map[string]any{"@timestamp": map[string]any{
					"gte": fmt.Sprintf("now-%dm", req.TimeRangeMinutes),
				}}}},
			},
		},
	}
	body, _ := json.Marshal(esQuery)
	esReq, _ := http.NewRequestWithContext(r.Context(), http.MethodPost,
		fmt.Sprintf("%s/%s/_search", s.esURL, req.IndexPattern), bytes.NewReader(body))
	esReq.Header.Set("Content-Type", "application/json")
	esReq.Header.Set("Authorization", "ApiKey "+s.apiKey)

	resp, err := s.client.Do(esReq)
	if err != nil {
		http.Error(w, "elasticsearch unreachable: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		http.Error(w, fmt.Sprintf("elasticsearch returned %d: %s", resp.StatusCode, msg), http.StatusBadGateway)
		return
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
					Level     string `json:"level"`
					Message   string `json:"message"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&esResp); err != nil {
		http.Error(w, "decode elasticsearch response: "+err.Error(), http.StatusBadGateway)
		return
	}

	out := model.SearchResponse{DocCount: esResp.Hits.Total.Value}
	for _, h := range esResp.Hits.Hits {
		out.Hits = append(out.Hits, model.LogHit{
			Timestamp: h.Source.Timestamp,
			AppID:     h.Source.AppID,
			Level:     h.Source.Level,
			Message:   h.Source.Message,
		})
	}

	log.Printf(`AUDIT {"tool":"elk_search_logs","scope":"elk.logs.read","decision":"allow","index_pattern":%q,"query":%q,"doc_count":%d}`,
		req.IndexPattern, req.Query, out.DocCount)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func main() {
	esURL := env("ES_URL", "http://olly-es-http:9200")
	keyFile := env("API_KEY_FILE", "/var/run/olly/es-apikey.json")

	var apiKey string
	var err error
	for i := 0; i < 60; i++ {
		if apiKey, err = loadAPIKey(keyFile); err == nil {
			break
		}
		log.Printf("waiting for scoped api key at %s: %v", keyFile, err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("no scoped api key available: %v", err)
	}

	s := &server{
		esURL:       esURL,
		apiKey:      apiKey,
		maxDocs:     envInt("MAX_DOCS", 100),
		maxRange:    envInt("MAX_RANGE_MINUTES", 1440),
		client:      &http.Client{Timeout: 15 * time.Second},
		promURL:     strings.TrimRight(env("PROM_URL", "http://kube-prometheus-stack-prometheus.monitoring:9090"), "/"),
		mappingURL:  strings.TrimRight(env("MAPPING_URL", "http://io-mapping-stub:8080"), "/"),
		tracesIndex:  env("TRACES_INDEX", "traces-*"),
		tenantPort:   env("TENANT_PORT", ":8080"),
		authzEnabled: env("AUTHZ_ENABLED", "true") == "true",
		authzSecret:  env("AUTHZ_JWT_SECRET", "acme-co-authz-dev-secret"),
	}

	mux := http.NewServeMux()
	// REST endpoints, one per tool, for direct scope-denial checks.
	mux.HandleFunc("/tools/elk_search_logs", s.search)
	s.registerTools(mux)
	// MCP JSON-RPC endpoint: the transport the sentinel connects to as an MCP
	// client. It dispatches to the same handlers the REST paths use.
	toolHandlers := map[string]http.HandlerFunc{
		"elk_search_logs":       s.search,
		"grafana_query_metrics": s.grafanaMetrics,
		"observr_traces":        s.observrTraces,
		"drift_changes":         s.driftChanges,
		"cmdb_lookup_ci":        s.cmdbLookup,
		"io_events_query":       s.ioEvents,
		"servicenow_inc_chg":    s.serviceNow,
	}
	mux.HandleFunc("/mcp", s.handleMCP(toolHandlers))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	listen := env("LISTEN", ":8080")
	log.Printf("olly-mcp listening on %s (%d tools over MCP JSON-RPC at /mcp, log patterns %s, max_docs=%d, max_range=%dm)",
		listen, len(scopeFor), strings.Join(allowedPatterns, ","), s.maxDocs, s.maxRange)
	log.Fatal(http.ListenAndServe(listen, mux))
}
