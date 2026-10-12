// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package e2e

import (
	"sort"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/k8saudit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// This is the estate-wide L2 half of the coverage gate, and it is frostdb-tagged
// for the same reason the k8saudit L2 check is: store.DefaultLabelAllowListKeys
// only exists under -tags frostdb, and that is the whole point of the check. A
// rule can have green memory-store fixtures (assertion 2) and a covered layer
// (assertion 1) and STILL be dead under the real store, because the frostdb
// Append refuses any batch carrying a label key the segment allow-list does not
// name — before a single Arrow record is built. Only a tagged test sees that
// refusal; an untagged one is structurally blind to it.
//
// collectorProjectedKeys enumerates the projected-key contract of every
// collector that EXPOSES one. Today that is two: k8saudit.ProjectedKeys and
// awslogs.ContractKeysFor over its four sources. The remaining shipped collectors
// (gcpaudit, netebpf, ebpf, baoaudit, agentnono, workspacesaas, and the
// identity-auth projection) do not expose a programmatic projected-key contract,
// so this gate cannot enumerate them estate-wide without a collector change —
// which is out of scope for a test-only card and is reported, not worked around.
// When a collector grows a ProjectedKeys-style contract, add it here and its keys
// come under the gate automatically.
func collectorProjectedKeys() map[string][]string {
	awsSources := []string{
		awslogs.SourceCloudTrail,
		awslogs.SourceIAM,
		awslogs.SourceVPCFlow,
		awslogs.SourceCollector,
	}
	awsKeys := map[string]struct{}{}
	for _, src := range awsSources {
		_, documented := awslogs.ContractKeysFor(src)
		for _, k := range documented {
			awsKeys[k] = struct{}{}
		}
	}
	aws := make([]string, 0, len(awsKeys))
	for k := range awsKeys {
		aws = append(aws, k)
	}
	sort.Strings(aws)

	return map[string][]string{
		"k8saudit": k8saudit.ProjectedKeys(),
		"awslogs":  aws,
	}
}

// TestPolicyCoverageMatrix_EstateProjectedKeysAllowListed asserts assertion 3:
// every label key any contract-exposing collector projects is in the store's
// default allow-list. A projected key that is not allow-listed is a batch the
// frostdb store refuses at runtime, so this gate turns that production refusal
// into a build-time failure.
func TestPolicyCoverageMatrix_EstateProjectedKeysAllowListed(t *testing.T) {
	allowed := map[string]bool{}
	for _, k := range store.DefaultLabelAllowListKeys() {
		allowed[k] = true
	}
	if len(allowed) == 0 {
		t.Fatalf("store.DefaultLabelAllowListKeys() is empty; the L2 gate has nothing to check against")
	}

	byCollector := collectorProjectedKeys()
	// Deterministic collector order so the output reads the same every run.
	names := make([]string, 0, len(byCollector))
	for name := range byCollector {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		keys := byCollector[name]
		if len(keys) == 0 {
			t.Errorf("collector %q exposes a projected-key contract but it is empty; a contract with no keys proves nothing", name)
			continue
		}
		for _, k := range keys {
			if !allowed[k] {
				t.Errorf("collector %q projects label key %q which is NOT in store.DefaultLabelAllowListKeys(); "+
					"a frostdb Append would refuse the batch before building any Arrow record", name, k)
			}
		}
		t.Logf("collector %q: %d projected keys, all allow-listed", name, len(keys))
	}
}
