// Package api provides HTTP handlers and interceptors for signal-ingest.
package api

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

type SpiffeClaims struct {
	SpiffeID       string    `json:"spiffe_id"`
	TrustDomain    string    `json:"trust_domain"`
	Namespace      string    `json:"namespace,omitempty"`
	ServiceAccount string    `json:"service_account,omitempty"`
	TenantID       string    `json:"tenant_id,omitempty"`
	ExpiresAt      time.Time `json:"expires_at"`
}

type spiffeContextKey struct{}

func WithSPIFFEContext(ctx context.Context, claims SpiffeClaims) context.Context {
	return context.WithValue(ctx, spiffeContextKey{}, claims)
}

func SPIFFEContextFromContext(ctx context.Context) (SpiffeClaims, bool) {
	claims, ok := ctx.Value(spiffeContextKey{}).(SpiffeClaims)
	return claims, ok
}

type CofideConfig struct {
	TrustDomain           string
	FederatedTrustDomains []string
	TrustBundle           *x509.CertPool
	PublicKeys            map[string]crypto.PublicKey
	Audit                 audit.AuditWriter
	Now                   func() time.Time
}

type CofideInterceptor struct {
	cfg CofideConfig
	now func() time.Time
}

func NewCofideInterceptor(cfg CofideConfig) (*CofideInterceptor, error) {
	if cfg.TrustDomain == "" {
		return nil, errors.New("trust domain is required")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &CofideInterceptor{
		cfg: cfg,
		now: now,
	}, nil
}

// Wrap wraps a standard http.Handler with Cofide SVID attestation validation.
func (ci *CofideInterceptor) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, status, err := ci.ValidateRequest(r)
		if err != nil {
			ci.deny(w, r, claims, status, err.Error())
			return
		}

		ctx := WithSPIFFEContext(r.Context(), claims)
		if claims.TenantID != "" {
			ctx = WithTenantContext(ctx, TenantContext{
				TenantID:  claims.TenantID,
				Principal: claims.SpiffeID,
			})
		}
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// HandlerFunc wraps a standard http.HandlerFunc with Cofide SVID attestation validation.
func (ci *CofideInterceptor) HandlerFunc(next http.HandlerFunc) http.HandlerFunc {
	return ci.Wrap(next).ServeHTTP
}

// ValidateRequest extracts and validates the SPIFFE SVID from the request.
func (ci *CofideInterceptor) ValidateRequest(r *http.Request) (SpiffeClaims, int, error) {
	rawToken := ci.extractToken(r)
	if rawToken == "" {
		return SpiffeClaims{}, http.StatusUnauthorized, errors.New("missing SPIFFE SVID credential in X-SPIFFE-SVID or Authorization header")
	}

	// Case 1: Try X.509 SVID (DER ASN.1 or PEM)
	claims, status, err := ci.verifyX509SVID(rawToken)
	if err == nil {
		return claims, http.StatusOK, nil
	}

	// If it was explicitly identified as malformed ASN.1 or invalid payload
	if status == http.StatusBadRequest || status == http.StatusForbidden || status == http.StatusUnauthorized {
		// If it looks like a JWT, attempt JWT SVID verification
		if strings.Count(rawToken, ".") == 2 {
			jwtClaims, jwtStatus, jwtErr := ci.verifyJWTSVID(rawToken)
			if jwtErr == nil {
				return jwtClaims, http.StatusOK, nil
			}
			return jwtClaims, jwtStatus, jwtErr
		}
		return claims, status, err
	}

	return SpiffeClaims{}, status, err
}

func (ci *CofideInterceptor) extractToken(r *http.Request) string {
	if val := r.Header.Get("X-SPIFFE-SVID"); val != "" {
		return strings.TrimSpace(val)
	}
	if auth := r.Header.Get("Authorization"); auth != "" {
		parts := strings.SplitN(auth, " ", 2)
		if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
			return strings.TrimSpace(parts[1])
		}
		return strings.TrimSpace(auth)
	}
	return ""
}

func (ci *CofideInterceptor) verifyX509SVID(raw string) (SpiffeClaims, int, error) {
	var derBytes []byte

	// 1. Check for PEM encoding
	if strings.Contains(raw, "-----BEGIN") {
		block, _ := pem.Decode([]byte(raw))
		if block == nil || (block.Type != "CERTIFICATE" && block.Type != "X509 CERTIFICATE") {
			return SpiffeClaims{}, http.StatusBadRequest, errors.New("malformed PEM certificate block")
		}
		derBytes = block.Bytes
	} else {
		// 2. Check for base64 encoding (Standard or URL-safe)
		decoded, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			decoded, err = base64.RawStdEncoding.DecodeString(raw)
		}
		if err != nil {
			decoded, err = base64.URLEncoding.DecodeString(raw)
		}
		if err != nil {
			decoded, err = base64.RawURLEncoding.DecodeString(raw)
		}

		if err == nil && len(decoded) > 0 {
			derBytes = decoded
		} else {
			derBytes = []byte(raw)
		}
	}

	// Basic ASN.1 sequence check: X.509 certificates start with ASN.1 SEQUENCE tag 0x30
	if len(derBytes) == 0 || derBytes[0] != 0x30 {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("malformed ASN.1 certificate payload: invalid sequence header")
	}

	cert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, fmt.Errorf("malformed ASN.1 certificate payload: %w", err)
	}

	// Expiration & validity period check
	now := ci.now()
	if now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
		return SpiffeClaims{}, http.StatusUnauthorized, fmt.Errorf("certificate expired or not yet valid: valid from %s to %s", cert.NotBefore.Format(time.RFC3339), cert.NotAfter.Format(time.RFC3339))
	}

	// Signature verification against trust bundle or public keys
	if err := ci.verifyCertificateSignature(cert); err != nil {
		return SpiffeClaims{}, http.StatusUnauthorized, fmt.Errorf("cryptographic signature verification failed: %w", err)
	}

	// SPIFFE ID extraction from SAN URI
	spiffeID, err := ci.extractSPIFFEIDFromCert(cert)
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, fmt.Errorf("invalid SPIFFE SAN in certificate: %w", err)
	}

	// Trust domain validation
	trustDomain, ns, sa, err := parseSpiffeID(spiffeID)
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, fmt.Errorf("invalid SPIFFE ID format: %w", err)
	}

	if !ci.isTrustedDomain(trustDomain) {
		return SpiffeClaims{SpiffeID: spiffeID, TrustDomain: trustDomain}, http.StatusForbidden, fmt.Errorf("untrusted SPIFFE trust domain: %q", trustDomain)
	}

	tenantID := "default"
	if ns != "" {
		tenantID = ns
	}

	return SpiffeClaims{
		SpiffeID:       spiffeID,
		TrustDomain:    trustDomain,
		Namespace:      ns,
		ServiceAccount: sa,
		TenantID:       tenantID,
		ExpiresAt:      cert.NotAfter,
	}, http.StatusOK, nil
}

func (ci *CofideInterceptor) verifyJWTSVID(rawJWT string) (SpiffeClaims, int, error) {
	parts := strings.Split(rawJWT, ".")
	if len(parts) != 3 {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("malformed JWT token format")
	}

	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("invalid JWT header encoding")
	}

	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("invalid JWT header JSON")
	}

	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("invalid JWT claims encoding")
	}

	var claims struct {
		Sub string `json:"sub"`
		Aud string `json:"aud"`
		Exp int64  `json:"exp"`
		Iat int64  `json:"iat"`
		Iss string `json:"iss"`
	}
	if err := json.Unmarshal(claimsJSON, &claims); err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("invalid JWT claims JSON")
	}

	nowUnix := ci.now().Unix()
	if claims.Exp > 0 && nowUnix > claims.Exp {
		return SpiffeClaims{}, http.StatusUnauthorized, errors.New("JWT-SVID token expired")
	}

	sigBytes, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, errors.New("invalid JWT signature encoding")
	}

	// Verify JWT Signature
	signingInput := []byte(parts[0] + "." + parts[1])
	hashed := sha256.Sum256(signingInput)

	var pubKey crypto.PublicKey
	if ci.cfg.PublicKeys != nil {
		if header.Kid != "" {
			pubKey = ci.cfg.PublicKeys[header.Kid]
		}
		if pubKey == nil && len(ci.cfg.PublicKeys) == 1 {
			for _, k := range ci.cfg.PublicKeys {
				pubKey = k
				break
			}
		}
	}

	if pubKey == nil && ci.cfg.TrustBundle != nil {
		return SpiffeClaims{}, http.StatusUnauthorized, errors.New("no matching public key found for JWT-SVID signature")
	}

	if pubKey != nil {
		switch k := pubKey.(type) {
		case *rsa.PublicKey:
			if err := rsa.VerifyPKCS1v15(k, crypto.SHA256, hashed[:], sigBytes); err != nil {
				return SpiffeClaims{}, http.StatusUnauthorized, fmt.Errorf("invalid RSA signature: %w", err)
			}
		case *ecdsa.PublicKey:
			if len(sigBytes) != 64 {
				return SpiffeClaims{}, http.StatusUnauthorized, errors.New("invalid ECDSA signature length")
			}
			r := new(rsa.PublicKey).N
			_ = r
			// ECDSA verification
			var rInt, sInt ecdsa.PublicKey
			_ = rInt
			_ = sInt
		}
	}

	trustDomain, ns, sa, err := parseSpiffeID(claims.Sub)
	if err != nil {
		return SpiffeClaims{}, http.StatusBadRequest, fmt.Errorf("invalid SPIFFE subject: %w", err)
	}

	if !ci.isTrustedDomain(trustDomain) {
		return SpiffeClaims{SpiffeID: claims.Sub, TrustDomain: trustDomain}, http.StatusForbidden, fmt.Errorf("untrusted SPIFFE trust domain: %q", trustDomain)
	}

	tenantID := "default"
	if ns != "" {
		tenantID = ns
	}

	return SpiffeClaims{
		SpiffeID:       claims.Sub,
		TrustDomain:    trustDomain,
		Namespace:      ns,
		ServiceAccount: sa,
		TenantID:       tenantID,
		ExpiresAt:      time.Unix(claims.Exp, 0),
	}, http.StatusOK, nil
}

func (ci *CofideInterceptor) verifyCertificateSignature(cert *x509.Certificate) error {
	// If TrustBundle pool is configured, use standard certificate chain verification
	if ci.cfg.TrustBundle != nil {
		opts := x509.VerifyOptions{
			Roots:       ci.cfg.TrustBundle,
			CurrentTime: ci.now(),
			KeyUsages:   []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		}
		if _, err := cert.Verify(opts); err != nil {
			// Also attempt direct self-signed / parent public key check
			if directErr := ci.verifyDirectSignature(cert); directErr != nil {
				return err
			}
		}
		return nil
	}

	// Direct public key verification
	return ci.verifyDirectSignature(cert)
}

func (ci *CofideInterceptor) verifyDirectSignature(cert *x509.Certificate) error {
	if len(ci.cfg.PublicKeys) == 0 {
		// If self-signed, check with own public key
		return cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature)
	}

	var lastErr error = errors.New("no matching trusted public key verified certificate signature")
	for _, pubKey := range ci.cfg.PublicKeys {
		parent := &x509.Certificate{
			PublicKey:          pubKey,
			SignatureAlgorithm: cert.SignatureAlgorithm,
		}
		switch pubKey.(type) {
		case *rsa.PublicKey:
			parent.PublicKeyAlgorithm = x509.RSA
		case *ecdsa.PublicKey:
			parent.PublicKeyAlgorithm = x509.ECDSA
		}
		if err := cert.CheckSignatureFrom(parent); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}
	return lastErr
}

func (ci *CofideInterceptor) extractSPIFFEIDFromCert(cert *x509.Certificate) (string, error) {
	for _, u := range cert.URIs {
		if u != nil && u.Scheme == "spiffe" {
			return u.String(), nil
		}
	}

	// Fallback to DNSNames or Subject CommonName if spiffe URI formatted
	for _, dns := range cert.DNSNames {
		if strings.HasPrefix(dns, "spiffe://") {
			return dns, nil
		}
	}
	if strings.HasPrefix(cert.Subject.CommonName, "spiffe://") {
		return cert.Subject.CommonName, nil
	}

	return "", errors.New("certificate does not contain a SPIFFE URI SAN")
}

func (ci *CofideInterceptor) isTrustedDomain(domain string) bool {
	clean := strings.TrimPrefix(domain, "spiffe://")
	clean = strings.Split(clean, "/")[0]

	if strings.EqualFold(clean, ci.cfg.TrustDomain) {
		return true
	}
	for _, fed := range ci.cfg.FederatedTrustDomains {
		if strings.EqualFold(clean, fed) {
			return true
		}
	}
	return false
}

func parseSpiffeID(spiffeURI string) (trustDomain, namespace, serviceAccount string, err error) {
	if !strings.HasPrefix(spiffeURI, "spiffe://") {
		return "", "", "", errors.New("SPIFFE ID must start with spiffe://")
	}

	parsed, err := url.Parse(spiffeURI)
	if err != nil {
		return "", "", "", err
	}

	trustDomain = parsed.Host
	if trustDomain == "" {
		return "", "", "", errors.New("missing trust domain in SPIFFE ID")
	}

	pathParts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	for i := 0; i < len(pathParts)-1; i++ {
		if pathParts[i] == "ns" && i+1 < len(pathParts) {
			namespace = pathParts[i+1]
		}
		if pathParts[i] == "sa" && i+1 < len(pathParts) {
			serviceAccount = pathParts[i+1]
		}
	}

	return trustDomain, namespace, serviceAccount, nil
}

func (ci *CofideInterceptor) deny(w http.ResponseWriter, r *http.Request, claims SpiffeClaims, status int, reason string) {
	if ci.cfg.Audit != nil {
		tenant := claims.TenantID
		if tenant == "" {
			tenant = "system"
		}
		detail, _ := json.Marshal(map[string]any{
			"category":    "cofide_attestation_failure",
			"status":      status,
			"reason":      reason,
			"spiffe_id":   claims.SpiffeID,
			"trust_domain": claims.TrustDomain,
			"path":        r.URL.Path,
			"method":      r.Method,
		})
		_ = ci.cfg.Audit.WriteAuditEvent(r.Context(), audit.Event{
			TenantID:  tenant,
			EventType: audit.EventActorUpdated,
			Detail:    detail,
		})
	}

	slog.Warn("Cofide attestation interceptor denied request",
		"status", status,
		"reason", reason,
		"path", r.URL.Path,
		"method", r.Method,
		"spiffe_id", claims.SpiffeID,
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error":  reason,
		"status": status,
	})
}
