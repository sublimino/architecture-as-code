package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const wiringToken = "wiring-test-token-0123456789abcdef0123456789"

func eventsNamed(events []stunEvent, name string) []stunEvent {
	var out []stunEvent
	for _, e := range events {
		if e.Event == name {
			out = append(out, e)
		}
	}
	return out
}

// tenantOf builds the correlator exactly as main does and attributes the
// kusari-agent pod as it ships (forged `tenant` label included).
func tenantOf(t *testing.T, cfg *Config) string {
	t.Helper()
	opts, _ := correlatorOptions(cfg)
	m := correlator.NewSentinelProbeManager(nil, "", nil, opts...)
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "fe-signalloom-agents", Name: "kusari-agent-1",
			Labels: map[string]string{"signalloom.ai/tenant": "kusari", "tenant": "acme"}},
		Spec: corev1.PodSpec{ServiceAccountName: "kusari-agent"},
	}
	return m.NormalizeObservation(correlator.SyscallEvent{}, pod).TenantID
}

func TestIngestTokenComesFromTheEnvironmentAndIsNeverSerialised(t *testing.T) {
	t.Setenv("SIGNAL_INGEST_TOKEN", "  "+wiringToken+"\n")
	cfg := parseConfig([]string{})
	if cfg.IngestToken != wiringToken {
		t.Fatalf("IngestToken = %q, want the trimmed env value", cfg.IngestToken)
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), wiringToken) {
		t.Fatalf("serialised config leaks the ingest token: %s", raw)
	}
}

func TestTenantMapComesFromEnvWithFlagPrecedence(t *testing.T) {
	t.Setenv("SENTINEL_TENANT_MAP", "fe-signalloom-agents/kusari-agent=kusari")
	if got := parseConfig([]string{}).TenantMap; got != "fe-signalloom-agents/kusari-agent=kusari" {
		t.Fatalf("TenantMap from env = %q", got)
	}
	if got := parseConfig([]string{"--tenant-map=ns-a=acme"}).TenantMap; got != "ns-a=acme" {
		t.Fatalf("TenantMap with flag = %q, want the flag to win", got)
	}
}

func TestMissingIngestTokenIsReportedAtStartup(t *testing.T) {
	_, events := correlatorOptions(&Config{})
	if len(eventsNamed(events, "ingest_token_missing")) != 1 {
		t.Fatalf("want one ingest_token_missing event, got %+v", events)
	}
}

func TestConfiguredIngestTokenIsUsedAndNeverLogged(t *testing.T) {
	cfg := &Config{IngestToken: wiringToken}
	opts, events := correlatorOptions(cfg)
	if len(eventsNamed(events, "ingest_token_missing")) != 0 {
		t.Fatalf("a configured token was reported missing: %+v", events)
	}
	raw, _ := json.Marshal(events)
	if strings.Contains(string(raw), wiringToken) {
		t.Fatalf("a startup event leaks the ingest token: %s", raw)
	}
	if !correlator.NewSentinelProbeManager(nil, "", nil, opts...).IngestTokenConfigured() {
		t.Fatal("the configured token did not reach the correlator")
	}
}

func TestTenantMapReachesTheCorrelator(t *testing.T) {
	cfg := &Config{TenantMap: "fe-signalloom-agents/kusari-agent=kusari"}
	if got := tenantOf(t, cfg); got != "kusari" {
		t.Fatalf("tenant_id = %q, want kusari", got)
	}
	if _, events := correlatorOptions(cfg); len(eventsNamed(events, "tenant_map_loaded")) != 1 {
		t.Fatalf("want one tenant_map_loaded event, got %+v", events)
	}
}

// A malformed map must not stop the sentinel (that would stop the freeze) and
// must not half-apply: every workload is unattributed, and it is said loudly.
func TestInvalidTenantMapIsLoudAndAttributesNothing(t *testing.T) {
	cfg := &Config{TenantMap: "fe-signalloom-agents/kusari-agent=kusari,fe-signalloom-agents/x=kusarі"}
	if got := tenantOf(t, cfg); got != correlator.UnattributedTenantID {
		t.Fatalf("tenant_id = %q under an invalid map, want %q", got, correlator.UnattributedTenantID)
	}
	_, events := correlatorOptions(cfg)
	if bad := eventsNamed(events, "tenant_map_invalid"); len(bad) != 1 || bad[0].Error == "" {
		t.Fatalf("want one tenant_map_invalid event carrying the parse error, got %+v", events)
	}
}

func TestParseConfigDefaults(t *testing.T) {
	os.Unsetenv("STUN_DRY_RUN")
	os.Unsetenv("HEALTH_ADDR")
	os.Unsetenv("CGROUP_ROOT")
	os.Unsetenv("WATCH_NAMESPACE")

	cfg := parseConfig([]string{})
	if cfg.DryRun != false {
		t.Errorf("DryRun = %v, want false", cfg.DryRun)
	}
	if cfg.HealthAddr != ":8081" {
		t.Errorf("HealthAddr = %q, want :8081", cfg.HealthAddr)
	}
	if cfg.CgroupRoot != "/sys/fs/cgroup" {
		t.Errorf("CgroupRoot = %q, want /sys/fs/cgroup", cfg.CgroupRoot)
	}
	if cfg.WatchNamespace != "fe-signalloom-agents" {
		t.Errorf("WatchNamespace = %q, want fe-signalloom-agents", cfg.WatchNamespace)
	}
}

func TestParseConfigFlags(t *testing.T) {
	args := []string{
		"--dry-run",
		"--health-addr=:9090",
		"--cgroup-root=/host/cgroup",
		"--watch-namespace=custom-ns",
	}

	cfg := parseConfig(args)
	if !cfg.DryRun {
		t.Errorf("DryRun = false, want true")
	}
	if cfg.HealthAddr != ":9090" {
		t.Errorf("HealthAddr = %q, want :9090", cfg.HealthAddr)
	}
	if cfg.CgroupRoot != "/host/cgroup" {
		t.Errorf("CgroupRoot = %q, want /host/cgroup", cfg.CgroupRoot)
	}
	if cfg.WatchNamespace != "custom-ns" {
		t.Errorf("WatchNamespace = %q, want custom-ns", cfg.WatchNamespace)
	}
}

func TestParseConfigEnvVars(t *testing.T) {
	t.Setenv("STUN_DRY_RUN", "true")
	t.Setenv("HEALTH_ADDR", ":8888")
	t.Setenv("CGROUP_ROOT", "/env/cgroup")
	t.Setenv("WATCH_NAMESPACE", "env-ns")

	cfg := parseConfig([]string{})
	if !cfg.DryRun {
		t.Errorf("DryRun = false, want true from STUN_DRY_RUN")
	}
	if cfg.HealthAddr != ":8888" {
		t.Errorf("HealthAddr = %q, want :8888", cfg.HealthAddr)
	}
	if cfg.CgroupRoot != "/env/cgroup" {
		t.Errorf("CgroupRoot = %q, want /env/cgroup", cfg.CgroupRoot)
	}
	if cfg.WatchNamespace != "env-ns" {
		t.Errorf("WatchNamespace = %q, want env-ns", cfg.WatchNamespace)
	}
}

func TestParseConfigFlagPrecedenceOverEnv(t *testing.T) {
	t.Setenv("HEALTH_ADDR", ":7777")
	t.Setenv("CGROUP_ROOT", "/env/cgroup")
	t.Setenv("WATCH_NAMESPACE", "env-ns")

	cfg := parseConfig([]string{
		"--health-addr=:9999",
		"--cgroup-root=/flag/cgroup",
		"--watch-namespace=flag-ns",
	})

	if cfg.HealthAddr != ":9999" {
		t.Errorf("HealthAddr = %q, want :9999 (flag should override env)", cfg.HealthAddr)
	}
	if cfg.CgroupRoot != "/flag/cgroup" {
		t.Errorf("CgroupRoot = %q, want /flag/cgroup", cfg.CgroupRoot)
	}
	if cfg.WatchNamespace != "flag-ns" {
		t.Errorf("WatchNamespace = %q, want flag-ns", cfg.WatchNamespace)
	}
}

func TestIsTruthy(t *testing.T) {
	for _, val := range []string{"true", "1", "yes", "True", "TRUE", "on", "t"} {
		if !isTruthy(val) {
			t.Errorf("isTruthy(%q) = false, want true", val)
		}
	}
	for _, val := range []string{"false", "0", "no", "off", "", "unknown"} {
		if isTruthy(val) {
			t.Errorf("isTruthy(%q) = true, want false", val)
		}
	}
}
