// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package transform

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestScrubber_RegexPatterns(t *testing.T) {
	scrubber := NewCryptographicSecretScrubber("test-salt-123")

	cases := []struct {
		input    string
		expected string
	}{
		{
			input:    "Authorization: Bearer my-secret-bearer-token-123456",
			expected: "Authorization: Bearer [REDACTED_TOKEN]",
		},
		{
			input:    "JWT token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
			expected: "JWT token: [REDACTED_JWT]",
		},
		{
			input:    "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0\n-----END RSA PRIVATE KEY-----",
			expected: "[REDACTED_PRIVATE_KEY]",
		},
		{
			input:    "AWS Key: AKIAIOSFODNN7EXAMPLE",
			expected: "AWS Key: [REDACTED_AWS_KEY]",
		},
		{
			input:    "GitHub Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
			expected: "GitHub Token: [REDACTED_GH_PAT]",
		},
		{
			input:    "Vault token: s.123456789012345678901234",
			expected: "Vault token: [REDACTED_VAULT_TOKEN]",
		},
	}

	for _, c := range cases {
		out := scrubber.ScrubText(c.input)
		if out != c.expected {
			t.Errorf("input: %s\ngot:  %s\nwant: %s", c.input, out, c.expected)
		}
	}
}

func TestScrubber_AnonymizeHMAC(t *testing.T) {
	scrubber := NewCryptographicSecretScrubber("cluster-salt-2026")

	h1 := scrubber.AnonymizeHMAC("accessor-12345")
	h2 := scrubber.AnonymizeHMAC("accessor-12345")
	h3 := scrubber.AnonymizeHMAC("accessor-99999")

	if h1 != h2 {
		t.Fatalf("expected deterministic output for identical input: %s != %s", h1, h2)
	}
	if h1 == h3 {
		t.Fatalf("expected distinct output for distinct inputs: %s == %s", h1, h3)
	}
	if !strings.HasPrefix(h1, "hmac-") {
		t.Fatalf("expected hmac prefix: %s", h1)
	}
	if strings.Contains(h1, "accessor") {
		t.Fatalf("HMAC leaked raw input string: %s", h1)
	}
}

func TestScrubber_ScrubMap_Recursive(t *testing.T) {
	scrubber := NewCryptographicSecretScrubber("test-salt")

	rawMap := map[string]interface{}{
		"client_token": "s.secret-token-123",
		"password":     "SuperSecretP@ssword",
		"nested": map[string]interface{}{
			"secret": "db-prod-password",
			"info":   "public-metadata",
		},
		"list": []interface{}{
			"normal-string",
			map[string]interface{}{
				"api_key": "raw-api-key-999",
			},
		},
	}

	sanitized := scrubber.ScrubMap(rawMap)

	if !strings.HasPrefix(sanitized["client_token"].(string), "hmac-") {
		t.Errorf("expected HMAC masked client_token, got: %v", sanitized["client_token"])
	}
	if !strings.HasPrefix(sanitized["password"].(string), "hmac-") {
		t.Errorf("expected HMAC masked password, got: %v", sanitized["password"])
	}

	nested := sanitized["nested"].(map[string]interface{})
	if !strings.HasPrefix(nested["secret"].(string), "hmac-") {
		t.Errorf("expected HMAC masked nested secret, got: %v", nested["secret"])
	}
	if nested["info"] != "public-metadata" {
		t.Errorf("expected info preserved, got: %v", nested["info"])
	}
}

func TestScrubber_ScrubObservation(t *testing.T) {
	scrubber := NewCryptographicSecretScrubber("obs-salt")

	obs := &model.Observation{
		ID:             "obs-1",
		Timestamp:      time.Now().UTC(),
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityDefinitive,
		Confidence:     0.95,
		ActorHint:      "agent-key: AKIAIOSFODNN7EXAMPLE",
		RawEvidenceRef: "openbao://auth?token=s.123456789012345678901234",
		Labels: map[string]string{
			"accessor":     "acc-test-123",
			"password":     "admin-pass",
			"path":         "secret/data/cardvault/keys",
			"operation":    "read",
		},
		Description: "Workload authenticated with Bearer 12345678901234567890",
	}

	sanitized := scrubber.ScrubObservation(obs)

	if strings.Contains(sanitized.ActorHint, "AKIA") {
		t.Fatalf("actor hint leaked AWS key: %s", sanitized.ActorHint)
	}
	if strings.Contains(sanitized.RawEvidenceRef, "s.123456") {
		t.Fatalf("raw evidence ref leaked token: %s", sanitized.RawEvidenceRef)
	}
	if strings.Contains(sanitized.Description, "1234567890") {
		t.Fatalf("description leaked token: %s", sanitized.Description)
	}
	if sanitized.Labels["accessor"] == "acc-test-123" {
		t.Fatalf("accessor was not anonymized: %s", sanitized.Labels["accessor"])
	}
	if sanitized.Labels["password"] == "admin-pass" {
		t.Fatalf("password was not anonymized: %s", sanitized.Labels["password"])
	}
	if sanitized.Labels["path"] != "secret/data/cardvault/keys" {
		t.Fatalf("harmless path was altered: %s", sanitized.Labels["path"])
	}
}

func TestScrubber_MutationPayloads(t *testing.T) {
	scrubber := NewCryptographicSecretScrubber("mutation-salt")

	mutationVectors := []string{
		`{"auth":{"client_token":"s.098765432109876543210987","accessor":"acc-mut-1"}}`,
		`{"request":{"data":{"password":"root-sql-password","username":"admin"}}}`,
		`{"response":{"data":{"private_key":"-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----"}}}`,
		`{"headers":{"Authorization":"Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"}}`,
	}

	forbiddenSubstrings := []string{
		"s.0987654321",
		"root-sql-password",
		"BEGIN PRIVATE KEY",
		"Bearer eyJhbGci",
	}

	for i, vec := range mutationVectors {
		scrubbedJSON, err := scrubber.ScrubJSONPayload([]byte(vec))
		if err != nil {
			t.Fatalf("mutation vector %d failed: %v", i, err)
		}

		outStr := string(scrubbedJSON)
		for _, forbidden := range forbiddenSubstrings {
			if strings.Contains(outStr, forbidden) {
				t.Fatalf("mutation vector %d LEAKED secret substring %q: %s", i, forbidden, outStr)
			}
		}

		// Confirm still valid JSON
		var parsed map[string]interface{}
		if err := json.Unmarshal(scrubbedJSON, &parsed); err != nil {
			t.Fatalf("scrubbed JSON is invalid for vector %d: %v", i, err)
		}
	}
}
