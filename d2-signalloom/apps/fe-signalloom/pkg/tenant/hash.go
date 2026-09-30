// Package tenant derives the canonical Signal Loom tenant domain hash
// in-process, identical to scripts/derive_tenant_hash.py (SLDC-P3-1):
//
//	hash = hex(sha256(salt + ":" + lower(trim(tenant))))[:8]
//
// This is the salted SHA-256 concatenation (Governor ruling G1), not
// HMAC-SHA256. Salt resolution tries OpenBao KV v2 secret/data/signalloom/eap
// (field "salt") with a two-second timeout, then SIGNAL_LOOM_EAP_SALT, and
// otherwise fails closed. There is no built-in default salt.
package tenant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	CanonicalTenant = "kusari"
	CanonicalHash   = "4b53ab6b"
	PilotSalt       = "signalloom-eap-salt-2026-q3"
	RetiredTenant   = "kurasi"

	baoKVPath  = "/v1/secret/data/signalloom/eap"
	baoTimeout = 2 * time.Second
)

var (
	ErrEmptyTenant     = errors.New("tenant name cannot be empty")
	ErrInvalidTenant   = errors.New("invalid tenant name (must match ^[a-z0-9][a-z0-9-]{0,62}$)")
	ErrRetiredTenant   = errors.New("tenant 'kurasi' is a retired legacy typo; the canonical tenant is 'kusari'")
	ErrSaltUnavailable = errors.New("EAP salt unavailable: provision secret/signalloom/eap in OpenBao or set SIGNAL_LOOM_EAP_SALT")

	tenantRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
)

// NormalizeTenant trims and lowercases, then rejects empty, retired and
// malformed names.
func NormalizeTenant(name string) (string, error) {
	cleaned := strings.ToLower(strings.TrimSpace(name))
	switch {
	case cleaned == "":
		return "", ErrEmptyTenant
	case cleaned == RetiredTenant:
		return "", ErrRetiredTenant
	case !tenantRE.MatchString(cleaned):
		return "", fmt.Errorf("%w: %q", ErrInvalidTenant, cleaned)
	}
	return cleaned, nil
}

// DeriveTenantHash returns the 8-char lowercase hex hash for tenant under salt.
func DeriveTenantHash(tenant, salt string) (string, error) {
	cleaned, err := NormalizeTenant(tenant)
	if err != nil {
		return "", err
	}
	if salt == "" {
		return "", ErrSaltUnavailable
	}
	sum := sha256.Sum256([]byte(salt + ":" + cleaned))
	return hex.EncodeToString(sum[:])[:8], nil
}

// Getenv is the environment lookup ResolveSalt uses; os.Getenv in production.
type Getenv func(string) string

func firstSet(getenv Getenv, names ...string) string {
	for _, n := range names {
		if v := getenv(n); v != "" {
			return v
		}
	}
	return ""
}

// ResolveSalt returns the OpenBao salt when reachable, else
// SIGNAL_LOOM_EAP_SALT, else ErrSaltUnavailable. client and getenv may be nil.
func ResolveSalt(ctx context.Context, client *http.Client, getenv Getenv) (string, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	if salt := fetchOpenBaoSalt(ctx, client, getenv); salt != "" {
		return salt, nil
	}
	if salt := getenv("SIGNAL_LOOM_EAP_SALT"); salt != "" {
		return salt, nil
	}
	return "", ErrSaltUnavailable
}

func fetchOpenBaoSalt(ctx context.Context, client *http.Client, getenv Getenv) string {
	addr := firstSet(getenv, "BAO_ADDR", "VAULT_ADDR", "OPENBAO_ADDR")
	token := firstSet(getenv, "BAO_TOKEN", "VAULT_TOKEN")
	if addr == "" || token == "" {
		return ""
	}
	if client == nil {
		client = &http.Client{}
	}
	ctx, cancel := context.WithTimeout(ctx, baoTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(addr, "/")+baoKVPath, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("X-Vault-Token", token)
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}
	var body struct {
		Data struct {
			Data struct {
				Salt string `json:"salt"`
			} `json:"data"`
		} `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&body) != nil {
		return ""
	}
	return body.Data.Data.Salt
}
