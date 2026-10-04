//go:build !frostdb

package store

import "fmt"

// NewStoreFromEnv returns a SignalStore based on environment configuration.
// Without the frostdb build tag only MemoryStore is available. Asking for frostdb from a
// binary that cannot provide it is refused rather than silently downgraded: a deployment
// that selects the durable store (SLAWS v2 D1, base/deployment.yaml) must not boot into RAM
// because an image was built without -tags frostdb. main exits non-zero on this error.
func NewStoreFromEnv(storeType, storeDir string) (SignalStore, error) {
	if storeType == "frostdb" {
		return nil, fmt.Errorf("store: SIGNAL_STORE=frostdb requested but this binary was built without -tags frostdb; refusing to fall back to the in-memory store (dir %q)", storeDir)
	}
	return NewMemoryStore(), nil
}
