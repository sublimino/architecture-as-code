package main

import (
	"bytes"
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
	reconciledOverlay  = "../fe-signalloom/local"
	fluxRuntimeInfo    = "../../../d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml"
	staticBearerSecret = "signal-ingest-static-bearer"
	sentinelSPIFFEID   = "spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"
)

// bootstrapSecrets is every Secret the rendered Deployment may read and who provisions it. A
// secretKeyRef to anything else is a new bootstrap prerequisite nobody has written down, and fails.
var bootstrapSecrets = map[string]map[string]string{
	// inf-signalloom / bootstrap SQL; unchanged by this work.
	"discovery-portal-database": {
		"DATABASE_URL":            "postgres://signal@postgres.inf-signalloom:5432/signal",
		"IDENTITY_ENCRYPTION_KEY": strings.Repeat("ab", 32),
	},
	// scripts/sldc-ingest-bearer.sh.
	staticBearerSecret: {"token": testBearerToken},
}

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
		s, ok := bootstrapSecrets[name]
		if !ok {
			t.Fatalf("the Deployment reads Secret %s, which no bootstrap step provisions (known: discovery-portal-database, %s)",
				name, staticBearerSecret)
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
	clearStaticBearerEnv(t)
	for _, k := range []string{"SIGNAL_AUTH_AUDIENCE", "SIGNAL_AUTH_TRUST_DOMAIN", "SIGNAL_AUTH_JWKS",
		"SIGNAL_AUTH_JWKS_FILE", "SIGNAL_AUTH_JWKS_REFRESH", "SIGNAL_AUTH_BINDINGS", ProbePortEnvVar} {
		t.Setenv(k, "")
	}
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
	return a.Authenticate(r)
}

// TestReconciledManifestStartsSignalIngestWithAuthOn is the deployability gate: given the two
// things the bootstrap provisions (the bearer Secret, the synced JWKS), the rendered Deployment's
// environment passes the binary's own startup validation, the Secret's token authenticates as the
// correlator's scoped principal, and a JWT-SVID for the sentinel authenticates through the shipped
// bindings — the JWT path is configured, not merely present.
func TestReconciledManifestStartsSignalIngestWithAuthOn(t *testing.T) {
	r := renderReconciledManifest(t)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	env := containerEnv(t, r, t.TempDir(), map[string]string{"signal-ingest-jwks/jwks.json": syncedJWKS(t, "k1", key)})
	setContainerEnv(t, env)

	cfg, err := api.AuthConfigFromEnv()
	if err != nil {
		t.Fatalf("main would refuse startup (api.AuthConfigFromEnv): %v", err)
	}
	jwt, err := api.NewJWTAuthenticator(cfg)
	if err != nil {
		t.Fatalf("main would refuse startup (api.NewJWTAuthenticator): %v", err)
	}
	gateway, err := httpAuthenticator(jwt)
	if err != nil {
		t.Fatalf("main would refuse startup (httpAuthenticator): %v", err)
	}
	if _, ok := gateway.(*api.StaticBearerAuthenticator); !ok {
		t.Fatalf("rendered manifest does not enable the static bearer; the sentinel would 401 (gateway is %T)", gateway)
	}

	p, err := authenticate(t, gateway, testBearerToken)
	if err != nil {
		t.Fatalf("the token from Secret %s does not authenticate: %v", staticBearerSecret, err)
	}
	if p.TenantID != "kusari" || !p.Permissions[api.PermissionObservationWrite] || p.Permissions[api.PermissionObservationRead] {
		t.Fatalf("static principal scope = tenant %q perms %v, want kusari with observations:write and no read", p.TenantID, p.Permissions)
	}

	p, err = authenticate(t, gateway, mintJWTSVID(t, "k1", key, sentinelSPIFFEID, "signal-ingest"))
	if err != nil {
		t.Fatalf("a JWT-SVID for %s does not authenticate through the rendered bindings: %v", sentinelSPIFFEID, err)
	}
	if p.Subject != sentinelSPIFFEID || !p.Permissions[api.PermissionObservationWrite] {
		t.Fatalf("JWT principal = %+v", p)
	}
	if _, err := authenticate(t, gateway, mintJWTSVID(t, "k1", key, sentinelSPIFFEID, "wrong-audience")); err == nil {
		t.Fatal("a JWT-SVID for another audience authenticated; the rendered audience is not enforced")
	}
}

// TestReconciledManifestRefusesToStartBeforeTheJWKSIsSynced documents the one bootstrap
// prerequisite that is not a Secret: the shipped signal-ingest-jwks holds an empty key set, and the
// binary refuses to boot trusting nothing. The ConfigMap is created by Flux once and then left alone
// (ssa: IfNotPresent) so the bootstrap's sync survives reconciliation.
func TestReconciledManifestRefusesToStartBeforeTheJWKSIsSynced(t *testing.T) {
	r := renderReconciledManifest(t)
	setContainerEnv(t, containerEnv(t, r, t.TempDir(), nil))
	if _, err := api.AuthConfigFromEnv(); err == nil || !strings.Contains(err.Error(), "empty JWKS") {
		t.Fatalf("shipped JWKS placeholder: AuthConfigFromEnv err = %v, want the empty-JWKS refusal", err)
	}

	jwks, ok := r.object("ConfigMap", "signal-ingest-jwks")
	if !ok {
		t.Fatal("signal-ingest-jwks is not in the reconciled manifest")
	}
	if got := jwks.Metadata.Annotations["kustomize.toolkit.fluxcd.io/ssa"]; got != "IfNotPresent" {
		t.Fatalf("signal-ingest-jwks ssa annotation = %q, want IfNotPresent; otherwise every reconcile reverts the synced keys to an empty set and the next restart crash-loops", got)
	}
}

func TestReconciledManifestTakesTheTokenFromTheSecretOnly(t *testing.T) {
	r := renderReconciledManifest(t)
	var fromSecret bool
	for _, e := range r.container.Env {
		if e.Name != "SIGNAL_AUTH_STATIC_BEARER_TOKEN" {
			continue
		}
		ref := e.ValueFrom
		if e.Value != "" || ref == nil || ref.SecretKeyRef == nil || ref.SecretKeyRef.Name != staticBearerSecret || ref.SecretKeyRef.Key != "token" {
			t.Fatalf("SIGNAL_AUTH_STATIC_BEARER_TOKEN must come from secretKeyRef %s/token, got %+v", staticBearerSecret, e)
		}
		if ref.SecretKeyRef.Optional != nil && *ref.SecretKeyRef.Optional {
			t.Fatal("the token secretKeyRef is optional; a missing Secret would start a half-configured static bearer")
		}
		fromSecret = true
	}
	if !fromSecret {
		t.Fatal("the rendered Deployment does not source SIGNAL_AUTH_STATIC_BEARER_TOKEN from a Secret")
	}
	for _, o := range r.objects {
		if o.Kind == "ConfigMap" {
			if _, ok := o.Data["SIGNAL_AUTH_STATIC_BEARER_TOKEN"]; ok {
				t.Errorf("ConfigMap %s carries the static bearer token", o.Metadata.Name)
			}
		}
		if o.Kind == "Secret" && o.Metadata.Name == staticBearerSecret {
			t.Errorf("Secret %s is committed to the manifest; it must be minted at bootstrap", staticBearerSecret)
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
