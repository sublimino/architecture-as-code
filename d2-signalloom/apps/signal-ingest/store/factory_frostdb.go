//go:build frostdb

package store

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

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
	var options []FrostDBStoreOption
	if os.Getenv("SIGNAL_SEGMENT_ATTESTATION") == "1" {
		keysDir := os.Getenv("KEYS_DIR")
		if keysDir == "" {
			keysDir = ".keys"
		}
		evidenceDir := os.Getenv("SIGNAL_SEGMENT_EVIDENCE_DIR")
		if evidenceDir == "" {
			evidenceDir = storeDir
		}
		keyPath := os.Getenv("SIGNAL_SEGMENT_SIGNING_KEY")
		if keyPath == "" {
			keyPath = filepath.Join(keysDir, "witness.pem")
		}
		highWaterPath := os.Getenv("SIGNAL_SEGMENT_HIGHWATER")
		if highWaterPath == "" {
			highWaterPath = filepath.Join(keysDir, "signal-segment-highwater.json")
		}
		queueSize := 16
		if raw := os.Getenv("SIGNAL_SEGMENT_QUEUE_SIZE"); raw != "" {
			parsed, parseErr := strconv.Atoi(raw)
			if parseErr != nil || parsed <= 0 {
				return nil, fmt.Errorf("SIGNAL_SEGMENT_QUEUE_SIZE must be a positive integer")
			}
			queueSize = parsed
		}
		options = append(options, WithSegmentAttestation(SegmentAttestorConfig{
			SegmentRoot: storeDir, EvidenceDir: evidenceDir, PrivateKeyPath: keyPath, HighWaterPath: highWaterPath,
			ArchivistaURL: os.Getenv("ARCHIVISTA_URL"), RequireArchivista: os.Getenv("AUDIT_ANCHOR_REQUIRE_LOG") == "1", QueueSize: queueSize,
		}))
	}
	s, err := NewFrostDBStoreWithBucket(storeDir, options...)
	if err != nil {
		return nil, fmt.Errorf("frostdb store from env: %w", err)
	}
	return s, nil
}
