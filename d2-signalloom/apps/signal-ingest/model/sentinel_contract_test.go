// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package model

import (
	"encoding/json"
	"os"
	"testing"
)

// The stun-sentinel correlator posts observations to POST /api/v1/observations.
// For weeks every one of them was a 400: it sent a single object in its own
// shape, while the handler decodes a JSON ARRAY of Observation and Validate()
// requires id, timestamp, layer, fidelity and source. The correlator now emits
// the golden file below, and this test holds signal-ingest to accepting it with
// the same decode and the same Validate the handler uses. If either side
// changes shape alone, one of the two suites goes red.
const sentinelGolden = "../../stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"

func TestSentinelCorrelatorPayloadIsAcceptedByTheObservationContract(t *testing.T) {
	raw, err := os.ReadFile(sentinelGolden)
	if err != nil {
		t.Fatalf("read the correlator's contract file: %v", err)
	}
	var batch []Observation
	if err := json.Unmarshal(raw, &batch); err != nil {
		t.Fatalf("handler decode of the correlator payload fails: %v", err)
	}
	if len(batch) == 0 {
		t.Fatal("contract file holds no observations")
	}
	for i, o := range batch {
		if err := o.Validate(); err != nil {
			t.Fatalf("observation[%d] rejected by Validate: %v", i, err)
		}
		if o.Labels["syscall"] == "" || o.Labels["target"] == "" || o.Labels["pod_name"] == "" {
			t.Fatalf("observation[%d] lost the Shared Pattern 2 labels the containment suite reads: %v", i, o.Labels)
		}
	}
}
