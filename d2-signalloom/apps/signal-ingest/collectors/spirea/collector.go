// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package spirea

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// IngestionSink receives converted identity observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// SPIREIssuanceCollector manages SVID event streams and identity correlation.
type SPIREIssuanceCollector struct {
	tracker        *IdentityTracker
	sink           IngestionSink
	eventsReceived uint64
	eventsIngested uint64
	anomaliesFound uint64
	ctx            context.Context
	cancel         context.CancelFunc
	wg             sync.WaitGroup
	running        uint32
}

// NewSPIREIssuanceCollector instantiates a SPIRE SVID issuance collector.
func NewSPIREIssuanceCollector(sink IngestionSink) *SPIREIssuanceCollector {
	ctx, cancel := context.WithCancel(context.Background())
	return &SPIREIssuanceCollector{
		tracker: NewIdentityTracker(),
		sink:    sink,
		ctx:     ctx,
		cancel:  cancel,
	}
}

// Start initiates background maintenance and abandoned credential sweep routines.
func (sc *SPIREIssuanceCollector) Start() {
	if !atomic.CompareAndSwapUint32(&sc.running, 0, 1) {
		return
	}

	sc.wg.Add(1)
	go sc.monitoringLoop()
}

// Stop halts the collector goroutines.
func (sc *SPIREIssuanceCollector) Stop() {
	if atomic.CompareAndSwapUint32(&sc.running, 1, 0) {
		if sc.cancel != nil {
			sc.cancel()
		}
		sc.wg.Wait()
	}
}

// Tracker returns the underlying identity tracker.
func (sc *SPIREIssuanceCollector) Tracker() *IdentityTracker {
	return sc.tracker
}

// IngestIssuanceEvent processes an SVID issuance event, updates tracker, and emits an observation.
func (sc *SPIREIssuanceCollector) IngestIssuanceEvent(ctx context.Context, event *SVIDIssuanceEvent) error {
	if event == nil || event.SPIFFEID == "" {
		return nil
	}

	atomic.AddUint64(&sc.eventsReceived, 1)
	sc.tracker.RecordIssuance(event)

	if sc.sink != nil {
		obs := sc.convertToObservation(event)
		if obs != nil {
			_ = sc.sink.IngestObservation(ctx, obs)
			atomic.AddUint64(&sc.eventsIngested, 1)
		}
	}

	return nil
}

// convertToObservation converts an SVID issuance event into a model.Observation.
func (sc *SPIREIssuanceCollector) convertToObservation(event *SVIDIssuanceEvent) *model.Observation {
	t := event.Timestamp
	if t.IsZero() {
		t = time.Now().UTC()
	}

	ns := event.PodNamespace
	sa := event.ServiceAccount
	if ns == "" || sa == "" {
		ns, sa = parseSPIFFEID(event.SPIFFEID)
	}

	saPrincipal := ""
	if ns != "" && sa != "" {
		saPrincipal = FormatSAPrincipal(ns, sa)
	}

	labels := map[string]string{
		"event_type":   "spire_svid_issuance",
		"spiffe_id":    event.SPIFFEID,
		"trust_domain": event.TrustDomain,
		"svid_type":    string(event.SVIDType),
		"ttl_seconds":  fmt.Sprintf("%d", event.TTLSeconds),
	}

	if event.PodName != "" {
		labels["pod_name"] = event.PodName
	}
	if ns != "" {
		labels["namespace"] = ns
	}
	if sa != "" {
		labels["service_account"] = sa
	}
	if saPrincipal != "" {
		labels["sa_principal"] = saPrincipal
	}
	if event.NodeName != "" {
		labels["node_name"] = event.NodeName
	}
	if event.SerialNumber != "" {
		labels["serial_number"] = event.SerialNumber
	}
	if event.JWTID != "" {
		labels["jwt_id"] = event.JWTID
	}

	actorHint := event.SPIFFEID
	if actorHint == "" && saPrincipal != "" {
		actorHint = saPrincipal
	}

	return &model.Observation{
		ID:             fmt.Sprintf("spire-%d-%s", t.UnixNano(), event.SVIDType),
		Timestamp:      t,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityStrong,
		Source:         "spire-agent",
		Confidence:     0.85,
		ActorHint:      actorHint,
		PrincipalID:    saPrincipal,
		RawEvidenceRef: fmt.Sprintf("spire://svid/%s", event.SPIFFEID),
		Labels:         labels,
		Description:    fmt.Sprintf("SPIRE issued %s SVID for %s (sa=%s, TTL=%ds)", event.SVIDType, event.SPIFFEID, saPrincipal, event.TTLSeconds),
	}
}

// monitoringLoop sweeps for abandoned credentials and expired leases periodically.
func (sc *SPIREIssuanceCollector) monitoringLoop() {
	defer sc.wg.Done()
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sc.ctx.Done():
			return
		case now := <-ticker.C:
			abandoned := sc.tracker.FindAbandonedCredentials(now)
			for _, lease := range abandoned {
				atomic.AddUint64(&sc.anomaliesFound, 1)
				if sc.sink != nil {
					obs := &model.Observation{
						ID:             fmt.Sprintf("spire-abandoned-%d", now.UnixNano()),
						Timestamp:      now,
						Layer:          model.LayerIdentityAuth,
						Fidelity:       model.FidelitySuggestive,
						Source:         "spire-tracker",
						Confidence:     0.75,
						ActorHint:      lease.SPIFFEID,
						RawEvidenceRef: fmt.Sprintf("spire://abandoned/%s", lease.SPIFFEID),
						Labels: map[string]string{
							"event_type":   "abandoned_credential_anomaly",
							"spiffe_id":    lease.SPIFFEID,
							"agent_role":   lease.AgentRole,
							"expired_at":   lease.ExpiresAt.Format(time.RFC3339),
							"active_leases": fmt.Sprintf("%d", len(lease.ActiveLeases)),
						},
						Description: fmt.Sprintf("Abandoned credential detected: %s expired with %d open leases", lease.SPIFFEID, len(lease.ActiveLeases)),
					}
					_ = sc.sink.IngestObservation(sc.ctx, obs)
				}
			}
			sc.tracker.EvictExpired(now, 1*time.Hour)
		}
	}
}

// Stats returns collector metrics.
func (sc *SPIREIssuanceCollector) Stats() (received, ingested, anomalies uint64) {
	return atomic.LoadUint64(&sc.eventsReceived),
		atomic.LoadUint64(&sc.eventsIngested),
		atomic.LoadUint64(&sc.anomaliesFound)
}
