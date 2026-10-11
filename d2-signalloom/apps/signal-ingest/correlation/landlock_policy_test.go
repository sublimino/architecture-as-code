// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlation

import (
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/policy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

func TestLandlockDenialPolicy(t *testing.T) {
	bundle, err := obscel.LoadBundleFile("../../../../policy/bundles/kusari/landlock-denial.yaml")
	if err != nil {
		t.Fatal(err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 10, 11, 10, 0, 0, 0, time.UTC)
	positive := obscel.Observation{
		ID:        "landlock-1",
		Timestamp: now,
		Layer:     "endpoint_host",
		TenantID:  "kusari",
		Actor:     "pseud-kusari-agent",
		Labels: map[string]string{
			"tenant_id":           "kusari",
			"verification_status": "VERIFIED",
			"agent_id":            "kusari-agent",
			"denial_reason":       "landlock denied openat /etc/shadow",
			"path":                "/etc/shadow",
			"syscall":             "openat",
		},
	}

	assertFinding := func(t *testing.T, obs obscel.Observation) obscel.Finding {
		t.Helper()
		findings, evalErr := evaluator.EvaluateObservation(obs, bundle)
		if evalErr != nil {
			t.Fatal(evalErr)
		}
		if len(findings) != 1 {
			t.Fatalf("findings = %d, want 1: %#v", len(findings), findings)
		}
		if findings[0].RuleID != "landlock-verified-denial" {
			t.Fatalf("rule id = %q, want landlock-verified-denial", findings[0].RuleID)
		}
		return findings[0]
	}

	assertFinding(t, positive)
	lowercase := positive
	lowercase.ID = "landlock-2"
	lowercase.Labels = cloneLabels(positive.Labels)
	lowercase.Labels["verification_status"] = "verified"
	assertFinding(t, lowercase)

	negativeCases := []struct {
		name string
		edit func(*obscel.Observation)
	}{
		{
			name: "tampered verification",
			edit: func(obs *obscel.Observation) {
				obs.Labels["verification_status"] = "TAMPERED"
			},
		},
		{
			name: "empty denial reason",
			edit: func(obs *obscel.Observation) {
				obs.Labels["denial_reason"] = ""
			},
		},
		{
			name: "absent denial reason",
			edit: func(obs *obscel.Observation) {
				delete(obs.Labels, "denial_reason")
			},
		},
		{
			name: "wrong layer",
			edit: func(obs *obscel.Observation) {
				obs.Layer = "cloud_control_plane"
			},
		},
	}
	for _, tc := range negativeCases {
		t.Run(tc.name, func(t *testing.T) {
			obs := positive
			obs.ID = "negative-" + tc.name
			obs.Labels = cloneLabels(positive.Labels)
			tc.edit(&obs)
			findings, evalErr := evaluator.EvaluateObservation(obs, bundle)
			if evalErr != nil {
				t.Fatal(evalErr)
			}
			if len(findings) != 0 {
				t.Fatalf("findings = %#v, want none", findings)
			}
		})
	}

	var denialRule obscel.Rule
	for _, rule := range bundle.Rules {
		if rule.ID == "landlock-verified-denial" {
			denialRule = rule
			break
		}
	}
	if denialRule.ID == "" {
		t.Fatal("bundle does not contain landlock-verified-denial")
	}
	finding := obscel.NewFinding(positive, bundle, denialRule)
	decisions := policy.NewWindows([]*obscel.Bundle{bundle}).Offer(finding, bundle)
	if len(decisions) != 1 {
		t.Fatalf("decisions = %d, want 1: %#v", len(decisions), decisions)
	}
	if decisions[0].WindowID != "landlock-denial-burst" {
		t.Fatalf("window id = %q, want landlock-denial-burst", decisions[0].WindowID)
	}
	if decisions[0].RuleID != finding.RuleID {
		t.Fatalf("decision rule id = %q, want finding rule id %q", decisions[0].RuleID, finding.RuleID)
	}
}

func cloneLabels(labels map[string]string) map[string]string {
	clone := make(map[string]string, len(labels))
	for key, value := range labels {
		clone[key] = value
	}
	return clone
}
