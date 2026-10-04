package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// SLAWS v2 D6: policy/bundles/<tenant>/<name>.yaml is the source of truth; the
// policy-engine-bundles ConfigMap is rendered from it by scripts/render-policy-bundles.sh.
// This test fails when the rendered manifest is stale, so a bundle edit cannot ship
// without `make policy-bundles-render`.
func TestRenderedBundlesConfigMapIsCurrent(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	src := filepath.Join(root, "policy", "bundles")
	want := map[string]string{}
	tenants, err := os.ReadDir(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	for _, tenant := range tenants {
		if !tenant.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(src, tenant.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range files {
			if f.IsDir() || !(strings.HasSuffix(f.Name(), ".yaml") || strings.HasSuffix(f.Name(), ".yml")) {
				continue
			}
			body, err := os.ReadFile(filepath.Join(src, tenant.Name(), f.Name()))
			if err != nil {
				t.Fatal(err)
			}
			want[tenant.Name()+"--"+f.Name()] = string(body)
		}
	}
	if len(want) == 0 {
		t.Fatal("no bundles under policy/bundles; D6 requires at least the kusari bundle")
	}

	raw, err := os.ReadFile(filepath.Join("base", "bundles-configmap.yaml"))
	if err != nil {
		t.Fatalf("rendered ConfigMap missing; run make policy-bundles-render: %v", err)
	}
	var cm struct {
		Kind     string                `yaml:"kind"`
		Metadata struct{ Name string } `yaml:"metadata"`
		Data     map[string]string     `yaml:"data"`
	}
	if err := yaml.Unmarshal(raw, &cm); err != nil {
		t.Fatal(err)
	}
	if cm.Kind != "ConfigMap" || cm.Metadata.Name != "policy-engine-bundles" {
		t.Fatalf("unexpected manifest identity: kind=%q name=%q", cm.Kind, cm.Metadata.Name)
	}
	gotKeys := keys(cm.Data)
	wantKeys := keys(want)
	if strings.Join(gotKeys, ",") != strings.Join(wantKeys, ",") {
		t.Fatalf("ConfigMap keys %v, source files %v: run make policy-bundles-render", gotKeys, wantKeys)
	}
	for k, body := range want {
		if strings.TrimRight(cm.Data[k], "\n") != strings.TrimRight(body, "\n") {
			t.Fatalf("ConfigMap key %s is stale relative to policy/bundles: run make policy-bundles-render", k)
		}
	}
}

// The deployment must point POLICY_BUNDLES_DIR at a mount of that ConfigMap, otherwise
// the engine boots with zero bundles (the gap W4 reported).
func TestDeploymentMountsTheBundlesConfigMap(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("base", "deployment.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(raw)
	for _, want := range []string{
		"name: POLICY_BUNDLES_DIR",
		"value: /etc/policy-engine/bundles",
		"mountPath: /etc/policy-engine/bundles",
		"name: policy-engine-bundles",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("deployment.yaml lacks %q", want)
		}
	}
	k, err := os.ReadFile(filepath.Join("base", "kustomization.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(k), "bundles-configmap.yaml") {
		t.Error("kustomization.yaml does not include bundles-configmap.yaml")
	}
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
