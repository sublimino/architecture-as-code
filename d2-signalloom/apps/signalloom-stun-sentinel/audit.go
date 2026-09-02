package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// stunEvent represents a structured JSON audit event emitted for containment
// decisions, state transitions, lifecycle events, and reconciliation operations.
type stunEvent struct {
	Timestamp       string                 `json:"timestamp"`
	Event           string                 `json:"event"`
	Pod             string                 `json:"pod,omitempty"`
	Namespace       string                 `json:"namespace,omitempty"`
	UID             string                 `json:"uid,omitempty"`
	DryRun          bool                   `json:"dry_run,omitempty"`
	Latency         string                 `json:"latency_ms,omitempty"`
	CgroupPath      string                 `json:"cgroup_path,omitempty"`
	HostVeth        string                 `json:"host_veth,omitempty"`
	TCIngressFilter string                 `json:"tc_ingress_filter,omitempty"`
	TCEgressFilter  string                 `json:"tc_egress_filter,omitempty"`
	Decision        string                 `json:"decision,omitempty"`
	ProbesCount     int                    `json:"probes_count,omitempty"`
	ReconcileCount  int64                  `json:"reconcile_count,omitempty"`
	Error           string                 `json:"error,omitempty"`
	Details         map[string]interface{} `json:"details,omitempty"`
}

// AuditLogger manages thread-safe output of structured JSON audit lines.
type AuditLogger struct {
	mu  sync.Mutex
	out io.Writer
}

var defaultAuditLogger = &AuditLogger{out: os.Stdout}

// SetAuditOutput sets the destination writer for the global audit logger (e.g. for testing).
func SetAuditOutput(w io.Writer) {
	defaultAuditLogger.mu.Lock()
	defer defaultAuditLogger.mu.Unlock()
	defaultAuditLogger.out = w
}

// Log writes a single JSON-encoded audit event followed by a newline.
func (l *AuditLogger) Log(event stunEvent) {
	if event.Timestamp == "" {
		event.Timestamp = now()
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	out := l.out
	if out == nil {
		out = os.Stdout
	}
	_ = json.NewEncoder(out).Encode(event)
}

func logEvent(event stunEvent) {
	defaultAuditLogger.Log(event)
}

func now() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

// ValidateAuditEvent parses raw JSON bytes and verifies that mandatory audit fields are present.
func ValidateAuditEvent(data []byte) (*stunEvent, error) {
	var ev stunEvent
	if err := json.Unmarshal(data, &ev); err != nil {
		return nil, fmt.Errorf("invalid audit JSON: %w", err)
	}
	if ev.Timestamp == "" {
		return nil, fmt.Errorf("audit event missing mandatory 'timestamp' field")
	}
	if ev.Event == "" {
		return nil, fmt.Errorf("audit event missing mandatory 'event' field")
	}
	return &ev, nil
}
