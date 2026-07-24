// Prometheus query proxy, broker side.
//
// The native Eye in the Sky overview (ui/agentic-sre.html) reads the same
// metrics the Grafana estate and SRE dashboards read. Rather than embed a
// Grafana iframe, the page issues PromQL through this proxy and renders the
// numbers itself. One route:
//
//	GET /api/metrics/query?q=<promql>[&time=<unix>]  -> Prometheus instant query
//	(time is optional; it evaluates the query as of a past instant so the
//	dashboard can show historical data, the same way Grafana's time range does)
//
// It forwards to Prometheus in the monitoring namespace through the same
// supervised port-forward pool the rest of the console uses.
package main

import (
	"io"
	"net/http"
	"net/url"
	"time"
)

func (c *console) registerMetrics(mux *http.ServeMux) {
	mux.HandleFunc("/api/metrics/query", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "" {
			http.Error(w, "missing q", http.StatusBadRequest)
			return
		}
		local, err := c.pf.get("prometheus")
		if err != nil {
			clusterUnavailable(w, "Prometheus (monitoring namespace)", err)
			return
		}
		target := "http://" + local + "/api/v1/query?query=" + url.QueryEscape(q)
		// Historical view: the dashboard passes &time=<unix> to evaluate the
		// query as of a past instant (Grafana-style time range), so data that
		// already exists still renders when live ingestion has paused. Absent
		// or empty means "now", the default instant query.
		if t := r.URL.Query().Get("time"); t != "" {
			target += "&time=" + url.QueryEscape(t)
		}
		client := &http.Client{Timeout: 12 * time.Second}
		resp, err := client.Get(target)
		if err != nil {
			clusterUnavailable(w, "Prometheus", err)
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(body)
	})
}
