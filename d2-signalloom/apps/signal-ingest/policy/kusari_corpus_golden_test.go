// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

const fixedCorpusTestKeyHex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

// TestKusariCorpusGoldenIsCurrent writes pkg/obscel/testdata/kusari-corpus.json
// (projected observations, cleartext actors) and kusari-canonical-findings.txt
// (obscel.CanonicalFinding lines under fixed test key, epoch 1, tenant kusari)
// and fails when stale.
func TestKusariCorpusGoldenIsCurrent(t *testing.T) {
	rootKey, err := hex.DecodeString(fixedCorpusTestKeyHex)
	if err != nil {
		t.Fatalf("DecodeString: %v", err)
	}

	testdataDir := filepath.Join("..", "..", "..", "pkg", "obscel", "testdata")
	if err := os.MkdirAll(testdataDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", testdataDir, err)
	}

	rawCorpus := e2eCorpus(t)
	SortObservations(rawCorpus)

	// 1. Build cleartext obscel observations for kusari-corpus.json
	cleartextObs := make([]obscel.Observation, len(rawCorpus))
	for i := range rawCorpus {
		obs, err := toObscel(&rawCorpus[i], nil)
		if err != nil {
			t.Fatalf("toObscel(%s): %v", rawCorpus[i].ID, err)
		}
		cleartextObs[i] = obs
	}

	corpusJSON, err := json.MarshalIndent(cleartextObs, "", "  ")
	if err != nil {
		t.Fatalf("MarshalIndent: %v", err)
	}
	corpusJSON = append(corpusJSON, '\n')

	corpusPath := filepath.Join(testdataDir, "kusari-corpus.json")
	checkOrWrite(t, corpusPath, corpusJSON)

	// 2. Compute canonical findings using the fixed test key and epoch 1
	ps, err := obscel.NewHMACPseudonymiser(rootKey, e2eTenant, 1)
	if err != nil {
		t.Fatalf("NewHMACPseudonymiser: %v", err)
	}

	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t), ps)
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}

	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	var canonicalLines []string
	for _, raw := range rawCorpus {
		obs, err := toObscel(&raw, ps)
		if err != nil {
			t.Fatalf("toObscel with pseudonymiser: %v", err)
		}
		for _, b := range bundles {
			if b.TenantID != e2eTenant {
				continue
			}
			findings, err := evaluator.EvaluateObservation(obs, b)
			if err != nil {
				t.Fatalf("EvaluateObservation: %v", err)
			}
			for _, f := range findings {
				canonicalLines = append(canonicalLines, obscel.CanonicalFinding(f))
			}
		}
	}

	sort.Strings(canonicalLines)
	if len(canonicalLines) == 0 {
		t.Fatal("evaluating corpus produced 0 findings; golden would be empty")
	}

	findingsText := strings.Join(canonicalLines, "\n") + "\n"
	findingsPath := filepath.Join(testdataDir, "kusari-canonical-findings.txt")
	checkOrWrite(t, findingsPath, []byte(findingsText))
}

func checkOrWrite(t *testing.T, path string, want []byte) {
	t.Helper()
	existing, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if err := os.WriteFile(path, want, 0o644); err != nil {
				t.Fatalf("WriteFile(%s): %v", path, err)
			}
			t.Logf("wrote golden file %s (%d bytes)", path, len(want))
			return
		}
		t.Fatalf("ReadFile(%s): %v", path, err)
	}

	if string(existing) != string(want) {
		// If UPDATE_GOLDEN is set, write the updated content
		if os.Getenv("UPDATE_GOLDEN") == "1" {
			if err := os.WriteFile(path, want, 0o644); err != nil {
				t.Fatalf("WriteFile(%s): %v", path, err)
			}
			t.Logf("updated golden file %s", path)
			return
		}
		t.Fatalf("golden file %s is stale (differs from freshly computed). Run with UPDATE_GOLDEN=1 to regenerate", path)
	}
}
