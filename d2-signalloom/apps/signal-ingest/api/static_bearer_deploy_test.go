package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

const deployedAuthConfigPath = "../deploy/jwt-auth-config.yaml"

const deployedAuthConfigMapName = "signal-ingest-jwt-auth"

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

// shippedKeyGrants is the least-privilege contract for every static key the manifest ships: the
// exact permission set each caller gets. A key added to the ConfigMap without a row here, or a
// permission added to a row's caller in YAML only, fails TestStaticKeysShippedGrantExactlyTheContract.
var shippedKeyGrants = map[string][]Permission{
	// The eBPF correlator: POST /api/v1/observations for whichever tenant the workload maps to.
	"stun-sentinel":     {PermissionObservationWrite, PermissionCrossTenantWrite},
	"signalloom-warden": {PermissionObservationWrite, PermissionCrossTenantWrite},
	// fe-signalloom: exactly what its proxies call (signal_fusion, risk, coding-agent telemetry,
	// claim delegation sync), acting for the verified user's tenant; cross-read only for "*".
	"fe-signalloom-gateway": {PermissionActForTenant, PermissionCrossTenantRead,
		PermissionObservationRead, PermissionObservationWrite, PermissionStream,
		PermissionActorList, PermissionActorRead, PermissionActorWrite,
		PermissionAnalysisRead, PermissionAnalysisRun, PermissionCollectorWrite,
		PermissionRiskRead, PermissionDelegationWrite},
	// scripts/signalfusion-demo.sh: healthz, seed, correlate, inject, actors, coverage, promote.
	"signalfusion-demo": {PermissionCrossTenantRead, PermissionHealth,
		PermissionObservationWrite, PermissionCollectorWrite, PermissionAnalysisRun,
		PermissionAnalysisRead, PermissionActorList, PermissionActorRead, PermissionActorWrite},
	// test/sfas-live-acceptance.bats: healthz, readyz, the authorization query.
	"sldc-live-bats": {PermissionCrossTenantRead, PermissionHealth, PermissionActorList},
	// e2e Step 4: reads kusari's observations, nothing else.
	"sldc-evidence-reader": {PermissionObservationRead},
}

// shippedKeyTenants pins each key's tenant.
var shippedKeyTenants = map[string]string{
	"stun-sentinel": "kusari", "signalloom-warden": "kusari", "fe-signalloom-gateway": "fe-signalloom", "signalfusion-demo": "tenant-demo",
	"sldc-live-bats": "tenant-demo", "sldc-evidence-reader": "kusari",
}

// loadShippedStaticKeys runs the shipped ConfigMap through the real loader, with a distinct
// synthetic value per key standing in for the Secret each key is projected from.
func loadShippedStaticKeys(t *testing.T) []StaticBearerConfig {
	t.Helper()
	cm := loadDeployedAuthConfigMap(t)
	raw, ok := cm.Data[StaticKeysEnv]
	if !ok {
		t.Fatalf("ConfigMap %s carries no %s", deployedAuthConfigMapName, StaticKeysEnv)
	}
	var specs []struct{ Name string }
	if err := json.Unmarshal([]byte(raw), &specs); err != nil {
		t.Fatalf("%s is not JSON: %v", StaticKeysEnv, err)
	}
	values := map[string]string{}
	for i, s := range specs {
		values[s.Name] = fmt.Sprintf("%s-%02d-%s", strings.Repeat("v", 32), i, s.Name)
	}
	setStaticKeysEnv(t, raw, values)
	keys, err := StaticKeysFromEnv()
	if err != nil {
		t.Fatalf("shipped static keys rejected by their own loader: %v", err)
	}
	if len(keys) != len(specs) {
		t.Fatalf("loaded %d of %d shipped keys", len(keys), len(specs))
	}
	return keys
}

// TestStaticBearerTokenIsNotInTheShippedManifest: key values are credentials, so they live in
// per-key Secrets (minted by scripts/sldc-ingest-bearer.sh), never in a ConfigMap and never in git.
func TestStaticBearerTokenIsNotInTheShippedManifest(t *testing.T) {
	cm := loadDeployedAuthConfigMap(t)
	for k := range cm.Data {
		if strings.Contains(k, "TOKEN") {
			t.Errorf("ConfigMap %s carries %s; key values belong in Secrets", deployedAuthConfigMapName, k)
		}
	}
	raw, err := os.ReadFile(deployedAuthConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(retiredPublicToken)) {
		t.Errorf("%s still names the retired public token %q", deployedAuthConfigPath, retiredPublicToken)
	}
}

// TestStaticKeysShippedGrantExactlyTheContract authenticates every shipped key with the real
// authenticator and compares its principal's permissions with shippedKeyGrants, both ways.
func TestStaticKeysShippedGrantExactlyTheContract(t *testing.T) {
	keys := loadShippedStaticKeys(t)
	delegate, _, _ := testJWTDelegate(t)
	a, err := NewStaticKeyAuthenticator(keys, delegate)
	if err != nil {
		t.Fatalf("shipped static keys rejected by the constructor: %v", err)
	}
	seen := map[string]bool{}
	for _, k := range keys {
		seen[k.Name] = true
		want, ok := shippedKeyGrants[k.Name]
		if !ok {
			t.Errorf("shipped key %s has no row in shippedKeyGrants", k.Name)
			continue
		}
		if k.TenantID != shippedKeyTenants[k.Name] {
			t.Errorf("key %s tenant = %q, want %q", k.Name, k.TenantID, shippedKeyTenants[k.Name])
		}
		// Configured grants, checked on the config rather than on a principal: an act-for key's
		// principal is shaped by the acting tenant, which is the act-for tests' subject.
		got := map[Permission]bool{}
		for _, perm := range k.Permissions {
			got[perm] = true
		}
		p := Principal{Permissions: got}
		if _, err := a.Authenticate(actingRequest(http.MethodGet, "/api/v1/observations", k.Token, "kusari")); err != nil {
			t.Fatalf("key %s does not authenticate with the shipped config: %v", k.Name, err)
		}
		granted := map[Permission]bool{}
		for _, perm := range want {
			granted[perm] = true
		}
		for permission := range KnownPermissions {
			if p.Permissions[permission] != granted[permission] {
				t.Errorf("key %s permission %q: granted=%v, want %v", k.Name, permission, p.Permissions[permission], granted[permission])
			}
		}
	}
	for name := range shippedKeyGrants {
		if !seen[name] {
			t.Errorf("shippedKeyGrants names %s, which the manifest does not ship", name)
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
	for _, want := range []string{"TEMPORARY", "90 days", "JWT-SVID"} {
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
