package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

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
	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
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
	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
	if cfg.TenantMap != "fe-signalloom-agents/kusari-agent=kusari" {
		t.Fatalf("TenantMap from env = %q", cfg.TenantMap)
	}

	cfgFlag, err := parseConfig([]string{"--tenant-map=ns-a=acme"})
	if err != nil {
		t.Fatalf("parseConfig flag: %v", err)
	}
	if cfgFlag.TenantMap != "ns-a=acme" {
		t.Fatalf("TenantMap with flag = %q, want the flag to win", cfgFlag.TenantMap)
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
	os.Unsetenv("SIGNAL_INGEST_SPOOL_DIR")
	os.Unsetenv("SIGNAL_INGEST_SPOOL_MAX_BYTES")
	os.Unsetenv("SIGNAL_INGEST_SPOOL_MAX_AGE")
	os.Unsetenv("SIGNAL_INGEST_BATCH_MAX")
	os.Unsetenv("SIGNAL_INGEST_BATCH_LINGER")

	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
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
	if cfg.SpoolDir != "/var/lib/signalloom/spool" {
		t.Errorf("SpoolDir = %q, want /var/lib/signalloom/spool", cfg.SpoolDir)
	}
	if cfg.SpoolMaxBytes != 268435456 {
		t.Errorf("SpoolMaxBytes = %d, want 268435456", cfg.SpoolMaxBytes)
	}
	if cfg.SpoolMaxAge != 8*time.Hour {
		t.Errorf("SpoolMaxAge = %v, want 8h", cfg.SpoolMaxAge)
	}
	if cfg.BatchMax != 100 {
		t.Errorf("BatchMax = %d, want 100", cfg.BatchMax)
	}
	if cfg.BatchLinger != 250*time.Millisecond {
		t.Errorf("BatchLinger = %v, want 250ms", cfg.BatchLinger)
	}
}

func TestParseConfigFlags(t *testing.T) {
	args := []string{
		"--dry-run",
		"--health-addr=:9090",
		"--cgroup-root=/host/cgroup",
		"--watch-namespace=custom-ns",
		"--spool-dir=/custom/spool",
		"--spool-max-bytes=1048576",
		"--spool-max-age=4h",
		"--batch-max=50",
		"--batch-linger=100ms",
	}

	cfg, err := parseConfig(args)
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
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
	if cfg.SpoolDir != "/custom/spool" {
		t.Errorf("SpoolDir = %q, want /custom/spool", cfg.SpoolDir)
	}
	if cfg.SpoolMaxBytes != 1048576 {
		t.Errorf("SpoolMaxBytes = %d, want 1048576", cfg.SpoolMaxBytes)
	}
	if cfg.SpoolMaxAge != 4*time.Hour {
		t.Errorf("SpoolMaxAge = %v, want 4h", cfg.SpoolMaxAge)
	}
	if cfg.BatchMax != 50 {
		t.Errorf("BatchMax = %d, want 50", cfg.BatchMax)
	}
	if cfg.BatchLinger != 100*time.Millisecond {
		t.Errorf("BatchLinger = %v, want 100ms", cfg.BatchLinger)
	}
}

func TestParseConfigEnvVars(t *testing.T) {
	t.Setenv("STUN_DRY_RUN", "true")
	t.Setenv("HEALTH_ADDR", ":8888")
	t.Setenv("CGROUP_ROOT", "/env/cgroup")
	t.Setenv("WATCH_NAMESPACE", "env-ns")
	t.Setenv("SIGNAL_INGEST_SPOOL_DIR", "/env/spool")
	t.Setenv("SIGNAL_INGEST_SPOOL_MAX_BYTES", "52428800")
	t.Setenv("SIGNAL_INGEST_SPOOL_MAX_AGE", "12h")
	t.Setenv("SIGNAL_INGEST_BATCH_MAX", "200")
	t.Setenv("SIGNAL_INGEST_BATCH_LINGER", "500ms")

	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
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
	if cfg.SpoolDir != "/env/spool" {
		t.Errorf("SpoolDir = %q, want /env/spool", cfg.SpoolDir)
	}
	if cfg.SpoolMaxBytes != 52428800 {
		t.Errorf("SpoolMaxBytes = %d, want 52428800", cfg.SpoolMaxBytes)
	}
	if cfg.SpoolMaxAge != 12*time.Hour {
		t.Errorf("SpoolMaxAge = %v, want 12h", cfg.SpoolMaxAge)
	}
	if cfg.BatchMax != 200 {
		t.Errorf("BatchMax = %d, want 200", cfg.BatchMax)
	}
	if cfg.BatchLinger != 500*time.Millisecond {
		t.Errorf("BatchLinger = %v, want 500ms", cfg.BatchLinger)
	}
}

func TestConfigSpoolDefaults(t *testing.T) {
	os.Unsetenv("SIGNAL_INGEST_SPOOL_DIR")
	os.Unsetenv("SIGNAL_INGEST_SPOOL_MAX_BYTES")
	os.Unsetenv("SIGNAL_INGEST_SPOOL_MAX_AGE")
	os.Unsetenv("SIGNAL_INGEST_BATCH_MAX")
	os.Unsetenv("SIGNAL_INGEST_BATCH_LINGER")

	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}

	if cfg.SpoolDir != "/var/lib/signalloom/spool" {
		t.Errorf("SpoolDir default = %q, want /var/lib/signalloom/spool", cfg.SpoolDir)
	}
	if cfg.SpoolMaxBytes != 268435456 {
		t.Errorf("SpoolMaxBytes default = %d, want 268435456 (256 MiB)", cfg.SpoolMaxBytes)
	}
	if cfg.SpoolMaxAge != 8*time.Hour {
		t.Errorf("SpoolMaxAge default = %v, want 8h", cfg.SpoolMaxAge)
	}
	if cfg.BatchMax != 100 {
		t.Errorf("BatchMax default = %d, want 100", cfg.BatchMax)
	}
	if cfg.BatchLinger != 250*time.Millisecond {
		t.Errorf("BatchLinger default = %v, want 250ms", cfg.BatchLinger)
	}
}

func TestConfigSpoolValidEnvVars(t *testing.T) {
	t.Setenv("SIGNAL_INGEST_SPOOL_DIR", "/custom/spool")
	t.Setenv("SIGNAL_INGEST_SPOOL_MAX_BYTES", "1000000")
	t.Setenv("SIGNAL_INGEST_SPOOL_MAX_AGE", "2h30m")
	t.Setenv("SIGNAL_INGEST_BATCH_MAX", "50")
	t.Setenv("SIGNAL_INGEST_BATCH_LINGER", "150ms")

	cfg, err := parseConfig([]string{})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}

	if cfg.SpoolDir != "/custom/spool" {
		t.Errorf("SpoolDir = %q, want /custom/spool", cfg.SpoolDir)
	}
	if cfg.SpoolMaxBytes != 1000000 {
		t.Errorf("SpoolMaxBytes = %d, want 1000000", cfg.SpoolMaxBytes)
	}
	if cfg.SpoolMaxAge != 2*time.Hour+30*time.Minute {
		t.Errorf("SpoolMaxAge = %v, want 2h30m", cfg.SpoolMaxAge)
	}
	if cfg.BatchMax != 50 {
		t.Errorf("BatchMax = %d, want 50", cfg.BatchMax)
	}
	if cfg.BatchLinger != 150*time.Millisecond {
		t.Errorf("BatchLinger = %v, want 150ms", cfg.BatchLinger)
	}
}

func TestConfigSpoolRejectsNegativeOrMalformed(t *testing.T) {
	cases := []struct {
		envName string
		envVal  string
	}{
		{"SIGNAL_INGEST_SPOOL_MAX_BYTES", "-100"},
		{"SIGNAL_INGEST_SPOOL_MAX_BYTES", "notanumber"},
		{"SIGNAL_INGEST_SPOOL_MAX_AGE", "-5m"},
		{"SIGNAL_INGEST_SPOOL_MAX_AGE", "invalid-duration"},
		{"SIGNAL_INGEST_BATCH_MAX", "-10"},
		{"SIGNAL_INGEST_BATCH_MAX", "0"},
		{"SIGNAL_INGEST_BATCH_MAX", "xyz"},
		{"SIGNAL_INGEST_BATCH_LINGER", "-100ms"},
		{"SIGNAL_INGEST_BATCH_LINGER", "badtime"},
	}

	for _, tc := range cases {
		t.Run(tc.envName+"="+tc.envVal, func(t *testing.T) {
			t.Setenv(tc.envName, tc.envVal)
			cfg, err := parseConfig([]string{})
			if err == nil {
				t.Fatalf("parseConfig unexpectedly succeeded with %s=%q: %+v", tc.envName, tc.envVal, cfg)
			}
			if !strings.Contains(err.Error(), tc.envName) {
				t.Fatalf("error %q must name the offending env var %q", err.Error(), tc.envName)
			}
		})
	}
}

func TestParseConfigFlagPrecedenceOverEnv(t *testing.T) {
	t.Setenv("HEALTH_ADDR", ":7777")
	t.Setenv("CGROUP_ROOT", "/env/cgroup")
	t.Setenv("WATCH_NAMESPACE", "env-ns")

	cfg, err := parseConfig([]string{
		"--health-addr=:9999",
		"--cgroup-root=/flag/cgroup",
		"--watch-namespace=flag-ns",
	})
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}

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
