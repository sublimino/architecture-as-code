package main

import (
	"flag"
	"os"
	"strings"
)

// Config encapsulates runtime configuration options for the STUN sentinel.
type Config struct {
	DryRun         bool   `json:"dry_run"`
	HealthAddr     string `json:"health_addr"`
	CgroupRoot     string `json:"cgroup_root"`
	WatchNamespace string `json:"watch_namespace"`
}

// parseConfig parses command-line flags and environment variables with the following precedence:
// 1. Explicit command-line flags (--dry-run, --health-addr, etc.)
// 2. Environment variables (STUN_DRY_RUN, HEALTH_ADDR, etc.)
// 3. Built-in default values
func parseConfig(args []string) *Config {
	fs := flag.NewFlagSet("signalloom-stun-sentinel", flag.ContinueOnError)

	dryRunFlag := fs.Bool("dry-run", false, "Enable positive dry-run mode (log containment decisions without mutating kernel state)")
	healthAddrFlag := fs.String("health-addr", "", "Address for the HTTP health/readiness server (default: :8081)")
	cgroupRootFlag := fs.String("cgroup-root", "", "Path to cgroup v2 root hierarchy")
	watchNamespaceFlag := fs.String("watch-namespace", "", "Kubernetes namespace to watch for agent pods")

	_ = fs.Parse(args)

	cfg := &Config{}

	// Dry-run mode: --dry-run flag OR STUN_DRY_RUN environment variable
	envDryRun := isTruthy(os.Getenv("STUN_DRY_RUN"))
	cfg.DryRun = *dryRunFlag || envDryRun

	// Health server address: --health-addr flag -> HEALTH_ADDR / STUN_HEALTH_ADDR env -> default :8081
	if *healthAddrFlag != "" {
		cfg.HealthAddr = *healthAddrFlag
	} else if val := os.Getenv("HEALTH_ADDR"); val != "" {
		cfg.HealthAddr = val
	} else if val := os.Getenv("STUN_HEALTH_ADDR"); val != "" {
		cfg.HealthAddr = val
	} else {
		cfg.HealthAddr = ":8081"
	}

	// Cgroup root: --cgroup-root flag -> CGROUP_ROOT env -> default /sys/fs/cgroup
	if *cgroupRootFlag != "" {
		cfg.CgroupRoot = *cgroupRootFlag
	} else if val := os.Getenv("CGROUP_ROOT"); val != "" {
		cfg.CgroupRoot = val
	} else {
		cfg.CgroupRoot = defaultCgroupRoot
	}

	// Watch namespace: --watch-namespace flag -> WATCH_NAMESPACE env -> default fe-signalloom-agents
	if *watchNamespaceFlag != "" {
		cfg.WatchNamespace = *watchNamespaceFlag
	} else if val := os.Getenv("WATCH_NAMESPACE"); val != "" {
		cfg.WatchNamespace = val
	} else {
		cfg.WatchNamespace = watchNamespace
	}

	return cfg
}

func isTruthy(val string) bool {
	lower := strings.ToLower(strings.TrimSpace(val))
	return lower == "true" || lower == "1" || lower == "yes" || lower == "t" || lower == "on"
}
