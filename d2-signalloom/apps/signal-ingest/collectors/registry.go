package collectors

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
)

// Registry manages the lifecycle, startup ordering, and health checks of registered collectors.
type Registry struct {
	mu         sync.RWMutex
	collectors []Collector
	started    []Collector
	startErrs  map[string]error
}

// NewRegistry instantiates a collector registry with the given collectors.
func NewRegistry(collectors ...Collector) *Registry {
	return &Registry{
		collectors: collectors,
		startErrs:  make(map[string]error),
	}
}

// Register adds a collector to the registry.
func (r *Registry) Register(c Collector) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.collectors = append(r.collectors, c)
}

// Collectors returns a copy of all registered collectors.
func (r *Registry) Collectors() []Collector {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Collector, len(r.collectors))
	copy(out, r.collectors)
	return out
}

// GetCollector finds a registered collector by its name.
func (r *Registry) GetCollector(name string) Collector {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, c := range r.collectors {
		if c.Name() == name {
			return c
		}
	}
	return nil
}

// Start starts each registered collector that is not in ModeOff.
// Emits structured log line: slog.Info("collector started", "name", ..., "mode", ...)
func (r *Registry) Start(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, c := range r.collectors {
		mode := c.Mode()
		if mode == ModeOff {
			continue
		}

		slog.Info("collector started", "name", c.Name(), "mode", string(mode))
		if err := c.Start(ctx); err != nil {
			slog.Error("collector start failed", "name", c.Name(), "mode", string(mode), "error", err)
			r.startErrs[c.Name()] = err
			return fmt.Errorf("collector %s start failed: %w", c.Name(), err)
		}
		r.started = append(r.started, c)
	}
	return nil
}

// Stop terminates all started collectors.
func (r *Registry) Stop() {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, c := range r.started {
		if s, ok := c.(Stopper); ok {
			s.Stop()
		}
	}
	r.started = nil
}

// Health verifies that all live-mode collectors are healthy and none failed at startup.
func (r *Registry) Health(ctx context.Context) error {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for name, err := range r.startErrs {
		return fmt.Errorf("collector %s failed to start: %w", name, err)
	}

	for _, c := range r.collectors {
		if c.Mode() == ModeLive {
			if hc, ok := c.(HealthChecker); ok {
				if err := hc.Health(ctx); err != nil {
					return fmt.Errorf("collector %s source unhealthy: %w", c.Name(), err)
				}
			}
		}
	}
	return nil
}

// NewRegistryFromEnv creates a registry with all six standard collector packages registered,
// configured from environment variables, defaulting to ModeOff when variables are unset.
func NewRegistryFromEnv(sink IngestionSink) *Registry {
	return NewRegistryFromEnvWithReceiver(sink, nil)
}

// NewRegistryFromEnvWithReceiver creates a registry with all six standard collector packages registered,
// reusing an existing audit.WebhookReceiver for the k8saudit collector.
func NewRegistryFromEnvWithReceiver(sink IngestionSink, rcv *audit.WebhookReceiver) *Registry {
	reg := NewRegistry()

	reg.Register(NewGCPAuditCollector(resolveEnvMode("COLLECTOR_GCPAUDIT_MODE", "SIGNAL_COLLECTOR_GCPAUDIT", "GCPAUDIT_MODE"), sink))
	reg.Register(NewBaoAuditCollector(resolveEnvMode("COLLECTOR_BAOAUDIT_MODE", "SIGNAL_COLLECTOR_BAOAUDIT", "BAOAUDIT_MODE"), sink))
	reg.Register(NewSPIREACollector(resolveEnvMode("COLLECTOR_SPIREA_MODE", "SIGNAL_COLLECTOR_SPIREA", "SPIREA_MODE"), sink))
	reg.Register(NewNetEBPFCollector(resolveEnvMode("COLLECTOR_NETEBPF_MODE", "SIGNAL_COLLECTOR_NETEBPF", "NETEBPF_MODE"), sink))
	if rcv != nil {
		reg.Register(NewK8sAuditCollectorWithReceiver(resolveEnvMode("COLLECTOR_K8SAUDIT_MODE", "SIGNAL_COLLECTOR_K8SAUDIT", "K8SAUDIT_MODE"), sink, rcv))
	} else {
		reg.Register(NewK8sAuditCollector(resolveEnvMode("COLLECTOR_K8SAUDIT_MODE", "SIGNAL_COLLECTOR_K8SAUDIT", "K8SAUDIT_MODE"), sink))
	}
	reg.Register(NewKAgentCollector(resolveEnvMode("COLLECTOR_KAGENT_MODE", "SIGNAL_COLLECTOR_KAGENT", "KAGENT_MODE"), sink))
	reg.Register(NewWorkspaceSaaSCollector(resolveEnvMode("COLLECTOR_WORKSPACESAAS_MODE", "SIGNAL_COLLECTOR_WORKSPACESAAS", "WORKSPACESAAS_MODE"), sink))
	reg.Register(NewFixtureCollector(resolveEnvMode("COLLECTOR_FIXTURES_MODE", "SIGNAL_COLLECTOR_FIXTURES", "FIXTURES_MODE"), sink))

	return reg
}

// ResolveEnvMode checks the provided environment variable keys and parses the first non-empty value into a Mode.
// Defaults to ModeOff if none of the keys are set.
func ResolveEnvMode(keys ...string) Mode {
	for _, k := range keys {
		if val := os.Getenv(k); val != "" {
			return ParseMode(val)
		}
	}
	return ModeOff
}

func resolveEnvMode(keys ...string) Mode {
	return ResolveEnvMode(keys...)
}

