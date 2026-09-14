package privacy

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
)

// ErrDestructionNotImplemented is returned by UnimplementedKeyDestroyer.
var ErrDestructionNotImplemented = errors.New("key destruction is not implemented in this build: the per-subject key hierarchy and erasure saga are SLDP-P4-1")

// UnimplementedKeyDestroyer is the KeyDestroyer wired into production until SLDP-P4-1 lands.
//
// It refuses. That is the entire design, and the alternative was considered and rejected: a stub
// that returned a plausible receipt would make every gate above it appear to work end to end while
// destroying nothing, so the first genuine erasure would be reported complete to a data subject and
// to a regulator without having happened. A false "erased" is a misstatement; a loud refusal is an
// unfinished feature. This is also why there is no development opt-in — for encryption a passthrough
// yields weaker data that still exists, whereas for destruction a passthrough in either direction
// is a lie about an irreversible act.
//
// It logs at Error rather than Warn deliberately: reaching this code means every gate passed and an
// erasure was authorised, so the request is legitimate and is now blocked by an unfinished
// dependency. That is an operational problem someone must see.
type UnimplementedKeyDestroyer struct{}

// DestroySubjectKeys implements KeyDestroyer by refusing.
func (UnimplementedKeyDestroyer) DestroySubjectKeys(_ context.Context, tenantID, subjectID string) (KeyDestructionReceipt, error) {
	slog.Error("erasure was authorised but cannot be performed: no key destroyer is implemented",
		"tenant_id", tenantID,
		"subject_pseudonym_required", true,
		"next_card", "SLDP-P4-1")
	return KeyDestructionReceipt{}, fmt.Errorf("%w (tenant %q)", ErrDestructionNotImplemented, tenantID)
}

// RecordingKeyDestroyer records destruction calls without touching key material.
//
// It exists for integration environments that need to exercise the whole path, and it is in
// non-test code deliberately so that the one place a "destroyer that does not destroy" lives is
// named, greppable and obviously not production. It still returns a receipt, so unlike
// UnimplementedKeyDestroyer it must never be wired into a deployment that reports to a data
// subject.
// The mutex is not optional despite this being a recording type. It is shipped non-test code
// intended for integration deployments, which serve concurrent HTTP requests, and an unsynchronised
// append races the slice header: lost receipts, or worse. `go test -race` staying clean here proves
// only that no test drives it concurrently — absence of a race report is absence of coverage, not
// evidence of safety.
type RecordingKeyDestroyer struct {
	mu    sync.Mutex
	calls []KeyDestructionReceipt
}

// DestroySubjectKeys implements KeyDestroyer by recording the call.
func (r *RecordingKeyDestroyer) DestroySubjectKeys(_ context.Context, tenantID, subjectID string) (KeyDestructionReceipt, error) {
	receipt := KeyDestructionReceipt{TenantID: tenantID, SubjectID: subjectID}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, receipt)
	return receipt, nil
}

// Calls returns a snapshot of the recorded destructions.
func (r *RecordingKeyDestroyer) Calls() []KeyDestructionReceipt {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]KeyDestructionReceipt, len(r.calls))
	copy(out, r.calls)
	return out
}
