//go:build !frostdb

package store

// NewStoreFromEnv returns a SignalStore based on environment configuration.
// Without the frostdb build tag, only MemoryStore is available.
func NewStoreFromEnv(storeType, storeDir string) (SignalStore, error) {
	return NewMemoryStore(), nil
}
