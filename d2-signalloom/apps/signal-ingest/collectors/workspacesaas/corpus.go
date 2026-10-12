// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package workspacesaas

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// corpusFS embeds the SaaS audit testdata so the identity_authorization (login)
// and application_saas corpora are reproducible wherever the binary runs — the
// same reasoning as collectors/k8saudit. The login/ subtree feeds the
// identity-auth bundle and the app/ subtree feeds the application-saas bundle;
// they are kept apart so each stream's e2e asserts an exact count over only its
// own layer.
//
//go:embed testdata
var corpusFS embed.FS

// LoginFixtureObservations projects every embedded login fixture (the SaaS
// identity_authorization stream) through the production NormalisedSaaSEvent
// projection.
func LoginFixtureObservations() ([]model.Observation, error) {
	return loadCorpus("login")
}

// AppSaaSFixtureObservations projects every embedded application fixture (the
// application_saas stream) through the production projection.
func AppSaaSFixtureObservations() ([]model.Observation, error) {
	return loadCorpus("app")
}

// loadCorpus reads every JSON fixture file under testdata/<sub> in sorted order,
// deserialises each into NormalisedSaaSEvent records, and converts them with the
// production ToObservation projection. The RawEvidenceRef is rewritten to the
// fixture file so the e2e negative-discipline check can attribute an observation
// to its object; the labels, layer, source and actor the rules read are exactly
// what the contract projection produces.
func loadCorpus(sub string) ([]model.Observation, error) {
	dir := "testdata/" + sub
	entries, err := fs.ReadDir(corpusFS, dir)
	if err != nil {
		return nil, fmt.Errorf("workspacesaas: reading embedded %s: %w", dir, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	if len(names) == 0 {
		return nil, fmt.Errorf("workspacesaas: no embedded fixtures under %s; fixture mode would be vacuous", dir)
	}

	var out []model.Observation
	for _, name := range names {
		path := dir + "/" + name
		body, err := corpusFS.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("workspacesaas: reading fixture %q: %w", path, err)
		}
		var events []NormalisedSaaSEvent
		if err := json.Unmarshal(body, &events); err != nil {
			return nil, fmt.Errorf("workspacesaas: parsing fixture %q: %w", path, err)
		}
		if len(events) == 0 {
			return nil, fmt.Errorf("workspacesaas: fixture %q holds no events; its assertions would be vacuous", path)
		}
		ref := fmt.Sprintf("testdata/%s/%s", sub, name)
		for i := range events {
			obs, err := events[i].ToObservation()
			if err != nil {
				return nil, fmt.Errorf("workspacesaas: projecting fixture %q event %d: %w", path, i, err)
			}
			obs.RawEvidenceRef = ref
			out = append(out, *obs)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("workspacesaas: fixture corpus under %s projected nothing; every e2e assertion would be vacuous", dir)
	}
	return out, nil
}
