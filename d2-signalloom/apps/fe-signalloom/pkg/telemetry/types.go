package telemetry

import (
	"time"
)

// MetricSample represents a single point-in-time metrics sample scraped for a container.
type MetricSample struct {
	Timestamp       time.Time `json:"timestamp"`
	CpuSecondsTotal float64   `json:"cpu_seconds_total"`
	MemoryRssBytes  uint64    `json:"memory_rss_bytes"`
	ThrottleCount   uint64    `json:"throttle_count"`
}

// AgentTelemetry represents processed live telemetry for an agent pod with calculated rate and memory.
type AgentTelemetry struct {
	PodName     string    `json:"pod_name"`
	Namespace   string    `json:"namespace"`
	Millicores  float64   `json:"millicores"`
	MemoryRssMB float64   `json:"memory_rss_mb"`
	Status      string    `json:"status"`
	LastUpdated time.Time `json:"last_updated"`
}
