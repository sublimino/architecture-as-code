package api

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

const deployedAuthConfigPath = "../deploy/jwt-auth-config.yaml"

const deployedAuthConfigMapName = "signal-ingest-jwt-auth"

// expiryAnnotation makes the credential's deadline visible in the cluster, so
// `kubectl get cm -o yaml` answers "when does this go away" without reading Go.
const expiryAnnotation = "signalloom.ai/expires"

type deployedConfigMap struct {
	Metadata struct {
		Name        string            `yaml:"name"`
		Annotations map[string]string `yaml:"annotations"`
	} `yaml:"metadata"`
	Data map[string]string `yaml:"data"`
}

// loadDeployedAuthConfigMap returns the signal-ingest-jwt-auth ConfigMap from
// the shipped manifest.
func loadDeployedAuthConfigMap(t *testing.T) deployedConfigMap {
	t.Helper()
	raw, err := os.ReadFile(deployedAuthConfigPath)
	if err != nil {
		t.Fatalf("read %s: %v", deployedAuthConfigPath, err)
	}
	dec := yaml.NewDecoder(bytes.NewReader(raw))
	for {
		var cm deployedConfigMap
		err := dec.Decode(&cm)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("decode %s: %v", deployedAuthConfigPath, err)
		}
		if cm.Metadata.Name == deployedAuthConfigMapName {
			return cm
		}
	}
	t.Fatalf("%s holds no ConfigMap named %s", deployedAuthConfigPath, deployedAuthConfigMapName)
	return deployedConfigMap{}
}

// TestStaticBearerDeployedExpiryMatchesSunset stops the code constant and the
// deployed manifest from drifting apart: a credential whose YAML says one date
// and whose sunset gate says another has no real deadline at all.
func TestStaticBearerDeployedExpiryMatchesSunset(t *testing.T) {
	cm := loadDeployedAuthConfigMap(t)

	if got := cm.Data["SIGNAL_AUTH_STATIC_BEARER_EXPIRES"]; got != StaticBearerSunset {
		t.Errorf("SIGNAL_AUTH_STATIC_BEARER_EXPIRES = %q, want StaticBearerSunset %q", got, StaticBearerSunset)
	}
	if got := cm.Metadata.Annotations[expiryAnnotation]; got != StaticBearerSunset {
		t.Errorf("%s annotation = %q, want StaticBearerSunset %q", expiryAnnotation, got, StaticBearerSunset)
	}
}

// TestStaticBearerDeployedConfigAuthenticatesTheCorrelator runs the shipped
// ConfigMap through the real env loader and authenticator, so the assertion is
// about the manifest that actually reaches the cluster rather than about a
// config hand-built in a test.
func TestStaticBearerDeployedConfigAuthenticatesTheCorrelator(t *testing.T) {
	cm := loadDeployedAuthConfigMap(t)
	clearStaticBearerEnv(t)
	for k, v := range cm.Data {
		if strings.HasPrefix(k, "SIGNAL_AUTH_STATIC_BEARER_") {
			t.Setenv(k, v)
		}
	}

	cfg, err := StaticBearerConfigFromEnv()
	if err != nil {
		t.Fatalf("shipped static bearer config rejected by its own loader: %v", err)
	}
	if cfg == nil {
		t.Fatalf("%s carries no SIGNAL_AUTH_STATIC_BEARER_* keys", deployedAuthConfigPath)
	}

	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticBearerAuthenticator(*cfg, delegate)
	if err != nil {
		t.Fatalf("shipped static bearer config rejected by the constructor: %v", err)
	}

	// The token the correlator actually sends must be the token the manifest
	// configures; otherwise the deployed pair still 401s.
	p, err := a.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", testSentinelToken))
	if err != nil {
		t.Fatalf("the correlator's token is not the deployed token: %v", err)
	}
	if p.TenantID != "kusari" {
		t.Errorf("deployed tenant = %q, want kusari", p.TenantID)
	}
	granted := map[Permission]bool{PermissionObservationWrite: true, PermissionCollectorWrite: true}
	for permission := range KnownPermissions {
		if p.Permissions[permission] != granted[permission] {
			t.Errorf("deployed permission %q: granted=%v, want %v", permission, p.Permissions[permission], granted[permission])
		}
	}
}

// TestStaticBearerDeployedConfigIsMarkedTemporary asserts the manifest says in
// words that these keys are temporary and names what replaces them, so an
// operator reading only the YAML learns it without reading this package.
func TestStaticBearerDeployedConfigIsMarkedTemporary(t *testing.T) {
	raw, err := os.ReadFile(deployedAuthConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"TEMPORARY", StaticBearerSunset, "JWT-SVID"} {
		if !bytes.Contains(raw, []byte(want)) {
			t.Errorf("%s does not mention %q", deployedAuthConfigPath, want)
		}
	}
}

// TestKnownPermissionsCoversEveryRoute keeps KnownPermissions in step with the
// routes. If a new route introduces a permission the set does not list,
// StaticBearerConfig.validate would reject a legitimate grant for it.
func TestKnownPermissionsCoversEveryRoute(t *testing.T) {
	h, _ := newTestHandlers(t)
	for _, rd := range h.routeDefinitions(http.NotFoundHandler()) {
		if !KnownPermissions[rd.permission] {
			t.Errorf("route %s %s requires permission %q, which KnownPermissions does not list",
				rd.method, rd.path, rd.permission)
		}
	}
}
