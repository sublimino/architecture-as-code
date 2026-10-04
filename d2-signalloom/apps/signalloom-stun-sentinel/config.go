package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
)

// Config encapsulates runtime configuration options for the STUN sentinel.
type Config struct {
	DryRun         bool   `json:"dry_run"`
	HealthAddr     string `json:"health_addr"`
	CgroupRoot     string `json:"cgroup_root"`
	WatchNamespace string `json:"watch_namespace"`
	FreezeToken    string `json:"freeze_token,omitempty"`
	ResumeToken    string `json:"resume_token,omitempty"`
	// TenantMap is the operator's workload->tenant attribution
	// (correlator.ParseTenantMap syntax). Never derived from pod labels.
	TenantMap string `json:"tenant_map,omitempty"`
	// IngestToken is the signal-ingest bearer. Environment only
	// (SIGNAL_INGEST_TOKEN, from a Secret): a flag would put it in argv,
	// readable from /proc/<pid>/cmdline. Never serialised.
	IngestToken string `json:"-"`

	// On-node spool and batch dispatch options (SLTM Phase 2)
	SpoolDir      string        `json:"spool_dir"`
	SpoolMaxBytes int64         `json:"spool_max_bytes"`
	SpoolMaxAge   time.Duration `json:"spool_max_age"`
	BatchMax      int           `json:"batch_max"`
	BatchLinger   time.Duration `json:"batch_linger"`

	// Remote-cluster contract (docs/EAP/remote-contract.md). ClusterID names
	// this cluster in every fleet-manager report and poll; NodeName scopes
	// the report to this node's pods and signs every ack.
	ClusterID           string        `json:"cluster_id,omitempty"`
	NodeName            string        `json:"node_name,omitempty"`
	FleetReportInterval time.Duration `json:"fleet_report_interval"`
	FleetPollInterval   time.Duration `json:"fleet_poll_interval"`
}

// Remote-contract defaults.
const (
	DefaultFleetReportInterval = 60 * time.Second
	DefaultFleetPollInterval   = 10 * time.Second
)

// parseConfig parses command-line flags and environment variables with the following precedence:
// 1. Explicit command-line flags (--dry-run, --health-addr, etc.)
// 2. Environment variables (STUN_DRY_RUN, HEALTH_ADDR, etc.)
// 3. Built-in default values
func parseConfig(args []string) (*Config, error) {
	fs := flag.NewFlagSet("signalloom-stun-sentinel", flag.ContinueOnError)

	dryRunFlag := fs.Bool("dry-run", false, "Enable positive dry-run mode (log containment decisions without mutating kernel state)")
	healthAddrFlag := fs.String("health-addr", "", "Address for the HTTP health/readiness server (default: :8081)")
	cgroupRootFlag := fs.String("cgroup-root", "", "Path to cgroup v2 root hierarchy")
	watchNamespaceFlag := fs.String("watch-namespace", "", "Kubernetes namespace to watch for agent pods")
	freezeTokenFlag := fs.String("freeze-token", "", "Governance freeze token")
	resumeTokenFlag := fs.String("resume-token", "", "Governance resume token")
	tenantMapFlag := fs.String("tenant-map", "", "Workload tenant attribution: comma-separated namespace[/serviceAccount]=tenant")

	spoolDirFlag := fs.String("spool-dir", "", "Path to bounded on-node spool directory (default: /var/lib/signalloom/spool)")
	spoolMaxBytesFlag := fs.Int64("spool-max-bytes", 0, "Maximum spool byte capacity (default: 268435456)")
	spoolMaxAgeFlag := fs.String("spool-max-age", "", "Maximum age for spooled batches before expiration (default: 8h)")
	batchMaxFlag := fs.Int("batch-max", 0, "Maximum observations per dispatch batch (default: 100)")
	batchLingerFlag := fs.String("batch-linger", "", "Maximum linger time before flushing batch (default: 250ms)")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

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

	if *freezeTokenFlag != "" {
		cfg.FreezeToken = *freezeTokenFlag
	} else {
		cfg.FreezeToken = os.Getenv("STUN_FREEZE_TOKEN")
	}

	if *resumeTokenFlag != "" {
		cfg.ResumeToken = *resumeTokenFlag
	} else {
		cfg.ResumeToken = os.Getenv("STUN_RESUME_TOKEN")
	}

	if *tenantMapFlag != "" {
		cfg.TenantMap = *tenantMapFlag
	} else {
		cfg.TenantMap = os.Getenv("SENTINEL_TENANT_MAP")
	}

	cfg.IngestToken = strings.TrimSpace(os.Getenv("SIGNAL_INGEST_TOKEN"))

	// Spool directory: --spool-dir flag -> SIGNAL_INGEST_SPOOL_DIR env -> default /var/lib/signalloom/spool
	if *spoolDirFlag != "" {
		cfg.SpoolDir = *spoolDirFlag
	} else if val := os.Getenv("SIGNAL_INGEST_SPOOL_DIR"); val != "" {
		cfg.SpoolDir = val
	} else {
		cfg.SpoolDir = correlator.DefaultSpoolDir
	}

	// Spool max bytes: --spool-max-bytes flag -> SIGNAL_INGEST_SPOOL_MAX_BYTES env -> default 268435456
	cfg.SpoolMaxBytes = correlator.DefaultSpoolMaxBytes
	if *spoolMaxBytesFlag != 0 {
		if *spoolMaxBytesFlag <= 0 {
			return nil, fmt.Errorf("spool-max-bytes: invalid value %d (must be positive)", *spoolMaxBytesFlag)
		}
		cfg.SpoolMaxBytes = *spoolMaxBytesFlag
	} else if val := os.Getenv("SIGNAL_INGEST_SPOOL_MAX_BYTES"); val != "" {
		parsed, err := strconv.ParseInt(val, 10, 64)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("SIGNAL_INGEST_SPOOL_MAX_BYTES: invalid value %q (must be a positive integer)", val)
		}
		cfg.SpoolMaxBytes = parsed
	}

	// Spool max age: --spool-max-age flag -> SIGNAL_INGEST_SPOOL_MAX_AGE env -> default 8h
	cfg.SpoolMaxAge = correlator.DefaultSpoolMaxAge
	if *spoolMaxAgeFlag != "" {
		parsed, err := time.ParseDuration(*spoolMaxAgeFlag)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("spool-max-age: invalid duration %q: %v", *spoolMaxAgeFlag, err)
		}
		cfg.SpoolMaxAge = parsed
	} else if val := os.Getenv("SIGNAL_INGEST_SPOOL_MAX_AGE"); val != "" {
		parsed, err := time.ParseDuration(val)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("SIGNAL_INGEST_SPOOL_MAX_AGE: invalid duration %q: %v", val, err)
		}
		cfg.SpoolMaxAge = parsed
	}

	// Batch max: --batch-max flag -> SIGNAL_INGEST_BATCH_MAX env -> default 100
	cfg.BatchMax = correlator.DefaultBatchMax
	if *batchMaxFlag != 0 {
		if *batchMaxFlag <= 0 {
			return nil, fmt.Errorf("batch-max: invalid value %d (must be positive)", *batchMaxFlag)
		}
		cfg.BatchMax = *batchMaxFlag
	} else if val := os.Getenv("SIGNAL_INGEST_BATCH_MAX"); val != "" {
		parsed, err := strconv.Atoi(val)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("SIGNAL_INGEST_BATCH_MAX: invalid value %q (must be a positive integer)", val)
		}
		cfg.BatchMax = parsed
	}

	// Batch linger: --batch-linger flag -> SIGNAL_INGEST_BATCH_LINGER env -> default 250ms
	cfg.BatchLinger = correlator.DefaultBatchLinger
	if *batchLingerFlag != "" {
		parsed, err := time.ParseDuration(*batchLingerFlag)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("batch-linger: invalid duration %q: %v", *batchLingerFlag, err)
		}
		cfg.BatchLinger = parsed
	} else if val := os.Getenv("SIGNAL_INGEST_BATCH_LINGER"); val != "" {
		parsed, err := time.ParseDuration(val)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("SIGNAL_INGEST_BATCH_LINGER: invalid duration %q: %v", val, err)
		}
		cfg.BatchLinger = parsed
	}

	cfg.ClusterID = strings.TrimSpace(os.Getenv("SIGNAL_CLUSTER_ID"))
	cfg.NodeName = strings.TrimSpace(os.Getenv("NODE_NAME"))

	cfg.FleetReportInterval = DefaultFleetReportInterval
	if val := os.Getenv("FLEET_REPORT_INTERVAL"); val != "" {
		parsed, err := time.ParseDuration(val)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("FLEET_REPORT_INTERVAL: invalid duration %q: %v", val, err)
		}
		cfg.FleetReportInterval = parsed
	}

	cfg.FleetPollInterval = DefaultFleetPollInterval
	if val := os.Getenv("FLEET_POLL_INTERVAL"); val != "" {
		parsed, err := time.ParseDuration(val)
		if err != nil || parsed <= 0 {
			return nil, fmt.Errorf("FLEET_POLL_INTERVAL: invalid duration %q: %v", val, err)
		}
		cfg.FleetPollInterval = parsed
	}

	return cfg, nil
}

func isTruthy(val string) bool {
	lower := strings.ToLower(strings.TrimSpace(val))
	return lower == "true" || lower == "1" || lower == "yes" || lower == "t" || lower == "on"
}
