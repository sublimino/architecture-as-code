// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// fixtureFS embeds the audit-event testdata so fixture mode is reproducible
// wherever the binary runs — the same reasoning as awslogs: reading off disk at
// runtime would couple the demo to the working directory.
//
//go:embed testdata
var fixtureFS embed.FS

// FixtureFiles returns the embedded fixture object names in a stable (sorted)
// order, so fixture mode and the e2e corpus replay deterministically and a file
// added to testdata/ flows into both with no code edit.
func FixtureFiles() ([]string, error) {
	entries, err := fs.ReadDir(fixtureFS, "testdata")
	if err != nil {
		return nil, fmt.Errorf("k8saudit: reading embedded testdata: %w", err)
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

// FixtureEvents parses every embedded fixture into audit events, in file order.
func FixtureEvents() ([]AuditEvent, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("k8saudit: no embedded fixtures found; fixture mode would be vacuous")
	}
	var out []AuditEvent
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("k8saudit: reading fixture %q: %w", name, err)
		}
		events, err := ParseAuditBytes(body)
		if err != nil {
			return nil, fmt.Errorf("k8saudit: parsing fixture %q: %w", name, err)
		}
		out = append(out, events...)
	}
	return out, nil
}

// FixtureObservations projects every embedded fixture event. It is the whole of
// fixture mode and the source of the e2e corpus, so a fixture added to testdata/
// flows into both without a second edit. The RawEvidenceRef is prefixed with the
// fixture file so the e2e negative-discipline check can attribute an observation
// to the object it came from.
func FixtureObservations() ([]model.Observation, error) {
	files, err := FixtureFiles()
	if err != nil {
		return nil, err
	}
	var p Projector
	var out []model.Observation
	for _, name := range files {
		body, err := fixtureFS.ReadFile("testdata/" + name)
		if err != nil {
			return nil, fmt.Errorf("k8saudit: reading fixture %q: %w", name, err)
		}
		events, err := ParseAuditBytes(body)
		if err != nil {
			return nil, fmt.Errorf("k8saudit: parsing fixture %q: %w", name, err)
		}
		for i := range events {
			ref := fmt.Sprintf("testdata/%s", name)
			obs, ok := p.Project(events[i], ref)
			if ok {
				out = append(out, obs)
			}
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("k8saudit: fixture corpus projected nothing; every e2e assertion would be vacuous")
	}
	return out, nil
}
