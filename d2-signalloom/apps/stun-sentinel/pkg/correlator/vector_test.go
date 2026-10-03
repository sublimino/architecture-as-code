// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type vectorBatch struct {
	Seq  uint64 `json:"seq"`
	Prev string `json:"prev"`
	Body string `json:"body"`
}

func TestBatchChainPrevVector(t *testing.T) {
	candidatePaths := []string{
		filepath.Join("..", "..", "..", "signal-ingest", "api", "testdata", "batch-chain-vector.json"),
		filepath.Join("..", "..", "signal-ingest", "api", "testdata", "batch-chain-vector.json"),
		filepath.Join("..", "signal-ingest", "api", "testdata", "batch-chain-vector.json"),
		filepath.Join("d2-signalloom", "apps", "signal-ingest", "api", "testdata", "batch-chain-vector.json"),
	}

	var data []byte
	var loadedPath string
	var err error

	for _, p := range candidatePaths {
		data, err = os.ReadFile(p)
		if err == nil {
			loadedPath = p
			break
		}
	}

	if data == nil {
		t.Fatalf("could not load batch-chain-vector.json from candidate paths: %v", err)
	}

	t.Logf("Loaded vector data from %s (%d bytes)", loadedPath, len(data))

	var vector []vectorBatch
	if err := json.Unmarshal(data, &vector); err != nil {
		t.Fatalf("unmarshal batch-chain-vector.json: %v", err)
	}

	if len(vector) < 3 {
		t.Fatalf("expected at least 3 vector batches, got %d", len(vector))
	}

	var lastPrev string
	for i, vb := range vector {
		expectedSeq := uint64(i + 1)
		if vb.Seq != expectedSeq {
			t.Errorf("batch[%d] seq = %d, want %d", i, vb.Seq, expectedSeq)
		}

		// Sequence 1 must have empty prev header
		if vb.Seq == 1 {
			if vb.Prev != "" {
				t.Errorf("batch[0] (seq 1) prev = %q, want empty string", vb.Prev)
			}
		} else {
			if vb.Prev != lastPrev {
				t.Errorf("batch[%d] (seq %d) prev = %q, want %q", i, vb.Seq, vb.Prev, lastPrev)
			}
		}

		// Compute prev hash for next iteration
		sum := sha256.Sum256([]byte(vb.Body))
		lastPrev = hex.EncodeToString(sum[:])
	}
}
