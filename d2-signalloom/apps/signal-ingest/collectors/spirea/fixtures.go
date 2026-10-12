// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package spirea

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// fixtureFS embeds the SPIRE SVID issuance testdata so the identity_authorization
// fixture corpus is reproducible wherever the binary runs, the same reasoning as
// collectors/k8saudit: reading off disk at runtime would couple the demo to the
// working directory.
//
//go:embed testdata
var fixtureFS embed.FS

// FixtureFiles returns the embedded fixture object names in a stable (sorted)
// order, so the e2e corpus replays deterministically and a file added to
// testdata/ flows into it with no code edit.
func FixtureFiles() ([]string, error) {
	entries, err := fs.ReadDir(fixtureFS, "testdata")
	if err != nil {
		return nil, fmt.Errorf("spirea: reading embedded testdata: %w", err)
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

// captureSink collects the observations the collector would push downstream, so
// FixtureObservations exercises the PRODUCTION projection (IngestIssuanceEvent ->
// convertToObservation) rather than a test-only copy of it.
type captureSink struct {
	out []*model.Observation
}

// IngestObservation implements IngestionSink by accumulating the observation.
func (c *captureSink) IngestObservation(_ context.Context, obs *model.Observation) error {
	c.out = append(c.out, obs)
	return nil
}

// FixtureObservations projects every embedded SVID-issuance fixture through the
// real collector conversion path. The RawEvidenceRef is rewritten to the fixture
// file so the e2e negative-discipline check can attribute an observation to the
// object it came from — the production labels and actor, which are what the rules
// read, are left exactly as the collector projects them.
func FixtureObservations() ([]model.Observation, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("spirea: no embedded fixtures found; fixture mode would be vacuous")
	}

	var out []model.Observation
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("spirea: reading fixture %q: %w", name, err)
		}
		var events []SVIDIssuanceEvent
		if err := json.Unmarshal(body, &events); err != nil {
			return nil, fmt.Errorf("spirea: parsing fixture %q: %w", name, err)
		}
		if len(events) == 0 {
			return nil, fmt.Errorf("spirea: fixture %q holds no events; its assertions would be vacuous", name)
		}

		sink := &captureSink{}
		sc := NewSPIREIssuanceCollector(sink)
		for i := range events {
			if err := sc.IngestIssuanceEvent(context.Background(), &events[i]); err != nil {
				return nil, fmt.Errorf("spirea: projecting fixture %q event %d: %w", name, i, err)
			}
		}

		ref := fmt.Sprintf("testdata/%s", name)
		for _, obs := range sink.out {
			obs.RawEvidenceRef = ref
			out = append(out, *obs)
		}
	}

	if len(out) == 0 {
		return nil, fmt.Errorf("spirea: fixture corpus projected nothing; every e2e assertion would be vacuous")
	}
	return out, nil
}
