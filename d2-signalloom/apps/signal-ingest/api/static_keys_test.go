package api

import (
	"bytes"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Named static keys: one per caller (Andy, 2026-10-02: "a bearer token with a long key is the
// simplest way … we'll have to use a static key for now"). The NON-secret half of each key —
// name, subject, tenant, permissions, expiry — is a JSON list in SIGNAL_AUTH_STATIC_KEYS (a
// ConfigMap). The secret half is a file named after the key under SIGNAL_AUTH_STATIC_KEYS_DIR,
// projected from that key's own Secret. A key value is never in env, argv, a ConfigMap or a log.

const (
	testGatewayToken = "Gw7x2Lq9pN4cR8tY1kD6hF3jS5aZ0mE7uB2oG9iX4wR"
	testGatewaySpec  = `{"name":"fe-signalloom-gateway","subject":"static-key/fe-signalloom-gateway","tenant":"kusari","permissions":["observations:read"],"expires":"2026-11-12"}`
	testSentinelSpec = `{"name":"stun-sentinel","subject":"static-bearer/stun-sentinel-correlator","tenant":"kusari","permissions":["observations:write","collectors:write"],"expires":"2026-11-12"}`
)

func clearStaticKeysEnv(t *testing.T) {
	t.Helper()
	t.Setenv(StaticKeysEnv, "")
	t.Setenv(StaticKeysDirEnv, "")
}

// setStaticKeysEnv points the loader at specs and writes each value as <dir>/<name>.
func setStaticKeysEnv(t *testing.T, specs string, values map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, v := range values {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o400); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv(StaticKeysEnv, specs)
	t.Setenv(StaticKeysDirEnv, dir)
	return dir
}

func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	restore := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(restore) })
	return &buf
}

func TestStaticKeysAbsentFromEnvYieldsNoConfig(t *testing.T) {
	clearStaticKeysEnv(t)
	keys, err := StaticKeysFromEnv()
	if err != nil || keys != nil {
		t.Fatalf("absent static keys: (%v, %v), want (nil, nil)", keys, err)
	}
}

func TestStaticKeysFromEnvLoadsEveryConfiguredKey(t *testing.T) {
	setStaticKeysEnv(t, "["+testSentinelSpec+","+testGatewaySpec+"]", map[string]string{
		"stun-sentinel":         testSentinelToken,
		"fe-signalloom-gateway": testGatewayToken + "\n", // a Secret written by `echo` carries one
	})
	keys, err := StaticKeysFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 {
		t.Fatalf("loaded %d keys, want 2", len(keys))
	}
	byName := map[string]StaticBearerConfig{}
	for _, k := range keys {
		byName[k.Name] = k
	}
	gw := byName["fe-signalloom-gateway"]
	if gw.Token != testGatewayToken || gw.Subject != "static-key/fe-signalloom-gateway" || gw.TenantID != "kusari" ||
		len(gw.Permissions) != 1 || gw.Permissions[0] != PermissionObservationRead ||
		!gw.ExpiresAt.Equal(time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("gateway key loaded wrong: name=%q subject=%q tenant=%q perms=%v expires=%s",
			gw.Name, gw.Subject, gw.TenantID, gw.Permissions, gw.ExpiresAt)
	}
	if byName["stun-sentinel"].Token != testSentinelToken {
		t.Fatal("sentinel key value not loaded from its file")
	}
}

// A refusal is a startup refusal: config that is wrong must not degrade to fewer keys or to a
// weaker gate. No refusal message may carry a key value.
func TestStaticKeysFromEnvRefusesInvalidConfig(t *testing.T) {
	good := map[string]string{"stun-sentinel": testSentinelToken}
	for _, tc := range []struct {
		name, specs string
		values      map[string]string
	}{
		{"not JSON", `[{`, good},
		{"an empty list", `[]`, good},
		{"a key value inline in the ConfigMap", `[{"name":"stun-sentinel","token":"` + testSentinelToken + `","subject":"s","tenant":"kusari","permissions":["observations:write"],"expires":"2026-11-12"}]`, good},
		{"duplicate names", "[" + testSentinelSpec + "," + testSentinelSpec + "]", good},
		{"name escaping the directory", `[{"name":"../stun-sentinel","subject":"s","tenant":"kusari","permissions":["observations:write"],"expires":"2026-11-12"}]`, good},
		{"no subject", `[{"name":"stun-sentinel","tenant":"kusari","permissions":["observations:write"],"expires":"2026-11-12"}]`, good},
		{"no tenant", `[{"name":"stun-sentinel","subject":"s","permissions":["observations:write"],"expires":"2026-11-12"}]`, good},
		{"no permissions", `[{"name":"stun-sentinel","subject":"s","tenant":"kusari","expires":"2026-11-12"}]`, good},
		{"unknown permission", `[{"name":"stun-sentinel","subject":"s","tenant":"kusari","permissions":["telemetry:write"],"expires":"2026-11-12"}]`, good},
		{"no expiry", `[{"name":"stun-sentinel","subject":"s","tenant":"kusari","permissions":["observations:write"]}]`, good},
		{"expiry not a date", `[{"name":"stun-sentinel","subject":"s","tenant":"kusari","permissions":["observations:write"],"expires":"soon"}]`, good},
		{"SPIFFE-shaped subject", `[{"name":"stun-sentinel","subject":"spiffe://osramp.local/ns/x/sa/y","tenant":"kusari","permissions":["observations:write"],"expires":"2026-11-12"}]`, good},
		{"value under 32 bytes", "[" + testSentinelSpec + "]", map[string]string{"stun-sentinel": "sentinel-in-cluster-token"}},
		{"value with whitespace inside", "[" + testSentinelSpec + "]", map[string]string{"stun-sentinel": testSentinelToken[:20] + " " + testSentinelToken[20:]}},
		{"two keys sharing one value", "[" + testSentinelSpec + "," + testGatewaySpec + "]", map[string]string{"stun-sentinel": testSentinelToken, "fe-signalloom-gateway": testSentinelToken}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			setStaticKeysEnv(t, tc.specs, tc.values)
			keys, err := StaticKeysFromEnv()
			if err == nil {
				t.Fatalf("invalid static keys accepted: %d keys", len(keys))
			}
			if keys != nil {
				t.Fatal("a refused configuration must return no keys")
			}
			if strings.Contains(err.Error(), testSentinelToken) || strings.Contains(err.Error(), "sentinel-in-cluster-token") {
				t.Fatalf("refusal leaks a key value: %v", err)
			}
		})
	}
}

// One caller's Secret missing (not yet minted, or deleted) disables that caller only: the other
// keys keep working and signal-ingest still boots. Loud, never silent.
func TestStaticKeysFromEnvDisablesOnlyAKeyWhoseSecretIsMissing(t *testing.T) {
	logs := captureLogs(t)
	setStaticKeysEnv(t, "["+testSentinelSpec+","+testGatewaySpec+"]", map[string]string{"stun-sentinel": testSentinelToken})
	keys, err := StaticKeysFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0].Name != "stun-sentinel" {
		t.Fatalf("loaded %+v, want only stun-sentinel", keys)
	}
	if !strings.Contains(logs.String(), `"level":"ERROR"`) || !strings.Contains(logs.String(), "fe-signalloom-gateway") {
		t.Fatalf("a disabled key must be logged at ERROR by name: %s", logs.String())
	}
}

func TestStaticKeysEachAuthenticateAsTheirOwnPrincipal(t *testing.T) {
	setStaticKeysEnv(t, "["+testSentinelSpec+","+testGatewaySpec+"]", map[string]string{
		"stun-sentinel": testSentinelToken, "fe-signalloom-gateway": testGatewayToken,
	})
	keys, err := StaticKeysFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticKeyAuthenticator(keys, delegate)
	if err != nil {
		t.Fatal(err)
	}
	logs := captureLogs(t)

	p, err := a.Authenticate(bearerRequest(http.MethodGet, "/api/v1/observations", testGatewayToken))
	if err != nil {
		t.Fatal(err)
	}
	if p.Subject != "static-key/fe-signalloom-gateway" || !p.Permissions[PermissionObservationRead] || p.Permissions[PermissionObservationWrite] {
		t.Fatalf("gateway key yielded %+v", p)
	}
	p, err = a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatal(err)
	}
	if p.Subject != "static-bearer/stun-sentinel-correlator" || p.Permissions[PermissionObservationRead] || !p.Permissions[PermissionObservationWrite] {
		t.Fatalf("sentinel key yielded %+v", p)
	}

	logged := logs.String()
	for _, name := range []string{`"key":"fe-signalloom-gateway"`, `"key":"stun-sentinel"`} {
		if !strings.Contains(logged, name) {
			t.Errorf("authentication not logged by key name %s: %s", name, logged)
		}
	}
	for _, secret := range []string{testGatewayToken, testSentinelToken} {
		if strings.Contains(logged, secret) {
			t.Fatalf("authentication log leaks a key value: %s", logged)
		}
	}
}

func TestNewStaticKeyAuthenticatorRefusesAmbiguousKeySets(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	one := testStaticConfig()
	sameName := testStaticConfig()
	sameName.Token = testGatewayToken
	sameValue := testStaticConfig()
	sameValue.Name = "fe-signalloom-gateway"
	for name, set := range map[string][]StaticBearerConfig{
		"no keys":            nil,
		"duplicate name":     {one, sameName},
		"duplicate value":    {one, sameValue},
		"one invalid member": {one, {Name: "x-y", Token: testGatewayToken}},
	} {
		if a, err := NewStaticKeyAuthenticator(set, delegate); err == nil || a != nil {
			t.Errorf("%s: accepted (%v, %v)", name, a, err)
		}
	}
}
