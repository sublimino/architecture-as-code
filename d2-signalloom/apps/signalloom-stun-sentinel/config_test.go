package main

import (
	"os"
	"testing"
)

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
