// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/k8saudit"
)

// K8sAuditKubeCollector adapts the collectors/k8saudit THREAT vertical to the
// Collector interface. It is the registry-visible half of the reference vertical
// and, like the awslogs adapter, the layer that applies the tenant binder —
// k8saudit declares its own narrow Sink and does not import this package (so this
// package can register it with no import cycle), so BindTenant is applied here
// where both sides are in scope.
//
// It is DISTINCT from K8sAuditCollector in adapters.go: that one is the
// identity-auth projection (LayerIdentityAuth, Source "k8s-apiserver-audit",
// COLLECTOR_K8SAUDIT_MODE) for delegation tracking, left untouched. This one is
// the threat projection (LayerKubernetes, Source "k8saudit-kube",
// COLLECTOR_K8SAUDIT_KUBE_MODE). See collectors/k8saudit/contract_doc.go.
type K8sAuditKubeCollector struct {
	mode     Mode
	sink     IngestionSink
	tenantID string
	cfg      k8saudit.Config
	col      *k8saudit.Collector
	startFn  func(ctx context.Context) error
	healthFn func(ctx context.Context) error
}

// EnvK8sAuditKubeTenant is the tenant this collector binds its observations to.
// Tenancy is configuration, never read from an audit record (SLAWS D7).
const EnvK8sAuditKubeTenant = "K8SAUDIT_TENANT_ID"

// defaultK8sAuditKubeTenant is the Kusari pilot tenant, matching the bundle
// tenant_id in policy/bundles/kusari/k8s-audit.yaml.
const defaultK8sAuditKubeTenant = "kusari"

// NewK8sAuditKubeCollector builds the adapter, reading the live-source config
// and tenant from the environment.
func NewK8sAuditKubeCollector(mode Mode, sink IngestionSink) *K8sAuditKubeCollector {
	tenant := os.Getenv(EnvK8sAuditKubeTenant)
	if tenant == "" {
		tenant = defaultK8sAuditKubeTenant
	}
	return &K8sAuditKubeCollector{
		mode:     mode,
		sink:     sink,
		tenantID: tenant,
		cfg:      k8saudit.ConfigFromEnv(),
	}
}

func (c *K8sAuditKubeCollector) Name() string { return "k8saudit-kube" }
func (c *K8sAuditKubeCollector) Mode() Mode   { return c.mode }

func (c *K8sAuditKubeCollector) SetStartFunc(fn func(ctx context.Context) error)  { c.startFn = fn }
func (c *K8sAuditKubeCollector) SetHealthFunc(fn func(ctx context.Context) error) { c.healthFn = fn }

// RawCollector exposes the underlying collector, nil until Start has built it.
func (c *K8sAuditKubeCollector) RawCollector() *k8saudit.Collector { return c.col }

func (c *K8sAuditKubeCollector) boundSink() k8saudit.Sink {
	if c.sink == nil {
		return nil
	}
	return BindTenant(c.sink, c.tenantID)
}

// mapMode translates the registry Mode into the package's own Mode. An off
// registry mode is an off collector; anything the package does not recognise it
// treats as off, never live.
func mapK8sAuditKubeMode(m Mode) k8saudit.Mode {
	switch m {
	case ModeLive:
		return k8saudit.ModeLive
	case ModeFixture:
		return k8saudit.ModeFixture
	default:
		return k8saudit.ModeOff
	}
}

func (c *K8sAuditKubeCollector) Start(ctx context.Context) error {
	if c.startFn != nil {
		return c.startFn(ctx)
	}
	if c.mode == ModeOff {
		return nil
	}
	if c.col == nil {
		c.col = k8saudit.New(mapK8sAuditKubeMode(c.mode), c.cfg, c.boundSink())
	}
	return c.col.Start(ctx)
}

func (c *K8sAuditKubeCollector) Health(ctx context.Context) error {
	if c.healthFn != nil {
		return c.healthFn(ctx)
	}
	if c.col != nil {
		return c.col.Health(ctx)
	}
	return nil
}

func (c *K8sAuditKubeCollector) Stop() {
	if c.col != nil {
		c.col.Stop()
	}
}
