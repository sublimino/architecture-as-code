package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// StaticKeysEnv holds the NON-secret half of every static key: a JSON list of
// {name, subject, tenant, permissions, actor_ids}. It lives in a ConfigMap.
const StaticKeysEnv = "SIGNAL_AUTH_STATIC_KEYS"

// StaticKeysDirEnv names the directory holding the secret half: one file per key, named after
// the key, projected from that key's own Secret. Defaults to DefaultStaticKeysDir.
const StaticKeysDirEnv = "SIGNAL_AUTH_STATIC_KEYS_DIR"

// StaticKeyExpirySuffix names the file beside each value holding its expiry (YYYY-MM-DD). The
// issuer mints both into the key's Secret, so a rotation renews value and lifetime together.
const StaticKeyExpirySuffix = ".expires"

// DefaultStaticKeysDir is where the Deployment projects the key Secrets.
const DefaultStaticKeysDir = "/etc/signal-ingest/static-keys"

// StaticKeySpec holds the parsed, validated specification of one static key from ConfigMap.
type StaticKeySpec struct {
	Name        string       `json:"name"`
	Subject     string       `json:"subject"`
	Tenant      string       `json:"tenant"`
	Permissions []Permission `json:"permissions"`
	ActorIDs    []string     `json:"actor_ids"`
}

// LoadStaticKeySpecs parses and validates the static key specifications from SIGNAL_AUTH_STATIC_KEYS
// and resolves the key secret directory from SIGNAL_AUTH_STATIC_KEYS_DIR (defaulting to DefaultStaticKeysDir).
//
// Returns (nil, "", nil) when SIGNAL_AUTH_STATIC_KEYS is unset.
func LoadStaticKeySpecs() ([]StaticKeySpec, string, error) {
	raw := strings.TrimSpace(os.Getenv(StaticKeysEnv))
	if raw == "" {
		return nil, "", nil
	}
	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.DisallowUnknownFields()
	var specs []StaticKeySpec
	if err := dec.Decode(&specs); err != nil {
		return nil, "", fmt.Errorf("%s is not a list of key specs: %w", StaticKeysEnv, err)
	}
	if len(specs) == 0 {
		return nil, "", fmt.Errorf("%s is set but names no keys; unset it to disable static keys", StaticKeysEnv)
	}
	dir := os.Getenv(StaticKeysDirEnv)
	if dir == "" {
		dir = DefaultStaticKeysDir
	}

	seen := map[string]bool{}
	for _, spec := range specs {
		cfg := StaticBearerConfig{
			Name: spec.Name, Subject: spec.Subject, TenantID: spec.Tenant,
			Permissions: spec.Permissions, ActorIDs: spec.ActorIDs,
		}
		if err := cfg.validateConfig(); err != nil {
			return nil, "", fmt.Errorf("static key %q: %w", spec.Name, err)
		}
		if seen[spec.Name] {
			return nil, "", fmt.Errorf("static key %q is configured twice", spec.Name)
		}
		seen[spec.Name] = true
	}
	return specs, dir, nil
}

// StaticKeysFromEnv loads the configured keys.
//
// (nil, nil) when SIGNAL_AUTH_STATIC_KEYS is unset: the feature is off.
//
// What refuses startup and what does not follows who wrote it. The ConfigMap is reviewed,
// versioned configuration: bad JSON, an unknown field (a value or expiry pasted into it is one), a
// duplicate or path-like name, or an invalid principal is an error for main to refuse startup on.
// A Secret's CONTENT is runtime state minted per cluster: a value missing, short or whitespace-
// bearing, an expiry missing, malformed, past, or beyond MaxStaticKeyLifetime, or two keys sharing
// one value — each DISABLES the affected key(s), logged at ERROR by name, and the rest still load.
// One caller's Secret must not take ingest down for every other caller, and every one of those
// outcomes is a narrowing (that caller gets 401), never a widening.
func StaticKeysFromEnv() ([]StaticBearerConfig, error) {
	specs, dir, err := LoadStaticKeySpecs()
	if err != nil || specs == nil {
		return nil, err
	}
	return loadStaticKeysFromSpecs(specs, dir, time.Now())
}

func loadStaticKeysFromSpecs(specs []StaticKeySpec, dir string, now time.Time) ([]StaticBearerConfig, error) {
	var keys []StaticBearerConfig
	for _, spec := range specs {
		cfg := StaticBearerConfig{
			Name: spec.Name, Subject: spec.Subject, TenantID: spec.Tenant,
			Permissions: spec.Permissions, ActorIDs: spec.ActorIDs,
		}

		if err := readKeySecret(dir, &cfg, now); err != nil {
			slog.Error("static key DISABLED: its Secret is unusable; this caller will get 401",
				"key", spec.Name, "dir", dir, "reason", err.Error())
			continue
		}
		if left := cfg.ExpiresAt.Sub(now); left < StaticKeyExpiryWarning {
			slog.Warn("static key expires soon; rotate it with scripts/sldc-ingest-bearer.sh --rotate",
				"key", spec.Name, "expires", cfg.ExpiresAt.UTC().Format(time.DateOnly))
		}
		keys = append(keys, cfg)
	}

	// Two callers holding one value cannot be told apart, so neither is trusted.
	byValue := map[string][]string{}
	for _, k := range keys {
		byValue[k.Token] = append(byValue[k.Token], k.Name)
	}
	kept := keys[:0]
	for _, k := range keys {
		if names := byValue[k.Token]; len(names) > 1 {
			slog.Error("static key DISABLED: keys share one value; every caller needs its own key",
				"key", k.Name, "shared_with", names)
			continue
		}
		kept = append(kept, k)
	}
	if len(kept) == 0 {
		slog.Error("every configured static key is disabled; only JWT-SVIDs can authenticate", "dir", dir)
		return nil, nil
	}
	return kept, nil
}

// readKeySecret fills cfg's value and expiry from the key's projected Secret. Its errors never
// carry the value.
func readKeySecret(dir string, cfg *StaticBearerConfig, now time.Time) error {
	value, err := os.ReadFile(filepath.Join(dir, cfg.Name))
	if errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("value not mounted (Secret not minted?): %w", fs.ErrNotExist)
	}
	if err != nil {
		return fmt.Errorf("read value: %w", err)
	}
	// One trailing newline is how `echo` and most editors end a file; anything else is part of
	// the value, and whitespace inside a value is a copy-paste accident, not a key.
	cfg.Token = strings.TrimSuffix(string(value), "\n")
	if strings.ContainsAny(cfg.Token, " \t\r\n") {
		return errors.New("value contains whitespace")
	}
	expires, err := os.ReadFile(filepath.Join(dir, cfg.Name+StaticKeyExpirySuffix))
	if err != nil {
		return errors.New("no expiry beside the value; re-issue the key")
	}
	cfg.ExpiresAt, err = time.Parse(time.DateOnly, strings.TrimSpace(string(expires)))
	if err != nil {
		return errors.New("expiry is not a YYYY-MM-DD date")
	}
	if !now.Before(cfg.ExpiresAt) {
		return fmt.Errorf("expired on %s", cfg.ExpiresAt.UTC().Format(time.DateOnly))
	}
	return cfg.validateSecret(now)
}
