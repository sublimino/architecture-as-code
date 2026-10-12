// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package k8saudit

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
)

// Source is the swappable input of the one projection. Every source yields the
// same AuditEvent wire type, so the Projector is written once and the only thing
// that changes between warden-local, fixture and a managed control plane is
// where the events come from — the awslogs live/fixture seam, applied to k8s.
//
// Drain returns the events currently available and acknowledges them by not
// returning them again; a file or fixture source reads its whole input once, a
// streaming source returns the batch drained so far. An empty slice with a nil
// error means "nothing to project", which is not an error.
type Source interface {
	Name() string
	Drain(ctx context.Context) ([]AuditEvent, error)
}

// ErrNoAuditLogPath is returned when the warden-local source is selected in live
// mode with no audit log path configured. It is a configuration defect, never a
// default: a warden-local collector with no file to tail would run as a source
// that silently collects nothing.
var ErrNoAuditLogPath = errors.New(
	"k8saudit: warden-local live mode needs an audit log path (K8SAUDIT_AUDIT_LOG_PATH / COLLECTOR_K8SAUDIT_KUBE_AUDIT_LOG)")

// ErrCloudLiveDeferred is returned when an EKS/GKE/AKS source is selected in
// live mode with no live cloud client factory registered. Live cloud ingestion
// is DEFERRED (no cloud credentials in this environment): the provider adapters
// and their fixture tests exist, but the aws-sdk / google-cloud / azure-sdk
// clients that would feed them are not wired, exactly as awslogs defers its live
// SDK behind SetLiveClientFactory.
var ErrCloudLiveDeferred = errors.New(
	"k8saudit: live cloud audit ingestion (EKS/GKE/AKS) is deferred — no live cloud client factory is registered (register one via SetLiveCloudClientFactory to enable it)")

// --- fixture source -------------------------------------------------------

// fixtureSource replays a fixed set of audit events, the whole of fixture mode.
type fixtureSource struct {
	events []AuditEvent
	once   sync.Once
}

func newFixtureSource(events []AuditEvent) *fixtureSource {
	return &fixtureSource{events: events}
}

func (s *fixtureSource) Name() string { return "fixture" }

// Drain returns the fixture events exactly once; a second Drain returns nothing,
// so a collector that polls does not re-ingest the fixtures every tick.
func (s *fixtureSource) Drain(_ context.Context) ([]AuditEvent, error) {
	var out []AuditEvent
	s.once.Do(func() { out = s.events })
	return out, nil
}

// --- warden-local file source --------------------------------------------

// wardenLocalFileSource reads the kube-apiserver audit log the on-node
// signalloom-warden tails (or the webhook payload it writes locally). This is
// the preferred local gatherer — the same on-node path nono evidence rides —
// and it is LIVE, not a fixture: it reads a real file off disk.
//
// The file is parsed as JSON-lines of audit Event first (the apiserver's
// --audit-log-path format), and as a single EventList if that yields nothing
// (the webhook payload format). A line that does not parse is skipped with the
// error surfaced, never silently dropped.
type wardenLocalFileSource struct {
	path string
	once sync.Once
}

func newWardenLocalFileSource(path string) *wardenLocalFileSource {
	return &wardenLocalFileSource{path: path}
}

func (s *wardenLocalFileSource) Name() string { return "warden-local" }

func (s *wardenLocalFileSource) Drain(_ context.Context) ([]AuditEvent, error) {
	var (
		out []AuditEvent
		err error
	)
	s.once.Do(func() {
		if s.path == "" {
			err = ErrNoAuditLogPath
			return
		}
		var body []byte
		body, err = os.ReadFile(s.path)
		if err != nil {
			err = fmt.Errorf("k8saudit: reading warden audit log %q: %w", s.path, err)
			return
		}
		out, err = ParseAuditBytes(body)
	})
	return out, err
}

// ParseAuditBytes decodes an audit payload that is either JSON-lines of Event or
// a single EventList. It is exported so the warden webhook path and tests share
// one decoder.
func ParseAuditBytes(body []byte) ([]AuditEvent, error) {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 {
		return nil, nil
	}

	// EventList form: a single JSON object with an items array.
	if trimmed[0] == '{' {
		var list EventList
		if err := json.Unmarshal(trimmed, &list); err == nil && (list.Kind == "EventList" || len(list.Items) > 0) {
			return list.Items, nil
		}
		// A single Event object (not a list).
		var one AuditEvent
		if err := json.Unmarshal(trimmed, &one); err == nil && (one.AuditID != "" || one.Stage != "") {
			return []AuditEvent{one}, nil
		}
	}

	// JSON-lines form: one Event per line.
	var out []AuditEvent
	scanner := bufio.NewScanner(bytes.NewReader(trimmed))
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		raw := bytes.TrimSpace(scanner.Bytes())
		if len(raw) == 0 {
			continue
		}
		var e AuditEvent
		if err := json.Unmarshal(raw, &e); err != nil {
			return nil, fmt.Errorf("k8saudit: audit log line %d is not a valid audit Event: %w", line, err)
		}
		out = append(out, e)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("k8saudit: scanning audit log: %w", err)
	}
	return out, nil
}

// --- cloud sources (EKS / GKE / AKS), live DEFERRED ----------------------

// CloudProvider names a managed control plane whose audit stream has no node to
// tail, so it is pulled from the provider's log service instead.
type CloudProvider string

const (
	ProviderEKS CloudProvider = "eks" // EKS -> CloudWatch Logs
	ProviderGKE CloudProvider = "gke" // GKE -> Cloud Logging
	ProviderAKS CloudProvider = "aks" // AKS -> Azure Monitor
)

// ValidCloudProvider reports whether p is a provider this vertical knows.
func ValidCloudProvider(p CloudProvider) bool {
	switch p {
	case ProviderEKS, ProviderGKE, ProviderAKS:
		return true
	default:
		return false
	}
}

// CloudAuditClient is the per-provider live seam. Its implementation is DEFERRED
// (no cloud credentials here); a provider adapter converts the provider-native
// record into the canonical AuditEvent, and this interface is what the deferred
// live client and the test fake both satisfy.
type CloudAuditClient interface {
	// FetchAuditEvents returns the audit events available since the last call.
	FetchAuditEvents(ctx context.Context) ([]AuditEvent, error)
}

// cloudSource drains a CloudAuditClient. It is provider-agnostic because the
// provider-specific projection is the client's job; this type only moves events.
type cloudSource struct {
	provider CloudProvider
	client   CloudAuditClient
}

func newCloudSource(provider CloudProvider, client CloudAuditClient) *cloudSource {
	return &cloudSource{provider: provider, client: client}
}

func (s *cloudSource) Name() string { return "cloud-" + string(s.provider) }

func (s *cloudSource) Drain(ctx context.Context) ([]AuditEvent, error) {
	if s.client == nil {
		return nil, ErrCloudLiveDeferred
	}
	events, err := s.client.FetchAuditEvents(ctx)
	if err != nil {
		return nil, fmt.Errorf("k8saudit: %s cloud client fetch failed: %w", s.provider, err)
	}
	return events, nil
}

// LiveCloudClientFactory builds a live CloudAuditClient for one provider and
// config. It is registered out-of-process (a future collectors/k8saudit/live
// subpackage) through SetLiveCloudClientFactory; until then live cloud mode
// returns ErrCloudLiveDeferred.
type LiveCloudClientFactory func(provider CloudProvider, cfg CloudConfig) (CloudAuditClient, error)

// CloudConfig is the live cloud source configuration, read from the environment.
// Every field is deferred's input; none is used by fixture or warden-local mode.
type CloudConfig struct {
	Provider CloudProvider
	// Location is the log group (EKS), project/cluster (GKE) or workspace (AKS).
	Location string
}

var (
	liveCloudMu      sync.RWMutex
	liveCloudFactory LiveCloudClientFactory
)

// SetLiveCloudClientFactory registers the factory that turns a CloudConfig into
// a live client. A nil factory clears the registration. This is the single seam
// a live cloud build wires; the core package never imports a cloud SDK, so
// fixture and the §label-contract tests build without one.
func SetLiveCloudClientFactory(f LiveCloudClientFactory) {
	liveCloudMu.Lock()
	defer liveCloudMu.Unlock()
	liveCloudFactory = f
}

func liveCloudClient(provider CloudProvider, cfg CloudConfig) (CloudAuditClient, error) {
	liveCloudMu.RLock()
	f := liveCloudFactory
	liveCloudMu.RUnlock()
	if f == nil {
		return nil, ErrCloudLiveDeferred
	}
	return f(provider, cfg)
}
