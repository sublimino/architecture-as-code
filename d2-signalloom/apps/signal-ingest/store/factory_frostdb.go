//go:build frostdb

package store

import "fmt"

// NewStoreFromEnv returns a SignalStore based on environment configuration.
// With the frostdb build tag, SIGNAL_STORE=frostdb activates FrostDB with
// Parquet durability to SIGNAL_STORE_DIR (default /tmp/signal-store).
func NewStoreFromEnv(storeType, storeDir string) (SignalStore, error) {
	if storeType != "frostdb" {
		return NewMemoryStore(), nil
	}
	if storeDir == "" {
		storeDir = "/tmp/signal-store"
	}
	s, err := NewFrostDBStoreWithBucket(storeDir)
	if err != nil {
		return nil, fmt.Errorf("frostdb store from env: %w", err)
	}
	return s, nil
}
