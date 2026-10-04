// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Hub TLS (remote-contract.md "TLS"). The warden's two HTTP clients, the
// observation sender and the fleet client, are built from one hubclient
// policy so they cannot trust different authorities. The mode is logged once
// at start; a refused policy (skip-verify outside dev mode, unreadable CA
// file) is a startup failure, never a silent fall-through to system roots.

import (
	"fmt"
	"net/http"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/hubclient"
)

// hubClients holds the two per-purpose clients over the shared trust policy.
type hubClients struct {
	mode   hubclient.Mode
	ingest *http.Client // observation sender (correlator.WithHTTPClient)
	fleet  *http.Client // fleet-manager stun, report, poll and ack
}

// newHubClients resolves the policy and builds both clients, or returns the
// refusal. The returned event is the single startup line naming the mode.
func newHubClients(cfg hubclient.Config) (*hubClients, stunEvent, error) {
	ingest, err := cfg.Client(correlator.DefaultHTTPTimeout)
	if err != nil {
		return nil, stunEvent{}, fmt.Errorf("hub tls: %w", err)
	}
	fleet, err := cfg.Client(fleetStunTimeout)
	if err != nil {
		return nil, stunEvent{}, fmt.Errorf("hub tls: %w", err)
	}
	details := map[string]interface{}{"mode": string(cfg.Mode()), "dev_mode": cfg.DevMode}
	if cfg.CAFile != "" {
		details["ca_file"] = cfg.CAFile
	}
	if cfg.CAFileMissing() {
		// The CA Secret is optional in the manifests: say the file was
		// configured and absent, so a hub TLS failure later is explained.
		details["ca_file_missing"] = true
	}
	return &hubClients{mode: cfg.Mode(), ingest: ingest, fleet: fleet},
		stunEvent{Timestamp: now(), Event: "hub_tls_mode", Details: details}, nil
}
