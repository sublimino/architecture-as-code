// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Mode is the collector's operational mode. It mirrors collectors.Mode as a local
// string type so this package does not import collectors — which is what allows
// collectors to register it without an import cycle, exactly as gcpaudit does.
type Mode string

const (
	ModeOff     Mode = "off"
	ModeFixture Mode = "fixture"
	ModeLive    Mode = "live"
)

// Default tuning. Each is deliberately modest: the buffer is a transport smoother,
// not a store, and §2.1 is explicit that it guarantees nothing past the sink.
const (
	DefaultTenantID     = "kusari"
	DefaultRegion       = "us-east-1"
	DefaultBufferDir    = "/var/lib/signalloom/awslogs"
	DefaultMaxRecords   = 10
	DefaultPollInterval = 10 * time.Second
)

// Environment variable names. The mode gate itself is resolved by the registry via
// resolveEnvMode("COLLECTOR_AWSLOGS_MODE", "SIGNAL_COLLECTOR_AWSLOGS", "AWSLOGS_MODE").
const (
	EnvTenantID     = "AWSLOGS_TENANT_ID"
	EnvRoleARN      = "AWSLOGS_ROLE_ARN"
	EnvExternalID   = "AWSLOGS_EXTERNAL_ID"
	EnvQueueURL     = "AWSLOGS_QUEUE_URL"
	EnvRegion       = "AWSLOGS_REGION"
	EnvBufferDir    = "AWSLOGS_BUFFER_DIR"
	EnvMaxRecords   = "AWSLOGS_MAX_RECORDS"
	EnvRingCapacity = "AWSLOGS_RING_CAPACITY"
)

// AWSCollectorConfig is one customer account's worth of configuration.
//
// There is one collector instance per account (SLAWS D7), and TenantID comes from
// here rather than from a record: a collector bound to an account cannot be talked
// into attributing its telemetry to another tenant by a crafted payload, because the
// payload is never consulted for tenancy.
type AWSCollectorConfig struct {
	AccountID  string `json:"account_id,omitempty"`
	TenantID   string `json:"tenant_id"`
	RoleARN    string `json:"role_arn"`
	ExternalID string `json:"external_id"`
	QueueURL   string `json:"queue_url"`
	Region     string `json:"region"`

	BufferDir  string `json:"buffer_dir"`
	MaxRecords int    `json:"max_records"`

	PollInterval          time.Duration `json:"poll_interval"`
	RingCapacity          int           `json:"ring_capacity"`
	CompactThresholdBytes int64         `json:"compact_threshold_bytes"`
}

// WithDefaults returns cfg with unset fields filled in. Tenant defaults to
// DefaultTenantID so fixture mode needs no configuration at all; nothing that would
// reach a customer account is ever defaulted.
func (c AWSCollectorConfig) WithDefaults() AWSCollectorConfig {
	if c.TenantID == "" {
		c.TenantID = DefaultTenantID
	}
	if c.Region == "" {
		c.Region = DefaultRegion
	}
	if c.BufferDir == "" {
		c.BufferDir = DefaultBufferDir
	}
	if c.MaxRecords <= 0 {
		c.MaxRecords = DefaultMaxRecords
	}
	if c.PollInterval <= 0 {
		c.PollInterval = DefaultPollInterval
	}
	if c.RingCapacity <= 0 {
		c.RingCapacity = DefaultDiskRingCapacity
	}
	if c.CompactThresholdBytes <= 0 {
		c.CompactThresholdBytes = DefaultCompactThresholdBytes
	}
	return c
}

// ErrMissingExternalID is returned when live mode is configured with a role but no
// external ID.
var ErrMissingExternalID = errors.New("awslogs: AWSLOGS_EXTERNAL_ID is required in live mode")

// Validate checks the configuration for the given mode.
//
// Off and fixture mode need only a tenant, because neither touches AWS. Live mode
// needs the full set, and the external ID is checked explicitly rather than left to
// fail at the first AssumeRole: a collector that boots and then cannot authenticate
// looks like an AWS outage, while one that refuses to boot names the actual problem.
func (c AWSCollectorConfig) Validate(mode Mode) error {
	if c.TenantID == "" {
		return errors.New("awslogs: tenant_id is required")
	}
	if mode != ModeLive {
		return nil
	}

	var missing []string
	if c.RoleARN == "" {
		missing = append(missing, EnvRoleARN)
	}
	if c.QueueURL == "" {
		missing = append(missing, EnvQueueURL)
	}
	if c.Region == "" {
		missing = append(missing, EnvRegion)
	}
	if len(missing) > 0 {
		return fmt.Errorf("awslogs: live mode is missing required configuration: %s", strings.Join(missing, ", "))
	}
	if c.ExternalID == "" {
		return ErrMissingExternalID
	}
	return nil
}

// ConfigFromEnv reads one account's configuration from the environment.
//
// A deployment serving several accounts constructs one config and one collector
// instance per account rather than overloading these variables; the registry wires
// the single env-configured account, which is what the EAP needs.
func ConfigFromEnv() AWSCollectorConfig {
	cfg := AWSCollectorConfig{
		TenantID:   os.Getenv(EnvTenantID),
		RoleARN:    os.Getenv(EnvRoleARN),
		ExternalID: os.Getenv(EnvExternalID),
		QueueURL:   os.Getenv(EnvQueueURL),
		Region:     os.Getenv(EnvRegion),
		BufferDir:  os.Getenv(EnvBufferDir),
	}
	if v := os.Getenv(EnvMaxRecords); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cfg.MaxRecords = n
		}
	}
	if v := os.Getenv(EnvRingCapacity); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			cfg.RingCapacity = n
		}
	}
	return cfg.WithDefaults()
}
