package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/util/validation"
)

const maxWorkloadReportBytes = 1 << 20

// WorkloadReportResponse records the effect of one accepted warden report.
// RegistrySize is measured after replacement and stale-entry eviction, so the
// caller receives the same current-state count that subsequent reads observe.
type WorkloadReportResponse struct {
	ClusterID    string `json:"cluster_id"`
	Node         string `json:"node"`
	Accepted     int    `json:"accepted"`
	Evicted      int    `json:"evicted"`
	RegistrySize int    `json:"registry_size"`
}

// WorkloadListResponse wraps registry results so an empty registry is encoded
// as an empty JSON array rather than null. Portal callers can therefore iterate
// the field without treating the first report as a schema transition.
type WorkloadListResponse struct {
	Workloads []RegisteredWorkload `json:"workloads"`
	Count     int                  `json:"count"`
}

// fleetReportIntervalFrom accepts both forms used by the deployment contract:
// Go duration strings such as "60s", and bare integer counts of seconds such
// as "60". Invalid or non-positive values return the operational default with
// an error, allowing main to warn while preserving break-glass availability.
func fleetReportIntervalFrom(raw string) (time.Duration, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return DefaultFleetReportInterval, nil
	}

	if interval, err := time.ParseDuration(value); err == nil {
		if interval <= 0 {
			return DefaultFleetReportInterval, fmt.Errorf("FLEET_REPORT_INTERVAL %q must be positive", raw)
		}
		return interval, nil
	}

	seconds, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return DefaultFleetReportInterval, fmt.Errorf("FLEET_REPORT_INTERVAL %q must be a Go duration or integer seconds", raw)
	}
	if seconds <= 0 {
		return DefaultFleetReportInterval, fmt.Errorf("FLEET_REPORT_INTERVAL %q must be positive", raw)
	}

	interval, err := time.ParseDuration(value + "s")
	if err != nil {
		return DefaultFleetReportInterval, fmt.Errorf("FLEET_REPORT_INTERVAL %q is outside the supported duration range", raw)
	}
	return interval, nil
}

// handleWorkloadReport accepts a complete node snapshot from the warden. A nil
// registry is possible in focused unit tests that construct server directly,
// just as a nil enforcement selection is possible there; returning 503 keeps
// that missing dependency observable instead of turning it into a panic.
func (s *server) handleWorkloadReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.workloads == nil {
		writeError(w, http.StatusServiceUnavailable, "workload registry is not configured")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxWorkloadReportBytes)
	decoder := json.NewDecoder(r.Body)

	// Unknown fields are rejected deliberately. A misspelled warden field must
	// fail at the reporting boundary rather than disappear silently and leave
	// the portal presenting a plausible but incomplete workload record.
	decoder.DisallowUnknownFields()

	var report WorkloadReport
	if err := decoder.Decode(&report); err != nil {
		writeWorkloadDecodeError(w, err)
		return
	}

	// A second decode must reach EOF. Accepting concatenated JSON values would
	// make request interpretation depend on which decoder invocation a future
	// refactor happened to retain.
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err != nil {
			writeWorkloadDecodeError(w, err)
			return
		}
		writeError(w, http.StatusBadRequest, "request body must contain one JSON object")
		return
	}

	if err := report.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	receiptTime := s.workloads.now()
	accepted, evicted, err := s.workloads.Apply(report)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	registrySize := s.workloads.Len()

	reportedAt, err := time.Parse(time.RFC3339, report.ReportedAt)
	if err != nil {
		// Validate already accepted this value, so this branch protects the
		// logging invariant if validation and parsing ever diverge.
		writeError(w, http.StatusBadRequest, "reported_at must be an RFC3339 timestamp")
		return
	}

	slog.Info(
		"accepted fleet workload report",
		"cluster_id", report.ClusterID,
		"node", report.Node,
		"accepted", accepted,
		"evicted", evicted,
		"registry_size", registrySize,
		"reported_at_skew_ms", receiptTime.Sub(reportedAt).Milliseconds(),
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(WorkloadReportResponse{
		ClusterID:    report.ClusterID,
		Node:         report.Node,
		Accepted:     accepted,
		Evicted:      evicted,
		RegistrySize: registrySize,
	})
}

// writeWorkloadDecodeError preserves MaxBytesReader's typed size signal. JSON
// decoder text is not an API for classifying oversized requests and has changed
// across Go releases, whereas errors.As follows the wrapped MaxBytesError
// contract and reliably distinguishes 413 from malformed JSON's 400.
func writeWorkloadDecodeError(w http.ResponseWriter, err error) {
	var maxBytesError *http.MaxBytesError
	if errors.As(err, &maxBytesError) {
		writeError(w, http.StatusRequestEntityTooLarge, "workload report exceeds 1048576 bytes")
		return
	}
	writeError(w, http.StatusBadRequest, err.Error())
}

// handleWorkloads lists the registry for portal readers. The cluster filter is
// optional because the portal merges workloads across clusters, while wardens
// only report snapshots and never call this read endpoint.
func (s *server) handleWorkloads(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.workloads == nil {
		writeError(w, http.StatusServiceUnavailable, "workload registry is not configured")
		return
	}

	clusterID := r.URL.Query().Get("cluster_id")
	if clusterID != "" {
		if problems := validation.IsDNS1123Label(clusterID); len(problems) != 0 {
			writeError(w, http.StatusBadRequest, "cluster_id: "+strings.Join(problems, "; "))
			return
		}
	}

	workloads := s.workloads.List(clusterID)
	if workloads == nil {
		// Preserve the response schema even if a registry implementation later
		// changes List's internal empty-slice allocation strategy.
		workloads = make([]RegisteredWorkload, 0)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(WorkloadListResponse{
		Workloads: workloads,
		Count:     len(workloads),
	})
}
