package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/internal/imagetag"
)

// These tests answer "would the manifest the cluster reconciles start this binary", using the
// binary's own startup validation rather than a grep of YAML.
//
// What reaches kind-osramp: the signalloom-apps ResourceSet (d2-osramp-fleet/tenants/local/
// signalloom.yaml) creates Flux Kustomization fe-signalloom/apps with path ./fe-signalloom/local,
// targetNamespace fe-signalloom, and postBuild.substituteFrom flux-runtime-info. That overlay is
// ../base, which includes ../../signal-ingest/base. So: render that overlay with kustomize, apply
// the runtime-info substitution Flux applies, and feed the signal-ingest Deployment's resolved
// environment into api.AuthConfigFromEnv / httpAuthenticator exactly as main does.
const (
	reconciledOverlay = "../fe-signalloom/local"
	fluxRuntimeInfo   = "../../../d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml"
	sentinelSPIFFEID  = "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"
)

// bootstrapSecrets is every Secret the rendered Deployment may read and who provisions it. A
// secretKeyRef to anything else is a new bootstrap prerequisite nobody has written down, and fails.
var bootstrapSecrets = map[string]map[string]string{
	// inf-signalloom / bootstrap SQL; unchanged by this work.
	"discovery-portal-database": {
		"DATABASE_URL":            "postgres://signal@postgres.inf-signalloom:5432/signal",
		"IDENTITY_ENCRYPTION_KEY": strings.Repeat("ab", 32),
	},
}

// keySecretPrefix names every static key's Secret: signal-ingest-key-<name>, minted by
// scripts/sldc-ingest-bearer.sh. Any of them resolves to keyValue(<name>).
const keySecretPrefix = "signal-ingest-key-"

type k8sObject struct {
	Kind     string `yaml:"kind"`
	Metadata struct {
		Name        string            `yaml:"name"`
		Annotations map[string]string `yaml:"annotations"`
	} `yaml:"metadata"`
	Data map[string]string `yaml:"data"`
	Spec yaml.Node         `yaml:"spec"`
}

type keyRef struct {
	Name     string `yaml:"name"`
	Key      string `yaml:"key"`
	Optional *bool  `yaml:"optional"`
}

type probeSpec struct {
	HTTPGet *struct {
		Path string `yaml:"path"`
		Port any    `yaml:"port"`
	} `yaml:"httpGet"`
}

type containerSpec struct {
	Name  string `yaml:"name"`
	Image string `yaml:"image"`
	Ports []struct {
		Name          string `yaml:"name"`
		ContainerPort int    `yaml:"containerPort"`
	} `yaml:"ports"`
	Env []struct {
		Name      string `yaml:"name"`
		Value     string `yaml:"value"`
		ValueFrom *struct {
			ConfigMapKeyRef *keyRef `yaml:"configMapKeyRef"`
			SecretKeyRef    *keyRef `yaml:"secretKeyRef"`
		} `yaml:"valueFrom"`
	} `yaml:"env"`
	EnvFrom []struct {
		ConfigMapRef *keyRef `yaml:"configMapRef"`
		SecretRef    *keyRef `yaml:"secretRef"`
	} `yaml:"envFrom"`
	VolumeMounts []struct {
		Name      string `yaml:"name"`
		MountPath string `yaml:"mountPath"`
		ReadOnly  bool   `yaml:"readOnly"`
	} `yaml:"volumeMounts"`
	StartupProbe   *probeSpec `yaml:"startupProbe"`
	LivenessProbe  *probeSpec `yaml:"livenessProbe"`
	ReadinessProbe *probeSpec `yaml:"readinessProbe"`
}

type deploymentSpec struct {
	Template struct {
		Spec struct {
			Containers []containerSpec `yaml:"containers"`
			Volumes    []struct {
				Name      string `yaml:"name"`
				ConfigMap *struct {
					Name string `yaml:"name"`
				} `yaml:"configMap"`
				Secret *struct {
					SecretName string `yaml:"secretName"`
				} `yaml:"secret"`
				// A signal store on an emptyDir is erased on every reschedule, so
				// decoding both tells the durability test which one it got rather
				// than letting an absent claim read as "no volume configured".
				EmptyDir              *struct{} `yaml:"emptyDir"`
				PersistentVolumeClaim *struct {
					ClaimName string `yaml:"claimName"`
				} `yaml:"persistentVolumeClaim"`
				Projected *struct {
					Sources []struct {
						Secret *struct {
							Name  string `yaml:"name"`
							Items []struct {
								Key  string `yaml:"key"`
								Path string `yaml:"path"`
							} `yaml:"items"`
						} `yaml:"secret"`
					} `yaml:"sources"`
				} `yaml:"projected"`
			} `yaml:"volumes"`
		} `yaml:"spec"`
	} `yaml:"template"`
}

type rendered struct {
	objects    []k8sObject
	deployment deploymentSpec
	container  containerSpec
}

func (r rendered) object(kind, name string) (k8sObject, bool) {
	for _, o := range r.objects {
		if o.Kind == kind && o.Metadata.Name == name {
			return o, true
		}
	}
	return k8sObject{}, false
}

var fluxVar = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// fluxSubstitute applies postBuild.substituteFrom the way kustomize-controller does: ${VAR} from
// the ConfigMap, $${VAR} passes through as a literal ${VAR}. An unresolved variable is returned
// so the caller can refuse it — Flux would silently substitute "".
func fluxSubstitute(in []byte, vars map[string]string) ([]byte, []string) {
	const escaped = "\x00ESCAPED_DOLLAR_BRACE\x00"
	s := strings.ReplaceAll(string(in), "$${", escaped)
	var missing []string
	s = fluxVar.ReplaceAllStringFunc(s, func(m string) string {
		name := fluxVar.FindStringSubmatch(m)[1]
		v, ok := vars[name]
		if !ok {
			missing = append(missing, name)
		}
		return v
	})
	return []byte(strings.ReplaceAll(s, escaped, "${")), missing
}

func renderReconciledManifest(t *testing.T) rendered {
	t.Helper()
	out, err := exec.Command("kubectl", "kustomize", reconciledOverlay).Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			t.Fatalf("kubectl kustomize %s: %v\n%s", reconciledOverlay, err, ee.Stderr)
		}
		t.Fatalf("kubectl kustomize %s: %v (kubectl is required: this test renders what Flux renders)", reconciledOverlay, err)
	}

	rawInfo, err := os.ReadFile(fluxRuntimeInfo)
	if err != nil {
		t.Fatalf("read %s: %v", fluxRuntimeInfo, err)
	}
	var info k8sObject
	if err := yaml.Unmarshal(rawInfo, &info); err != nil || len(info.Data) == 0 {
		t.Fatalf("decode flux-runtime-info: %v", err)
	}

	var r rendered
	dec := yaml.NewDecoder(bytes.NewReader(out))
	for {
		var node yaml.Node
		if err := dec.Decode(&node); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			t.Fatalf("decode rendered manifest: %v", err)
		}
		docBytes, err := yaml.Marshal(&node)
		if err != nil {
			t.Fatal(err)
		}
		var o k8sObject
		if err := yaml.Unmarshal(docBytes, &o); err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(o.Metadata.Name, "signal-ingest") && !strings.HasPrefix(o.Metadata.Name, "allow-signal-ingest") {
			r.objects = append(r.objects, o)
			continue
		}
		substituted, missing := fluxSubstitute(docBytes, info.Data)
		if len(missing) > 0 {
			t.Fatalf("%s/%s uses ${%s}, which flux-runtime-info does not define; Flux would substitute an empty string",
				o.Kind, o.Metadata.Name, strings.Join(missing, "}, ${"))
		}
		if err := yaml.Unmarshal(substituted, &o); err != nil {
			t.Fatal(err)
		}
		r.objects = append(r.objects, o)
		if o.Kind == "Deployment" && o.Metadata.Name == "signal-ingest" {
			if err := o.Spec.Decode(&r.deployment); err != nil {
				t.Fatalf("decode signal-ingest Deployment: %v", err)
			}
		}
	}
	for _, c := range r.deployment.Template.Spec.Containers {
		if c.Name == "signal-ingest" {
			r.container = c
		}
	}
	if r.container.Name == "" {
		t.Fatalf("%s renders no signal-ingest container; the cluster would not run it at all", reconciledOverlay)
	}
	return r
}

// containerEnv resolves the container's environment the way the kubelet does, with ConfigMaps from
// the render, Secrets from bootstrapSecrets, and every ConfigMap volume materialised under root so
// that a path the binary reads (SIGNAL_AUTH_JWKS_FILE) exists. fileOverrides replaces a mounted
// file's content, keyed "<configmap>/<key>", to model a bootstrap step that rewrites it.
func containerEnv(t *testing.T, r rendered, root string, fileOverrides map[string]string) map[string]string {
	t.Helper()
	c := r.container
	env := map[string]string{}
	configMap := func(name string) map[string]string {
		cm, ok := r.object("ConfigMap", name)
		if !ok {
			t.Fatalf("the Deployment reads ConfigMap %s, which the reconciled manifest does not create", name)
		}
		return cm.Data
	}
	secret := func(name string) map[string]string {
		if strings.HasPrefix(name, keySecretPrefix) {
			return map[string]string{"token": keyValue(strings.TrimPrefix(name, keySecretPrefix)),
				"expires": time.Now().UTC().Add(30 * 24 * time.Hour).Format(time.DateOnly)}
		}
		s, ok := bootstrapSecrets[name]
		if !ok {
			t.Fatalf("the Deployment reads Secret %s, which no bootstrap step provisions (known: discovery-portal-database, %s<name>)",
				name, keySecretPrefix)
		}
		return s
	}
	for _, ef := range c.EnvFrom {
		switch {
		case ef.ConfigMapRef != nil:
			for k, v := range configMap(ef.ConfigMapRef.Name) {
				env[k] = v
			}
		case ef.SecretRef != nil:
			for k, v := range secret(ef.SecretRef.Name) {
				env[k] = v
			}
		}
	}
	for _, e := range c.Env {
		switch {
		case e.ValueFrom == nil:
			env[e.Name] = e.Value
		case e.ValueFrom.ConfigMapKeyRef != nil:
			ref := e.ValueFrom.ConfigMapKeyRef
			v, ok := configMap(ref.Name)[ref.Key]
			if !ok {
				t.Fatalf("env %s: ConfigMap %s has no key %s", e.Name, ref.Name, ref.Key)
			}
			env[e.Name] = v
		case e.ValueFrom.SecretKeyRef != nil:
			ref := e.ValueFrom.SecretKeyRef
			v, ok := secret(ref.Name)[ref.Key]
			if !ok {
				t.Fatalf("env %s: Secret %s has no key %s", e.Name, ref.Name, ref.Key)
			}
			env[e.Name] = v
		}
	}

	volumes := map[string]string{}
	for _, v := range r.deployment.Template.Spec.Volumes {
		if v.ConfigMap != nil {
			volumes[v.Name] = v.ConfigMap.Name
		}
	}
	for _, v := range r.deployment.Template.Spec.Volumes {
		if v.Projected == nil {
			continue
		}
		for _, m := range c.VolumeMounts {
			if m.Name != v.Name {
				continue
			}
			dir := filepath.Join(root, m.MountPath)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			for _, src := range v.Projected.Sources {
				if src.Secret == nil {
					continue
				}
				for _, it := range src.Secret.Items {
					if err := os.WriteFile(filepath.Join(dir, it.Path), []byte(secret(src.Secret.Name)[it.Key]), 0o400); err != nil {
						t.Fatal(err)
					}
				}
			}
			// The binary reads SIGNAL_AUTH_STATIC_KEYS_DIR, defaulting to the mount path.
			if env[api.StaticKeysDirEnv] == "" || env[api.StaticKeysDirEnv] == m.MountPath {
				env[api.StaticKeysDirEnv] = dir
			}
		}
	}
	for _, m := range c.VolumeMounts {
		cmName, ok := volumes[m.Name]
		if !ok {
			continue
		}
		dir := filepath.Join(root, m.MountPath)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		for k, v := range configMap(cmName) {
			if o, ok := fileOverrides[cmName+"/"+k]; ok {
				v = o
			}
			if err := os.WriteFile(filepath.Join(dir, k), []byte(v), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		for k, v := range env {
			if strings.HasPrefix(v, m.MountPath+"/") {
				env[k] = filepath.Join(root, v)
			}
		}
	}
	return env
}

func setContainerEnv(t *testing.T, env map[string]string) {
	t.Helper()
	clearAuthEnv(t)
	t.Setenv(ProbePortEnvVar, "")
	for k, v := range env {
		t.Setenv(k, v)
	}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// syncedJWKS is what scripts/bootstrap-spire-federation.sh writes into signal-ingest-jwks: the
// trust domain's jwt-svid keys, {kty,kid,crv,x,y,use}.
func syncedJWKS(t *testing.T, kid string, key *ecdsa.PrivateKey) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"keys": []map[string]string{{
		"kty": "EC", "kid": kid, "crv": "P-256", "use": "jwt-svid",
		"x": b64(key.X.FillBytes(make([]byte, 32))), "y": b64(key.Y.FillBytes(make([]byte, 32))),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// mintJWTSVID signs an ES256 JWT the way SPIRE does for `spire-agent api fetch jwt -audience`.
func mintJWTSVID(t *testing.T, kid string, key *ecdsa.PrivateKey, sub, aud string) string {
	t.Helper()
	hdr, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": kid, "typ": "JWT"})
	now := time.Now()
	claims, _ := json.Marshal(map[string]any{"sub": sub, "aud": []string{aud},
		"iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix()})
	signing := b64(hdr) + "." + b64(claims)
	digest := sha256.Sum256([]byte(signing))
	rs, ss, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := append(rs.FillBytes(make([]byte, 32)), ss.FillBytes(make([]byte, 32))...)
	return signing + "." + b64(sig)
}

func authenticate(t *testing.T, a api.Authenticator, token string) (api.Principal, error) {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	// The gateway key acts for a tenant; every other key ignores this header.
	r.Header.Set(api.ActingTenantHeader, "kusari")
	return a.Authenticate(r)
}

// keyValue is the synthetic value the bootstrap would mint for a key: distinct per key, ≥32 bytes.
func keyValue(name string) string { return "k-" + name + "-" + strings.Repeat("x", 40) }

// shippedKeyNames is every static key the rendered ConfigMap configures.
func shippedKeyNames(t *testing.T, r rendered) []string {
	t.Helper()
	cm, ok := r.object("ConfigMap", "signal-ingest-jwt-auth")
	if !ok {
		t.Fatal("ConfigMap signal-ingest-jwt-auth is not in the reconciled manifest")
	}
	var specs []struct{ Name string }
	if err := json.Unmarshal([]byte(cm.Data[api.StaticKeysEnv]), &specs); err != nil || len(specs) == 0 {
		t.Fatalf("rendered %s names no keys (%v)", api.StaticKeysEnv, err)
	}
	var names []string
	for _, s := range specs {
		names = append(names, s.Name)
	}
	return names
}

// TestReconciledManifestBootsOnStaticKeysAlone is the deployability gate for kind-osramp, where
// callers hold static keys and no SPIRE (Andy, 2026-10-02). Given only the per-key Secrets the
// issuer script mints, the rendered Deployment passes the binary's own startup path
// (gatewayFromEnv, as main calls it); every shipped key authenticates as its own principal; and a
// JWT is refused, because no JWKS is configured.
func TestReconciledManifestBootsOnStaticKeysAlone(t *testing.T) {
	r := renderReconciledManifest(t)
	setContainerEnv(t, containerEnv(t, r, t.TempDir(), nil))

	gateway, err := gatewayFromEnv(context.Background())
	if err != nil {
		t.Fatalf("main would refuse startup: %v", err)
	}
	if _, ok := gateway.(*api.StaticBearerAuthenticator); !ok {
		t.Fatalf("rendered manifest enables no static keys (gateway is %T)", gateway)
	}
	for _, name := range shippedKeyNames(t, r) {
		if _, err := authenticate(t, gateway, keyValue(name)); err != nil {
			t.Errorf("key %s from Secret %s%s does not authenticate: %v", name, keySecretPrefix, name, err)
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := authenticate(t, gateway, mintJWTSVID(t, "k1", key, sentinelSPIFFEID, "signal-ingest")); !errors.Is(err, api.ErrInvalidCredential) {
		t.Fatalf("a JWT-SVID with no JWKS configured: err = %v, want ErrInvalidCredential", err)
	}
}

// TestReconciledManifestCanStillEnableJWTSVIDs: the JWT path is configured, not merely present.
// Setting SIGNAL_AUTH_JWKS_FILE (the hub bootstrap does) over a synced key set turns it on beside
// the static keys; over the shipped empty placeholder the binary refuses to boot trusting nothing.
// The ConfigMap is created by Flux once and then left alone (ssa: IfNotPresent) so a sync survives
// reconciliation.
func TestReconciledManifestCanStillEnableJWTSVIDs(t *testing.T) {
	r := renderReconciledManifest(t)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	env := containerEnv(t, r, root, map[string]string{"signal-ingest-jwks/jwks.json": syncedJWKS(t, "k1", key)})
	env["SIGNAL_AUTH_JWKS_FILE"] = filepath.Join(root, "/etc/signal-ingest/auth/jwks.json")
	setContainerEnv(t, env)
	gateway, err := gatewayFromEnv(context.Background())
	if err != nil {
		t.Fatalf("JWKS enabled over synced keys: main would refuse startup: %v", err)
	}
	p, err := authenticate(t, gateway, mintJWTSVID(t, "k1", key, sentinelSPIFFEID, "signal-ingest"))
	if err != nil || p.Subject != sentinelSPIFFEID {
		t.Fatalf("a JWT-SVID for %s through the rendered bindings: (%+v, %v)", sentinelSPIFFEID, p, err)
	}
	if _, err := authenticate(t, gateway, mintJWTSVID(t, "k1", key, sentinelSPIFFEID, "wrong-audience")); err == nil {
		t.Fatal("a JWT-SVID for another audience authenticated; the rendered audience is not enforced")
	}
	if _, err := authenticate(t, gateway, keyValue(shippedKeyNames(t, r)[0])); err != nil {
		t.Fatalf("static keys stop working when JWKS is enabled: %v", err)
	}

	root = t.TempDir()
	env = containerEnv(t, r, root, nil)
	env["SIGNAL_AUTH_JWKS_FILE"] = filepath.Join(root, "/etc/signal-ingest/auth/jwks.json")
	setContainerEnv(t, env)
	if _, err := gatewayFromEnv(context.Background()); err == nil || !strings.Contains(err.Error(), "empty JWKS") {
		t.Fatalf("JWKS enabled over the shipped placeholder: err = %v, want the empty-JWKS refusal", err)
	}
	jwks, ok := r.object("ConfigMap", "signal-ingest-jwks")
	if !ok {
		t.Fatal("signal-ingest-jwks is not in the reconciled manifest")
	}
	if got := jwks.Metadata.Annotations["kustomize.toolkit.fluxcd.io/ssa"]; got != "IfNotPresent" {
		t.Fatalf("signal-ingest-jwks ssa annotation = %q, want IfNotPresent", got)
	}
}

// TestReconciledManifestTakesKeyValuesFromSecretsOnly: every configured key's value is projected
// from its own Secret, at the path the loader reads (<dir>/<name>); no value is in env, in a
// ConfigMap, or committed as a Secret.
func TestReconciledManifestTakesKeyValuesFromSecretsOnly(t *testing.T) {
	r := renderReconciledManifest(t)
	projected := map[string]string{} // path -> secret
	for _, v := range r.deployment.Template.Spec.Volumes {
		if v.Name != "signal-ingest-static-keys" || v.Projected == nil {
			continue
		}
		for _, src := range v.Projected.Sources {
			if src.Secret == nil {
				t.Errorf("static-keys volume projects a non-Secret source")
				continue
			}
			for _, it := range src.Secret.Items {
				name := strings.TrimPrefix(src.Secret.Name, keySecretPrefix)
				switch {
				case it.Key == "token" && it.Path == name:
				case it.Key == "expires" && it.Path == name+api.StaticKeyExpirySuffix:
				default:
					t.Errorf("Secret %s projects %s -> %s; want token -> %s and expires -> %s%s",
						src.Secret.Name, it.Key, it.Path, name, name, api.StaticKeyExpirySuffix)
				}
				projected[it.Path] = src.Secret.Name
			}
		}
	}
	for _, name := range shippedKeyNames(t, r) {
		for _, path := range []string{name, name + api.StaticKeyExpirySuffix} {
			if got := projected[path]; got != keySecretPrefix+name {
				t.Errorf("%s is projected from %q, want Secret %s%s", path, got, keySecretPrefix, name)
			}
		}
	}
	var mounted bool
	for _, m := range r.container.VolumeMounts {
		if m.Name == "signal-ingest-static-keys" {
			mounted = m.MountPath == api.DefaultStaticKeysDir && m.ReadOnly
		}
	}
	if !mounted {
		t.Errorf("the static-keys volume is not mounted read-only at %s", api.DefaultStaticKeysDir)
	}
	for _, e := range r.container.Env {
		if strings.Contains(e.Name, "TOKEN") || (e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil && strings.HasPrefix(e.ValueFrom.SecretKeyRef.Name, keySecretPrefix)) {
			t.Errorf("env %s carries a key value; values are files, never env", e.Name)
		}
	}
	for _, o := range r.objects {
		if o.Kind == "ConfigMap" {
			for k := range o.Data {
				if strings.Contains(k, "TOKEN") {
					t.Errorf("ConfigMap %s carries %s", o.Metadata.Name, k)
				}
			}
		}
		if o.Kind == "Secret" && strings.HasPrefix(o.Metadata.Name, keySecretPrefix) {
			t.Errorf("Secret %s is committed to the manifest; it must be minted at bootstrap", o.Metadata.Name)
		}
	}
}

func portNumber(t *testing.T, c containerSpec, port any) int {
	t.Helper()
	switch p := port.(type) {
	case int:
		return p
	case string:
		if n, err := strconv.Atoi(p); err == nil {
			return n
		}
		for _, cp := range c.Ports {
			if cp.Name == p {
				return cp.ContainerPort
			}
		}
	}
	t.Fatalf("probe port %v names no container port", port)
	return 0
}

// TestReconciledManifestProbesTheProbeListener: an anonymous kubelet probe against the API port
// is a 401 (every route there is authenticated), so the probes must target the port the binary
// opens for them — and that port must not be published by the Service or the ingress policy.
func TestReconciledManifestProbesTheProbeListener(t *testing.T) {
	r := renderReconciledManifest(t)
	setContainerEnv(t, containerEnv(t, r, t.TempDir(), nil))
	want, err := strconv.Atoi(probePort())
	if err != nil {
		t.Fatalf("probePort() = %q is not a port", probePort())
	}
	for name, p := range map[string]*probeSpec{"startupProbe": r.container.StartupProbe,
		"livenessProbe": r.container.LivenessProbe, "readinessProbe": r.container.ReadinessProbe} {
		if p == nil || p.HTTPGet == nil {
			t.Errorf("%s is not an httpGet probe", name)
			continue
		}
		if got := portNumber(t, r.container, p.HTTPGet.Port); got != want {
			t.Errorf("%s targets port %d, but the binary serves probes on %d (the API port 401s the kubelet)", name, got, want)
		}
	}
	if r.container.ReadinessProbe != nil && r.container.ReadinessProbe.HTTPGet != nil && r.container.ReadinessProbe.HTTPGet.Path != "/readyz" {
		t.Errorf("readinessProbe path = %q, want /readyz (the audit-backend check)", r.container.ReadinessProbe.HTTPGet.Path)
	}

	svc, ok := r.object("Service", "signal-ingest")
	if !ok {
		t.Fatal("Service signal-ingest is not in the reconciled manifest")
	}
	var spec struct {
		Ports []struct {
			Port       int `yaml:"port"`
			TargetPort any `yaml:"targetPort"`
		} `yaml:"ports"`
	}
	if err := svc.Spec.Decode(&spec); err != nil {
		t.Fatal(err)
	}
	for _, p := range spec.Ports {
		if portNumber(t, r.container, p.TargetPort) == want {
			t.Errorf("Service signal-ingest publishes the probe port %d", want)
		}
	}
	np, ok := r.object("NetworkPolicy", "allow-signal-ingest-ingress")
	if !ok {
		t.Fatal("NetworkPolicy allow-signal-ingest-ingress is not in the reconciled manifest")
	}
	var policy struct {
		Ingress []struct {
			Ports []struct {
				Port any `yaml:"port"`
			} `yaml:"ports"`
		} `yaml:"ingress"`
	}
	if err := np.Spec.Decode(&policy); err != nil {
		t.Fatal(err)
	}
	for _, rule := range policy.Ingress {
		if len(rule.Ports) == 0 {
			t.Error("an ingress rule admits every port, including the unauthenticated probe port")
		}
		for _, p := range rule.Ports {
			if portNumber(t, r.container, p.Port) == want {
				t.Errorf("NetworkPolicy admits pod traffic to the probe port %d", want)
			}
		}
	}
}

// TestReconciledManifestRunsTheImageBuiltFromThisSource: the image is an immutable tag in the
// in-cluster zot, derived from exactly the files the Dockerfile's go build reads. A stale pin (code
// changed, manifest not re-pinned) is red here, which is the moment to rebuild and push.
func TestReconciledManifestRunsTheImageBuiltFromThisSource(t *testing.T) {
	r := renderReconciledManifest(t)
	tag, err := imagetag.Tag(".")
	if err != nil {
		t.Fatalf("imagetag.Tag: %v", err)
	}
	want := "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signal-ingest:" + tag
	if r.container.Image != want {
		t.Fatalf("rendered image = %q\nwant           %q\nre-pin with: go run ./cmd/image-tag (see the Makefile signal-ingest-image target)",
			r.container.Image, want)
	}
}

// issuerScript is the key issuer; its KEYS registry names each key's consumer Secret.
const issuerScript = "../../../scripts/sldc-ingest-bearer.sh"

var keyRegistryRow = regexp.MustCompile(`(?m)^\s+"([a-z][a-z0-9-]+)\|([a-z0-9-]*)\|([a-z0-9-]*)\|`)

// issuerRegistry is name -> "namespace/secret" (empty for a key with no in-cluster consumer).
func issuerRegistry(t *testing.T) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(issuerScript)
	if err != nil {
		t.Fatal(err)
	}
	reg := map[string]string{}
	for _, m := range keyRegistryRow.FindAllStringSubmatch(string(raw), -1) {
		reg[m[1]] = ""
		if m[2] != "" {
			reg[m[1]] = m[2] + "/" + m[3]
		}
	}
	if len(reg) == 0 {
		t.Fatalf("no KEYS rows parsed from %s", issuerScript)
	}
	return reg
}

func renderedDeployment(t *testing.T, r rendered, name string) deploymentSpec {
	t.Helper()
	o, ok := r.object("Deployment", name)
	if !ok {
		t.Fatalf("Deployment %s is not in the reconciled manifest", name)
	}
	var d deploymentSpec
	if err := o.Spec.Decode(&d); err != nil {
		t.Fatal(err)
	}
	return d
}

// Every key signal-ingest is configured with can be minted by the issuer, and nothing else can.
func TestEveryShippedKeyIsInTheIssuerRegistry(t *testing.T) {
	r := renderReconciledManifest(t)
	reg := issuerRegistry(t)
	shipped := map[string]bool{}
	for _, name := range shippedKeyNames(t, r) {
		shipped[name] = true
		if _, ok := reg[name]; !ok {
			t.Errorf("key %s is configured in signal-ingest but %s cannot mint it", name, issuerScript)
		}
	}
	for name := range reg {
		if !shipped[name] {
			t.Errorf("%s mints key %s, which signal-ingest is not configured with", issuerScript, name)
		}
	}
}

// Each in-cluster caller mounts its OWN consumer Secret, the one the issuer writes, read-only, and
// points SIGNAL_INGEST_KEY_FILE at it; the value never travels as an env var.
func TestEachInClusterCallerMountsItsOwnKey(t *testing.T) {
	r := renderReconciledManifest(t)
	reg := issuerRegistry(t)
	for _, tc := range []struct{ key, deployment, container string }{
		{"fe-signalloom-gateway", "fe-signalloom", "discovery-portal"},
		{"signalfusion-demo", "supercred-demo-runner", "runner"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			want := reg[tc.key]
			if !strings.HasPrefix(want, "fe-signalloom/") {
				t.Fatalf("issuer registry gives key %s consumer %q, want a Secret in fe-signalloom", tc.key, want)
			}
			secret := strings.TrimPrefix(want, "fe-signalloom/")
			d := renderedDeployment(t, r, tc.deployment)
			volume := ""
			for _, v := range d.Template.Spec.Volumes {
				if v.Secret != nil && v.Secret.SecretName == secret {
					volume = v.Name
				}
			}
			if volume == "" {
				t.Fatalf("Deployment %s mounts no volume from Secret %s", tc.deployment, secret)
			}
			var c *containerSpec
			for i := range d.Template.Spec.Containers {
				if d.Template.Spec.Containers[i].Name == tc.container {
					c = &d.Template.Spec.Containers[i]
				}
			}
			if c == nil {
				t.Fatalf("Deployment %s has no container %s", tc.deployment, tc.container)
			}
			mountPath := ""
			for _, m := range c.VolumeMounts {
				if m.Name == volume {
					if !m.ReadOnly {
						t.Errorf("%s mounts %s writable", tc.container, volume)
					}
					mountPath = m.MountPath
				}
			}
			if mountPath == "" {
				t.Fatalf("container %s does not mount volume %s", tc.container, volume)
			}
			var keyFile string
			for _, e := range c.Env {
				if e.Name == "SIGNAL_INGEST_KEY_FILE" {
					keyFile = e.Value
				}
				if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil && e.ValueFrom.SecretKeyRef.Name == secret {
					t.Errorf("env %s carries the key value; it must be read from the mounted file", e.Name)
				}
			}
			if keyFile != mountPath+"/token" {
				t.Errorf("SIGNAL_INGEST_KEY_FILE = %q, want %s/token", keyFile, mountPath)
			}
		})
	}
}

// TestReconciledManifestStoresSignalsDurably is the P1-1 durability gate.
//
// Two halves of one claim, which is why they are asserted together. The binary only opens the
// Parquet-backed FrostDB store when SIGNAL_STORE=frostdb (store/factory_frostdb.go); unset, it
// silently returns a MemoryStore and every observation lives in RAM. And a FrostDB store whose
// SIGNAL_STORE_DIR is an emptyDir is erased on every reschedule, so it would be durable only
// until the pod moved. Either half alone is a store that loses data while reporting success, so a
// manifest that sets the env without the claim, or mounts the claim without the env, is red here.
func TestReconciledManifestStoresSignalsDurably(t *testing.T) {
	r := renderReconciledManifest(t)

	env := map[string]string{}
	for _, e := range r.container.Env {
		if e.ValueFrom == nil {
			env[e.Name] = e.Value
		}
	}
	if got := env["SIGNAL_STORE"]; got != "frostdb" {
		t.Errorf("SIGNAL_STORE = %q, want %q; store.NewStoreFromEnv returns an in-memory store on anything else", got, "frostdb")
	}
	const storeDir = "/data/signals"
	if got := env["SIGNAL_STORE_DIR"]; got != storeDir {
		t.Errorf("SIGNAL_STORE_DIR = %q, want %q", got, storeDir)
	}

	// The store directory is backed by a claim, and mounted writable where the binary writes.
	var claimName string
	var found bool
	for _, v := range r.deployment.Template.Spec.Volumes {
		if v.Name != "signal-store" {
			continue
		}
		found = true
		if v.EmptyDir != nil {
			t.Errorf("volume signal-store is an emptyDir; %s is erased on every reschedule", storeDir)
		}
		if v.PersistentVolumeClaim == nil {
			t.Fatal("volume signal-store has no persistentVolumeClaim")
		}
		claimName = v.PersistentVolumeClaim.ClaimName
	}
	if !found {
		t.Fatal("the Deployment declares no signal-store volume")
	}
	var mounted bool
	for _, m := range r.container.VolumeMounts {
		if m.Name != "signal-store" {
			continue
		}
		mounted = m.MountPath == storeDir
		if m.ReadOnly {
			t.Error("signal-store is mounted read-only; the store writes Parquet files to it")
		}
	}
	if !mounted {
		t.Errorf("signal-store is not mounted at %s, where SIGNAL_STORE_DIR points", storeDir)
	}

	// The claim is reconciled alongside the Deployment; a claimName naming nothing leaves the pod
	// Pending forever, which is the failure this assertion catches at build time instead.
	pvc, ok := r.object("PersistentVolumeClaim", claimName)
	if !ok {
		t.Fatalf("the Deployment claims %q, which the reconciled manifest does not create", claimName)
	}
	var spec struct {
		AccessModes      []string `yaml:"accessModes"`
		StorageClassName *string  `yaml:"storageClassName"`
		Resources        struct {
			Requests struct {
				Storage string `yaml:"storage"`
			} `yaml:"requests"`
		} `yaml:"resources"`
	}
	if err := pvc.Spec.Decode(&spec); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(spec.AccessModes, []string{"ReadWriteOnce"}) {
		t.Errorf("accessModes = %v, want [ReadWriteOnce]; one writer, which is what replicas: 1 is", spec.AccessModes)
	}
	if got := spec.Resources.Requests.Storage; got != "10Gi" {
		t.Errorf("storage request = %q, want 10Gi", got)
	}
	// Unset, not "": an explicit empty string means "no class", which disables dynamic
	// provisioning and is not the same as taking the cluster default.
	if spec.StorageClassName != nil {
		t.Errorf("storageClassName = %q, want it unset so the cluster default provisions the volume", *spec.StorageClassName)
	}
}
