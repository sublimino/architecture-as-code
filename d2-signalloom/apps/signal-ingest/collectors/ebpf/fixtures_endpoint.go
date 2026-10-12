// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/netebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// endpointFixtureFS embeds the sentinel eBPF endpoint_host testdata so the e2e
// corpus replays deterministically wherever the binary runs — the same reasoning
// as collectors/k8saudit. Each file is a JSON ARRAY of the stun-sentinel's wire
// type (netebpf.InboundFlowEvent), one detection class per file so the e2e
// negative-discipline check can attribute an observation to its object.
//
//go:embed endpoint_testdata
var endpointFixtureFS embed.FS

// FixtureEndpointFiles returns the embedded endpoint fixture object names in
// stable (sorted) order, so a file added to endpoint_testdata/ flows into the
// e2e with no code edit.
func FixtureEndpointFiles() ([]string, error) {
	entries, err := fs.ReadDir(endpointFixtureFS, "endpoint_testdata")
	if err != nil {
		return nil, fmt.Errorf("ebpf: reading embedded endpoint_testdata: %w", err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

// FixtureEndpointObservations projects every embedded endpoint fixture event
// through ProjectEndpoint — the SAME code path production uses — so the e2e
// asserts the production projection and not a test-only corpus. The
// RawEvidenceRef is prefixed with the fixture file so the e2e negative-discipline
// check can attribute an observation to the object it came from.
//
// An event whose class is not an endpoint syscall (a stray network_connect in a
// fixture) is skipped by ProjectEndpoint, which is correct: it would belong to
// the netebpf network_egress corpus, not this one.
func FixtureEndpointObservations() ([]model.Observation, error) {
	files, err := FixtureEndpointFiles()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("ebpf: no embedded endpoint fixtures found; fixture mode would be vacuous")
	}
	var out []model.Observation
	for _, name := range files {
		body, err := endpointFixtureFS.ReadFile("endpoint_testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("ebpf: reading endpoint fixture %q: %w", name, err)
		}
		var evs []*netebpf.InboundFlowEvent
		if err := json.Unmarshal(body, &evs); err != nil {
			return nil, fmt.Errorf("ebpf: parsing endpoint fixture %q: %w", name, err)
		}
		ref := "endpoint_testdata/" + name
		for _, ev := range evs {
			if obs, ok := ProjectEndpoint(ev, ref); ok {
				out = append(out, obs)
			}
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("ebpf: endpoint fixture corpus projected nothing; every e2e assertion would be vacuous")
	}
	return out, nil
}
