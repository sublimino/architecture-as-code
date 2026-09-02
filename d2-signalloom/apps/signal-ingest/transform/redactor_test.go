package transform

import (
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestSecretRedactor_Tier1_BearerAndJWT(t *testing.T) {
	redactor := NewSecretRedactor()

	text := "GET /api/v1/namespaces/default/secrets Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgN"
	scrubbed := redactor.RedactText(text)

	if strings.Contains(scrubbed, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9") {
		t.Errorf("plaintext JWT found in scrubbed output: %s", scrubbed)
	}
	if !strings.Contains(scrubbed, "Bearer [REDACTED_SHA256:") {
		t.Errorf("expected hashed Bearer token format, got: %s", scrubbed)
	}
}

func TestSecretRedactor_Tier2_PEMKey(t *testing.T) {
	redactor := NewSecretRedactor()

	pem := "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0Y3...\n-----END RSA PRIVATE KEY-----"
	scrubbed := redactor.RedactText("Target payload with " + pem + " embedded.")

	if strings.Contains(scrubbed, "MIIEowIBAAKCAQEA0Y3") {
		t.Errorf("plaintext PEM content found in scrubbed output: %s", scrubbed)
	}
	if !strings.Contains(scrubbed, "[REDACTED_PEM_PRIVATE_KEY]") {
		t.Errorf("expected PEM replacement tag, got: %s", scrubbed)
	}
}

func TestSecretRedactor_Tier3_SensitiveLabels(t *testing.T) {
	redactor := NewSecretRedactor()

	obs := &model.Observation{
		ID:        "obs-101",
		Timestamp: time.Now().UTC(),
		Layer:     model.LayerCloudControlPlane,
		Fidelity:  model.FidelityDefinitive,
		Source:    "k8s-audit",
		Labels: map[string]string{
			"password":      "SuperSecretP@ssw0rd!",
			"api_key":       "AIzaSyD-9876543210abcdef",
			"resource":      "secrets",
			"namespace":     "kube-system",
			"vault_secret":  "hvs.CAESIJ...",
		},
		Description: "Access to token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgN by agent",
	}

	sanitized := redactor.RedactObservation(obs)

	// Resource and namespace should remain intact
	if sanitized.Labels["resource"] != "secrets" {
		t.Errorf("non-sensitive label was mangled: %s", sanitized.Labels["resource"])
	}
	if sanitized.Labels["namespace"] != "kube-system" {
		t.Errorf("non-sensitive label was mangled: %s", sanitized.Labels["namespace"])
	}

	// Sensitive labels must be redacted
	if strings.Contains(sanitized.Labels["password"], "SuperSecret") {
		t.Errorf("password leaked in labels: %s", sanitized.Labels["password"])
	}
	if !strings.HasPrefix(sanitized.Labels["password"], "[REDACTED_SHA256:") {
		t.Errorf("expected SHA256 redacted password, got: %s", sanitized.Labels["password"])
	}

	if strings.Contains(sanitized.Labels["api_key"], "AIzaSyD") {
		t.Errorf("api_key leaked in labels: %s", sanitized.Labels["api_key"])
	}

	if strings.Contains(sanitized.Labels["vault_secret"], "hvs.CAESIJ") {
		t.Errorf("vault_secret leaked in labels: %s", sanitized.Labels["vault_secret"])
	}

	if strings.Contains(sanitized.Description, "eyJhbGciOiJIUzI1Ni") {
		t.Errorf("description leaked JWT: %s", sanitized.Description)
	}
}
