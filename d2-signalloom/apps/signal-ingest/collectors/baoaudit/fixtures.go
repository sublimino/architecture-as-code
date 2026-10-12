// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package baoaudit

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// fixtureFS embeds the OpenBao audit-event testdata so fixture mode and e2e
// replay exercise the same production projection everywhere the binary runs.
//
//go:embed testdata
var fixtureFS embed.FS

// FixtureFiles returns embedded fixture object names in stable order.
func FixtureFiles() ([]string, error) {
	entries, err := fs.ReadDir(fixtureFS, "testdata")
	if err != nil {
		return nil, fmt.Errorf("baoaudit: reading embedded testdata: %w", err)
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

// FixtureObservations projects every embedded OpenBao audit event array through
// the receiver projection. RawEvidenceRef is rewritten to include the fixture
// file so e2e negative checks can attribute observations to objects.
func FixtureObservations() ([]model.Observation, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("baoaudit: no embedded fixtures found; fixture mode would be vacuous")
	}

	var out []model.Observation
	receiver := &AuditReceiver{}
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("baoaudit: reading fixture %q: %w", name, err)
		}
		var events []OpenBaoAuditEvent
		if err := json.Unmarshal(body, &events); err != nil {
			return nil, fmt.Errorf("baoaudit: parsing fixture %q: %w", name, err)
		}
		for i := range events {
			obs := receiver.convertToObservation(&events[i])
			if obs == nil {
				continue
			}
			obs.RawEvidenceRef = fmt.Sprintf("testdata/%s#%s", name, obs.ID)
			out = append(out, *obs)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("baoaudit: fixture corpus projected nothing; every e2e assertion would be vacuous")
	}
	return out, nil
}
