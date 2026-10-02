// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package deploy

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

const (
	sentinelConfigMap = "../../../infra/agent-swarm/signalloom-stun-sentinel/configmap.yaml"
	kusariDeployment  = "../../../infra/agent-swarm/kusari-agent/deployment.yaml"
)

func envNamed(t *testing.T, name string) corev1.EnvVar {
	t.Helper()
	c := sentinelContainer(t, canonical, loadDaemonSet(t, canonical))
	for _, e := range c.Env {
		if e.Name == name {
			return e
		}
	}
	t.Fatalf("%s is not set on the sentinel container", name)
	return corev1.EnvVar{}
}

func loadSentinelConfigMap(t *testing.T) corev1.ConfigMap {
	t.Helper()
	raw, err := os.ReadFile(sentinelConfigMap)
	if err != nil {
		t.Fatal(err)
	}
	for _, doc := range bytes.Split(raw, []byte("\n---")) {
		var cm corev1.ConfigMap
		if yaml.Unmarshal(doc, &cm) == nil && cm.Kind == "ConfigMap" && cm.Name == "stun-sentinel-config" {
			return cm
		}
	}
	t.Fatal("configmap.yaml declares no ConfigMap stun-sentinel-config")
	return corev1.ConfigMap{}
}

// The cross-slice contract (SLDC fix run 2): the bearer lives in Secret
// stun-sentinel-ingest-token, key token, and reaches the binary only as
// SIGNAL_INGEST_TOKEN via secretKeyRef. Optional, because a missing Secret
// must not keep the pod -- and so the freeze -- from starting; the binary
// reports the absence itself.
func TestIngestTokenComesOnlyFromItsSecret(t *testing.T) {
	e := envNamed(t, "SIGNAL_INGEST_TOKEN")
	if e.Value != "" {
		t.Fatal("SIGNAL_INGEST_TOKEN has a literal value in the manifest: the credential would be committed")
	}
	if e.ValueFrom == nil || e.ValueFrom.SecretKeyRef == nil {
		t.Fatal("SIGNAL_INGEST_TOKEN must come from a secretKeyRef")
	}
	ref := e.ValueFrom.SecretKeyRef
	if ref.Name != "stun-sentinel-ingest-token" || ref.Key != "token" {
		t.Fatalf("secretKeyRef = %s/%s, want stun-sentinel-ingest-token/token", ref.Name, ref.Key)
	}
	if ref.Optional == nil || !*ref.Optional {
		t.Fatal("the token Secret must be optional: a missing Secret would stop the pod and with it the freeze")
	}
}

func TestNoCredentialIsCarriedInTheSentinelConfigMap(t *testing.T) {
	for k, v := range loadSentinelConfigMap(t).Data {
		if strings.Contains(strings.ToLower(k), "token") || strings.Contains(v, "sentinel-in-cluster-token") {
			t.Fatalf("ConfigMap key %q carries a credential; `get configmaps` would read it", k)
		}
	}
}

func TestTenantMapComesFromTheSentinelConfigMap(t *testing.T) {
	e := envNamed(t, "SENTINEL_TENANT_MAP")
	if e.ValueFrom == nil || e.ValueFrom.ConfigMapKeyRef == nil ||
		e.ValueFrom.ConfigMapKeyRef.Name != "stun-sentinel-config" || e.ValueFrom.ConfigMapKeyRef.Key != "SENTINEL_TENANT_MAP" {
		t.Fatalf("SENTINEL_TENANT_MAP must come from configMapKeyRef stun-sentinel-config/SENTINEL_TENANT_MAP, got %+v", e.ValueFrom)
	}
}

// Live Step 4 asserts tenant_id == kusari for the kusari-agent pod. That now
// holds only because the base map names the namespace and service account the
// kusari Deployment actually runs as -- read from its manifest, not assumed.
func TestBaseTenantMapAttributesTheKusariDeploymentToKusari(t *testing.T) {
	tm, err := correlator.ParseTenantMap(loadSentinelConfigMap(t).Data["SENTINEL_TENANT_MAP"])
	if err != nil {
		t.Fatalf("the shipped tenant map does not parse: %v", err)
	}
	raw, err := os.ReadFile(kusariDeployment)
	if err != nil {
		t.Fatal(err)
	}
	var dep appsv1.Deployment
	if err := yaml.Unmarshal(raw, &dep); err != nil {
		t.Fatal(err)
	}
	ns, sa := dep.Namespace, dep.Spec.Template.Spec.ServiceAccountName
	if got := tm.Resolve(ns, sa); got != "kusari" {
		t.Fatalf("kusari-agent (%s/%s) resolves to %q, want kusari", ns, sa, got)
	}
	// fe-signalloom-agents is shared by every swarm agent: it must be mapped
	// per service account, or every agent in it becomes kusari again.
	if got := tm.Resolve(ns, "some-other-agent"); got != correlator.UnattributedTenantID {
		t.Fatalf("another SA in %s resolves to %q; the shared namespace must not be mapped wholesale", ns, got)
	}
}
