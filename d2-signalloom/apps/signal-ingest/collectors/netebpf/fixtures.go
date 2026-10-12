// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netebpf

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// fixtureFS embeds the socket-trace testdata so fixture mode is reproducible
// wherever the binary runs — the same reasoning as collectors/k8saudit: reading
// off disk at runtime would couple the demo and the e2e to the working directory.
//
// Each file is a JSON ARRAY of InboundFlowEvent, one detection class per file so
// the e2e negative-discipline check can attribute an observation to its object.
//
//go:embed testdata
var fixtureFS embed.FS

// FixtureFiles returns the embedded fixture object names in stable (sorted)
// order, so fixture mode and the e2e corpus replay deterministically and a file
// added to testdata/ flows into both with no code edit.
func FixtureFiles() ([]string, error) {
	entries, err := fs.ReadDir(fixtureFS, "testdata")
	if err != nil {
		return nil, fmt.Errorf("netebpf: reading embedded testdata: %w", err)
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

// FixtureEvents parses every embedded fixture into InboundFlowEvents, in file
// order. A file that is not a JSON array of events is a hard error: a silently
// skipped fixture would make the e2e counts drift with no failure.
func FixtureEvents() ([]*InboundFlowEvent, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("netebpf: no embedded fixtures found; fixture mode would be vacuous")
	}
	var out []*InboundFlowEvent
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("netebpf: reading fixture %q: %w", name, err)
		}
		var evs []*InboundFlowEvent
		if err := json.Unmarshal(body, &evs); err != nil {
			return nil, fmt.Errorf("netebpf: parsing fixture %q: %w", name, err)
		}
		out = append(out, evs...)
	}
	return out, nil
}

// FixtureObservations projects every embedded fixture event through the SAME
// flowToObservation code path production uses, so the e2e asserts the production
// projection and not a test-only corpus. The RawEvidenceRef is prefixed with the
// fixture file so the e2e negative-discipline check can attribute an observation
// to the object it came from.
func FixtureObservations() ([]model.Observation, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	var proj LiveNetworkEgressCollector // flowToObservation reads only the event
	var out []model.Observation
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("netebpf: reading fixture %q: %w", name, err)
		}
		var evs []*InboundFlowEvent
		if err := json.Unmarshal(body, &evs); err != nil {
			return nil, fmt.Errorf("netebpf: parsing fixture %q: %w", name, err)
		}
		for _, ev := range evs {
			obs := proj.flowToObservation(ev)
			obs.RawEvidenceRef = "testdata/" + name
			out = append(out, *obs)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("netebpf: fixture corpus projected nothing; every e2e assertion would be vacuous")
	}
	return out, nil
}
