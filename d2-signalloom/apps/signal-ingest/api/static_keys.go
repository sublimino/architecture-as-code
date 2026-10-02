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
// {name, subject, tenant, permissions, actor_ids, expires}. It lives in a ConfigMap.
const StaticKeysEnv = "SIGNAL_AUTH_STATIC_KEYS"

// StaticKeysDirEnv names the directory holding the secret half: one file per key, named after
// the key, projected from that key's own Secret. Defaults to DefaultStaticKeysDir.
const StaticKeysDirEnv = "SIGNAL_AUTH_STATIC_KEYS_DIR"

// DefaultStaticKeysDir is where the Deployment projects the key Secrets.
const DefaultStaticKeysDir = "/etc/signal-ingest/static-keys"

type staticKeySpec struct {
	Name        string       `json:"name"`
	Subject     string       `json:"subject"`
	Tenant      string       `json:"tenant"`
	Permissions []Permission `json:"permissions"`
	ActorIDs    []string     `json:"actor_ids"`
	Expires     string       `json:"expires"`
}

// StaticKeysFromEnv loads the configured keys.
//
// (nil, nil) when SIGNAL_AUTH_STATIC_KEYS is unset: the feature is off. Any malformed
// configuration — bad JSON, an unknown field (a value pasted into the ConfigMap is one), a
// duplicate or path-like name, an invalid key — is an error for main to refuse startup on.
//
// A key whose value file is absent is DISABLED, logged at ERROR by name, and the rest still load:
// one caller's Secret not yet minted must not take ingest down for every other caller. That is a
// narrowing, never a widening — the missing caller gets 401.
func StaticKeysFromEnv() ([]StaticBearerConfig, error) {
	raw := strings.TrimSpace(os.Getenv(StaticKeysEnv))
	if raw == "" {
		return nil, nil
	}
	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.DisallowUnknownFields()
	var specs []staticKeySpec
	if err := dec.Decode(&specs); err != nil {
		return nil, fmt.Errorf("%s is not a list of key specs: %w", StaticKeysEnv, err)
	}
	if len(specs) == 0 {
		return nil, fmt.Errorf("%s is set but names no keys; unset it to disable static keys", StaticKeysEnv)
	}
	dir := os.Getenv(StaticKeysDirEnv)
	if dir == "" {
		dir = DefaultStaticKeysDir
	}

	seen := map[string]bool{}
	var keys []StaticBearerConfig
	for _, spec := range specs {
		if !staticKeyNamePattern.MatchString(spec.Name) {
			return nil, fmt.Errorf("static key name %q must match %s", spec.Name, staticKeyNamePattern)
		}
		if seen[spec.Name] {
			return nil, fmt.Errorf("static key %q is configured twice", spec.Name)
		}
		seen[spec.Name] = true
		if spec.Expires == "" {
			return nil, fmt.Errorf("static key %q must carry an expiry; an undated temporary key is a permanent one", spec.Name)
		}
		expiresAt, err := time.Parse(time.DateOnly, spec.Expires)
		if err != nil {
			return nil, fmt.Errorf("static key %q: expires must be a YYYY-MM-DD date, got %q", spec.Name, spec.Expires)
		}
		cfg := StaticBearerConfig{
			Name: spec.Name, Subject: spec.Subject, TenantID: spec.Tenant,
			Permissions: spec.Permissions, ActorIDs: spec.ActorIDs, ExpiresAt: expiresAt,
		}

		value, err := os.ReadFile(filepath.Join(dir, spec.Name))
		if errors.Is(err, fs.ErrNotExist) {
			slog.Error("static key DISABLED: its Secret is not mounted; this caller will get 401",
				"key", spec.Name, "dir", dir)
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("static key %q: read value: %w", spec.Name, err)
		}
		// One trailing newline is how `echo` and most editors end a file; anything else is part
		// of the value, and whitespace inside a value is a copy-paste accident, not a key.
		cfg.Token = strings.TrimSuffix(string(value), "\n")
		if strings.ContainsAny(cfg.Token, " \t\r\n") {
			return nil, fmt.Errorf("static key %q: value contains whitespace", spec.Name)
		}
		// Validate here as well as in the constructor so the refusal names the key at load time.
		if err := cfg.validate(); err != nil {
			return nil, fmt.Errorf("static key %q: %w", spec.Name, err)
		}
		keys = append(keys, cfg)
	}
	// Duplicate values are refused here too, before anything is built from them.
	values := map[string]string{}
	for _, k := range keys {
		if other, dup := values[k.Token]; dup {
			return nil, fmt.Errorf("static keys %q and %q share one value; every caller needs its own key", other, k.Name)
		}
		values[k.Token] = k.Name
	}
	if len(keys) == 0 {
		slog.Error("every configured static key is disabled; only JWT-SVIDs can authenticate", "dir", dir)
		return nil, nil
	}
	return keys, nil
}
