package api

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

type mockAuditWriter struct {
	events []audit.Event
}

func (m *mockAuditWriter) WriteAuditEvent(ctx context.Context, e audit.Event) error {
	m.events = append(m.events, e)
	return nil
}

func generateCA(t *testing.T, commonName string) (*rsa.PrivateKey, *x509.Certificate) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("failed to generate CA key: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   commonName,
			Organization: []string{"Signal Loom CA"},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("failed to create CA certificate: %v", err)
	}

	caCert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("failed to parse CA certificate: %v", err)
	}

	return priv, caCert
}

func generateSVID(t *testing.T, caKey *rsa.PrivateKey, caCert *x509.Certificate, spiffeURI string, notBefore, notAfter time.Time) (*rsa.PrivateKey, *x509.Certificate, string) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("failed to generate SVID key: %v", err)
	}

	uri, err := url.Parse(spiffeURI)
	if err != nil {
		t.Fatalf("failed to parse SPIFFE URI: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject: pkix.Name{
			CommonName: spiffeURI,
		},
		URIs:                  []*url.URL{uri},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}

	signerCert := caCert
	signerKey := caKey
	if signerCert == nil {
		signerCert = template
		signerKey = priv
	}

	der, err := x509.CreateCertificate(rand.Reader, template, signerCert, &priv.PublicKey, signerKey)
	if err != nil {
		t.Fatalf("failed to create SVID certificate: %v", err)
	}

	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("failed to parse SVID certificate: %v", err)
	}

	pemBlock := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: der,
	})

	return priv, cert, string(pemBlock)
}

func TestCofideInterceptor_TableDriven(t *testing.T) {
	fixedNow := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)

	// Setup trusted CA and pool
	caKey, caCert := generateCA(t, "Signal Loom Root CA")
	trustPool := x509.NewCertPool()
	trustPool.AddCert(caCert)

	// Setup untrusted attacker CA
	attackerCAKey, attackerCACert := generateCA(t, "Untrusted Attacker CA")

	// 1. Valid SVID
	_, validCert, validPEM := generateSVID(t, caKey, caCert,
		"spiffe://signalloom.demo/ns/production/sa/payment-service",
		fixedNow.Add(-1*time.Hour),
		fixedNow.Add(1*time.Hour),
	)
	validBase64DER := base64.StdEncoding.EncodeToString(validCert.Raw)

	// 2. Forged SVID (signed by untrusted CA)
	_, _, forgedPEM := generateSVID(t, attackerCAKey, attackerCACert,
		"spiffe://signalloom.demo/ns/production/sa/payment-service",
		fixedNow.Add(-1*time.Hour),
		fixedNow.Add(1*time.Hour),
	)

	// 3. Expired SVID
	_, _, expiredPEM := generateSVID(t, caKey, caCert,
		"spiffe://signalloom.demo/ns/production/sa/payment-service",
		fixedNow.Add(-3*time.Hour),
		fixedNow.Add(-1*time.Hour),
	)

	// 4. Wrong Trust Domain SVID
	_, _, wrongDomainPEM := generateSVID(t, caKey, caCert,
		"spiffe://evil.com/ns/default/sa/infiltrator",
		fixedNow.Add(-1*time.Hour),
		fixedNow.Add(1*time.Hour),
	)

	// 5. Federated Trust Domain SVID (allowed)
	_, _, federatedPEM := generateSVID(t, caKey, caCert,
		"spiffe://partner.mesh/ns/finance/sa/ledger-agent",
		fixedNow.Add(-1*time.Hour),
		fixedNow.Add(1*time.Hour),
	)

	tests := []struct {
		name               string
		authHeader         string
		spiffeHeader       string
		expectedStatus     int
		expectedTenant     string
		expectedSpiffeID   string
		expectAuditLog     bool
		expectedAuditCount int
	}{
		{
			name:             "Case 1a: Valid signed SVID via PEM header -> 200 OK",
			spiffeHeader:     validPEM,
			expectedStatus:   http.StatusOK,
			expectedTenant:   "production",
			expectedSpiffeID: "spiffe://signalloom.demo/ns/production/sa/payment-service",
			expectAuditLog:   false,
		},
		{
			name:             "Case 1b: Valid signed SVID via Base64 DER -> 200 OK",
			authHeader:       "Bearer " + validBase64DER,
			expectedStatus:   http.StatusOK,
			expectedTenant:   "production",
			expectedSpiffeID: "spiffe://signalloom.demo/ns/production/sa/payment-service",
			expectAuditLog:   false,
		},
		{
			name:             "Case 1c: Valid Federated Trust Domain SVID -> 200 OK",
			spiffeHeader:     federatedPEM,
			expectedStatus:   http.StatusOK,
			expectedTenant:   "finance",
			expectedSpiffeID: "spiffe://partner.mesh/ns/finance/sa/ledger-agent",
			expectAuditLog:   false,
		},
		{
			name:           "Case 2: Forged / Untrusted signature SVID -> 401 Unauthorized",
			spiffeHeader:   forgedPEM,
			expectedStatus: http.StatusUnauthorized,
			expectAuditLog: true,
		},
		{
			name:           "Case 3: Expired certificate -> 401 Unauthorized",
			spiffeHeader:   expiredPEM,
			expectedStatus: http.StatusUnauthorized,
			expectAuditLog: true,
		},
		{
			name:           "Case 4: Wrong trust domain (unfederated) -> 403 Forbidden",
			spiffeHeader:   wrongDomainPEM,
			expectedStatus: http.StatusForbidden,
			expectAuditLog: true,
		},
		{
			name:           "Case 5a: Malformed ASN.1 certificate payload -> 400 Bad Request",
			spiffeHeader:   base64.StdEncoding.EncodeToString([]byte{0x30, 0x05, 0xFF, 0xFF, 0x00}),
			expectedStatus: http.StatusBadRequest,
			expectAuditLog: true,
		},
		{
			name:           "Case 5b: Corrupt random string payload -> 400 Bad Request",
			spiffeHeader:   "completely-invalid-raw-token-data",
			expectedStatus: http.StatusBadRequest,
			expectAuditLog: true,
		},
		{
			name:           "Case 6: Missing SVID header -> 401 Unauthorized",
			expectedStatus: http.StatusUnauthorized,
			expectAuditLog: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			auditWriter := &mockAuditWriter{}
			interceptor, err := NewCofideInterceptor(CofideConfig{
				TrustDomain:           "signalloom.demo",
				FederatedTrustDomains: []string{"partner.mesh"},
				TrustBundle:           trustPool,
				Audit:                 auditWriter,
				Now:                   func() time.Time { return fixedNow },
			})
			if err != nil {
				t.Fatalf("failed to create interceptor: %v", err)
			}

			var capturedClaims SpiffeClaims
			var capturedTenant TenantContext
			handler := interceptor.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if claims, ok := SPIFFEContextFromContext(r.Context()); ok {
					capturedClaims = claims
				}
				if tenant, ok := TenantContextFromContext(r.Context()); ok {
					capturedTenant = tenant
				}
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"status":"success"}`))
			}))

			req := httptest.NewRequest(http.MethodGet, "/api/v1/federation/summary", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			if tc.spiffeHeader != "" {
				req.Header.Set("X-SPIFFE-SVID", tc.spiffeHeader)
			}

			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)

			if rec.Code != tc.expectedStatus {
				t.Errorf("expected status %d, got %d (body: %s)", tc.expectedStatus, rec.Code, rec.Body.String())
			}

			if tc.expectedStatus == http.StatusOK {
				if capturedClaims.SpiffeID != tc.expectedSpiffeID {
					t.Errorf("expected SPIFFE ID %q, got %q", tc.expectedSpiffeID, capturedClaims.SpiffeID)
				}
				if capturedTenant.TenantID != tc.expectedTenant {
					t.Errorf("expected TenantID %q, got %q", tc.expectedTenant, capturedTenant.TenantID)
				}
			}

			if tc.expectAuditLog && len(auditWriter.events) == 0 {
				t.Errorf("expected audit event to be written for failure, got 0 events")
			}
		})
	}
}

func TestCofideInterceptor_PublicKeyValidation(t *testing.T) {
	fixedNow := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)
	caKey, caCert := generateCA(t, "Direct Key CA")

	_, validCert, _ := generateSVID(t, caKey, caCert,
		"spiffe://signalloom.demo/ns/default/sa/test-sa",
		fixedNow.Add(-1*time.Hour),
		fixedNow.Add(1*time.Hour),
	)

	interceptor, err := NewCofideInterceptor(CofideConfig{
		TrustDomain: "signalloom.demo",
		PublicKeys: map[string]crypto.PublicKey{
			"key-1": &caKey.PublicKey,
		},
		Now: func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("failed to init interceptor: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/federation/zones", nil)
	req.Header.Set("X-SPIFFE-SVID", base64.StdEncoding.EncodeToString(validCert.Raw))

	claims, status, err := interceptor.ValidateRequest(req)
	if err != nil || status != http.StatusOK {
		t.Fatalf("expected validation success with direct public key, got status %d err %v", status, err)
	}

	if claims.SpiffeID != "spiffe://signalloom.demo/ns/default/sa/test-sa" {
		t.Errorf("unexpected SPIFFE ID: %s", claims.SpiffeID)
	}
}
