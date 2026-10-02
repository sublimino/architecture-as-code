package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// FileWriter appends every audit event to a file as one JSON line. It is the sink for a local run
// without Postgres (SIGNAL_AUDIT_FILE), and it is fail-closed: a write that cannot persist returns
// the error, so the router refuses rather than acting unaudited.
type FileWriter struct {
	mu sync.Mutex
	f  *os.File
}

// NewFileWriter opens path for appending, creating it with mode 0600.
func NewFileWriter(path string) (*FileWriter, error) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("audit file: %w", err)
	}
	return &FileWriter{f: f}, nil
}

// WriteAuditEvent appends event, stamping CreatedAt when unset.
func (w *FileWriter) WriteAuditEvent(_ context.Context, event Event) error {
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	line, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("audit file: encode: %w", err)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if _, err := w.f.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("audit file: write: %w", err)
	}
	return nil
}

// AuditPosture reports a healthy, fail-closed file backend.
func (w *FileWriter) AuditPosture() AuditPosture {
	return AuditPosture{Backend: "file", Mode: "enforced", Policy: "fail_closed", Healthy: true}
}

// Close closes the file; later writes fail.
func (w *FileWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.f.Close()
}
