// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"embed"
	"fmt"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// fixtureFS embeds testdata so fixture mode is reproducible wherever the binary runs.
// Reading these off disk at runtime would make the collector's behaviour depend on the
// working directory, which is exactly the kind of environment coupling that makes a
// fixture-mode demo fail on the cluster and pass locally.
//
//go:embed testdata
var fixtureFS embed.FS

// The fixture objects replayed by fixture mode and asserted by contract_test.go.
const (
	FixtureCloudTrail = "cloudtrail.json"
	FixtureIAM        = "iam.json"
	FixtureVPCFlow    = "vpcflow.log"
	FixturePoisoned   = "poisoned.json"
)

// FixtureFiles returns the fixture object names in replay order. poisoned.json is
// included: it is a valid CloudTrail object whose secrets must survive projection as
// absences, so replaying it in fixture mode is a live assertion of the negative
// contract rather than a test-only concern.
func FixtureFiles() []string {
	return []string{FixtureCloudTrail, FixtureIAM, FixtureVPCFlow, FixturePoisoned}
}

// FixtureOrigin returns the Origin for a fixture object. Bucket is empty, so the
// evidence ref reads testdata/<file>#<index> and is visibly not an S3 location.
func FixtureOrigin(name string) Origin {
	return Origin{Key: "testdata/" + name}
}

// FixtureBytes returns the embedded bytes of a fixture object.
func FixtureBytes(name string) ([]byte, error) {
	b, err := fixtureFS.ReadFile("testdata/" + name)
	if err != nil {
		return nil, fmt.Errorf("awslogs: reading embedded fixture %q: %w", name, err)
	}
	return b, nil
}

// FixtureObservations projects every fixture object in FixtureFiles order. It is the
// whole of fixture mode and the source of the expected count in the mode matrix, so a
// fixture added to testdata/ flows into both without a second edit.
func FixtureObservations(tenantID, region string) ([]model.Observation, error) {
	return projectFixtures(FixtureFiles(), tenantID, region)
}

// The fixture sets fixture mode can replay, selected by AWSLOGS_FIXTURE_SET.
const (
	// FixtureSetDefault replays FixtureFiles() and nothing else.
	FixtureSetDefault = "default"
	// FixtureSetKusari replays FixtureFiles() followed by KusariFixtureFiles(),
	// burst records included, so stage 2 has thresholds to cross on a cluster.
	FixtureSetKusari = "kusari"
)

// FixtureSetFiles returns the objects a fixture set replays, in order. An empty
// set is the default. An unknown set is an error, never a fallback.
func FixtureSetFiles(set string) ([]string, error) {
	switch set {
	case "", FixtureSetDefault:
		return FixtureFiles(), nil
	case FixtureSetKusari:
		return append(FixtureFiles(), KusariFixtureFiles()...), nil
	default:
		return nil, fmt.Errorf("awslogs: unknown fixture set %q (%s=%s|%s)", set, EnvFixtureSet, FixtureSetDefault, FixtureSetKusari)
	}
}

// FixtureSetObservations projects every object in a fixture set, in order. It is
// what fixture mode replays.
func FixtureSetObservations(set, tenantID, region string) ([]model.Observation, error) {
	files, err := FixtureSetFiles(set)
	if err != nil {
		return nil, err
	}
	return projectFixtures(files, tenantID, region)
}

func projectFixtures(files []string, tenantID, region string) ([]model.Observation, error) {
	p := Projector{TenantID: tenantID, Region: region}

	var out []model.Observation
	for _, name := range files {
		body, err := FixtureBytes(name)
		if err != nil {
			return nil, err
		}
		obs, err := p.Project(body, FixtureOrigin(name))
		if err != nil {
			return nil, fmt.Errorf("awslogs: projecting fixture %q: %w", name, err)
		}
		out = append(out, obs...)
	}
	return out, nil
}
