// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package baoaudit

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// IngestionSink receives transformed observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// AuditReceiver manages the decoupled, non-blocking ingestion of OpenBao audit device streams.
type AuditReceiver struct {
	ringBuffer     *AuditRingBuffer
	sink           IngestionSink
	eventsReceived uint64
	eventsIngested uint64
	parseErrors    uint64
	ctx            context.Context
	cancel         context.CancelFunc
	wg             sync.WaitGroup
	running        uint32
}

// NewAuditReceiver instantiates an OpenBao audit stream receiver with a dedicated ring buffer.
func NewAuditReceiver(capacity int, sink IngestionSink) *AuditReceiver {
	ctx, cancel := context.WithCancel(context.Background())
	return &AuditReceiver{
		ringBuffer: NewAuditRingBuffer(capacity),
		sink:       sink,
		ctx:        ctx,
		cancel:     cancel,
	}
}

// Start begins the asynchronous processing worker loop.
func (ar *AuditReceiver) Start() {
	if !atomic.CompareAndSwapUint32(&ar.running, 0, 1) {
		return
	}

	ar.wg.Add(1)
	go ar.workerLoop(ar.ctx)
}

// Stop gracefully shuts down the receiver and worker goroutines.
func (ar *AuditReceiver) Stop() {
	if atomic.CompareAndSwapUint32(&ar.running, 1, 0) {
		if ar.cancel != nil {
			ar.cancel()
		}
		ar.ringBuffer.Close()
		ar.wg.Wait()
	}
}

// IngestRawBytes parses a raw JSON audit line and deposits it into the non-blocking ring buffer.
func (ar *AuditReceiver) IngestRawBytes(data []byte) error {
	if len(data) == 0 {
		return nil
	}

	atomic.AddUint64(&ar.eventsReceived, 1)

	var event OpenBaoAuditEvent
	if err := json.Unmarshal(data, &event); err != nil {
		atomic.AddUint64(&ar.parseErrors, 1)
		return fmt.Errorf("failed to decode openbao audit event: %w", err)
	}

	if !ar.ringBuffer.Push(&event) {
		// Event dropped due to buffer saturation (drop-tail guarantee)
		return nil
	}

	return nil
}

// ListenUnixgram binds a non-blocking Unix datagram socket and receives audit events.
func (ar *AuditReceiver) ListenUnixgram(sockPath string) error {
	_ = os.Remove(sockPath)

	addr, err := net.ResolveUnixAddr("unixgram", sockPath)
	if err != nil {
		return fmt.Errorf("resolve unixgram addr: %w", err)
	}

	conn, err := net.ListenUnixgram("unixgram", addr)
	if err != nil {
		return fmt.Errorf("listen unixgram: %w", err)
	}

	// Set socket buffer sizes to 4MB
	_ = conn.SetReadBuffer(4 * 1024 * 1024)

	// Close conn on context cancellation to unblock ReadFrom immediately
	go func() {
		<-ar.ctx.Done()
		_ = conn.Close()
	}()

	ar.wg.Add(1)
	go func() {
		defer ar.wg.Done()
		defer os.Remove(sockPath)

		buf := make([]byte, 65536)
		for {
			select {
			case <-ar.ctx.Done():
				return
			default:
				n, _, err := conn.ReadFrom(buf)
				if err != nil {
					return
				}
				_ = ar.IngestRawBytes(buf[:n])
			}
		}
	}()

	return nil
}

// TapTmpfsFile continuously reads lines from a tmpfs audit log file (e.g. /dev/shm/openbao-audit.log).
func (ar *AuditReceiver) TapTmpfsFile(filePath string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("open tmpfs tap: %w", err)
	}

	go func() {
		<-ar.ctx.Done()
		_ = file.Close()
	}()

	ar.wg.Add(1)
	go func() {
		defer ar.wg.Done()

		reader := bufio.NewReader(file)
		for {
			select {
			case <-ar.ctx.Done():
				return
			default:
				line, err := reader.ReadBytes('\n')
				if err != nil {
					if err == io.EOF {
						time.Sleep(20 * time.Millisecond)
						continue
					}
					return
				}
				_ = ar.IngestRawBytes(line)
			}
		}
	}()

	return nil
}

// workerLoop drains the ring buffer and forwards observations to the ingestion sink.
func (ar *AuditReceiver) workerLoop(ctx context.Context) {
	defer ar.wg.Done()

	for {
		event, ok := ar.ringBuffer.Pop()
		if !ok {
			return
		}

		if ar.sink != nil && event != nil {
			obs := ar.convertToObservation(event)
			if obs != nil {
				_ = ar.sink.IngestObservation(ctx, obs)
				atomic.AddUint64(&ar.eventsIngested, 1)
			}
		}
	}
}

// convertToObservation transforms an OpenBao audit event into a standardized model.Observation.
func (ar *AuditReceiver) convertToObservation(event *OpenBaoAuditEvent) *model.Observation {
	t := time.Now().UTC()
	if event.Time != "" {
		if parsed, err := time.Parse(time.RFC3339Nano, event.Time); err == nil {
			t = parsed
		} else if parsed, err := time.Parse(time.RFC3339, event.Time); err == nil {
			t = parsed
		}
	}

	labels := map[string]string{
		"event_type": event.Type,
	}

	operation := "unknown"
	path := ""
	if event.Request != nil {
		operation = event.Request.Operation
		path = event.Request.Path
		labels["operation"] = operation
		labels["path"] = path
		if event.Request.ClientTokenAccessor != "" {
			labels["accessor"] = event.Request.ClientTokenAccessor
		}
	}

	spiffeID := ""
	role := ""
	saName := ""
	saNamespace := ""
	saPrincipal := ""

	if event.Auth != nil {
		if event.Auth.Metadata != nil {
			if s, ok := event.Auth.Metadata["spiffe_id"]; ok {
				spiffeID = s
				labels["spiffe_id"] = spiffeID
			}
			if r, ok := event.Auth.Metadata["role"]; ok {
				role = r
				labels["role"] = role
			}
			if sa, ok := event.Auth.Metadata["service_account_name"]; ok {
				saName = sa
			} else if sa, ok := event.Auth.Metadata["sa"]; ok {
				saName = sa
			}
			if ns, ok := event.Auth.Metadata["service_account_namespace"]; ok {
				saNamespace = ns
			} else if ns, ok := event.Auth.Metadata["namespace"]; ok {
				saNamespace = ns
			}
			if sap, ok := event.Auth.Metadata["sa_principal"]; ok {
				saPrincipal = sap
			}
		}
		if event.Auth.DisplayName != "" {
			labels["display_name"] = event.Auth.DisplayName
			if saPrincipal == "" && strings.HasPrefix(event.Auth.DisplayName, "system:serviceaccount:") {
				saPrincipal = event.Auth.DisplayName
			}
		}
		if event.Auth.Accessor != "" {
			labels["auth_accessor"] = event.Auth.Accessor
		}
	}

	// Derive SA <-> SPIFFE correspondence if not explicitly provided
	if spiffeID != "" && (saNamespace == "" || saName == "") {
		ns, sa := parseSPIFFE(spiffeID)
		if saNamespace == "" {
			saNamespace = ns
		}
		if saName == "" {
			saName = sa
		}
	}
	if saPrincipal == "" && saNamespace != "" && saName != "" {
		saPrincipal = fmt.Sprintf("system:serviceaccount:%s:%s", saNamespace, saName)
	}
	if saPrincipal != "" && spiffeID == "" {
		if ns, sa, ok := parseSAPrincipal(saPrincipal); ok {
			spiffeID = fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", ns, sa)
			labels["spiffe_id"] = spiffeID
		}
	}

	if saPrincipal != "" {
		labels["sa_principal"] = saPrincipal
	}
	if saNamespace != "" {
		labels["namespace"] = saNamespace
	}
	if saName != "" {
		labels["service_account"] = saName
	}

	if event.Response != nil && event.Response.Secret != nil {
		if event.Response.Secret.LeaseID != "" {
			labels["lease_id"] = event.Response.Secret.LeaseID
			labels["lease_duration"] = fmt.Sprintf("%d", event.Response.Secret.LeaseDuration)
		}
	}

	if event.Error != "" {
		labels["error"] = event.Error
	}

	actorHint := spiffeID
	if actorHint == "" && saPrincipal != "" {
		actorHint = saPrincipal
	}
	if actorHint == "" && role != "" {
		actorHint = "role:" + role
	}
	if actorHint == "" && labels["accessor"] != "" {
		actorHint = "accessor:" + labels["accessor"]
	}

	return &model.Observation{
		ID:             fmt.Sprintf("bao-%d-%s", t.UnixNano(), operation),
		Timestamp:      t,
		Layer:          model.LayerIdentityAuth,
		Fidelity:       model.FidelityDefinitive,
		Source:         "openbao-audit",
		Confidence:     0.95,
		ActorHint:      actorHint,
		PrincipalID:    saPrincipal,
		RawEvidenceRef: fmt.Sprintf("openbao://audit/%s", operation),
		Labels:         labels,
		Description:    fmt.Sprintf("OpenBao %s on %s (spiffe=%s, sa=%s)", operation, path, spiffeID, saPrincipal),
	}
}

// Stats returns the operational metrics of the receiver.
func (ar *AuditReceiver) Stats() (received, ingested, dropped, errors uint64) {
	return atomic.LoadUint64(&ar.eventsReceived),
		atomic.LoadUint64(&ar.eventsIngested),
		ar.ringBuffer.DropsTotal(),
		atomic.LoadUint64(&ar.parseErrors)
}

// DropsTotal returns the cumulative count of dropped events due to ring buffer saturation.
func (ar *AuditReceiver) DropsTotal() uint64 {
	return ar.ringBuffer.DropsTotal()
}

// Metrics returns operational metrics as a key-value map.
func (ar *AuditReceiver) Metrics() map[string]uint64 {
	rec, ing, drp, errs := ar.Stats()
	return map[string]uint64{
		"received":     rec,
		"ingested":     ing,
		"dropped":      drp,
		"parse_errors": errs,
	}
}

func parseSPIFFE(id string) (namespace, serviceAccount string) {
	if !strings.HasPrefix(id, "spiffe://") {
		return "", ""
	}
	parts := strings.Split(strings.TrimPrefix(id, "spiffe://"), "/")
	for i, p := range parts {
		if p == "ns" && i+1 < len(parts) {
			namespace = parts[i+1]
		}
		if p == "sa" && i+1 < len(parts) {
			serviceAccount = parts[i+1]
		}
	}
	return namespace, serviceAccount
}

func parseSAPrincipal(principal string) (namespace, serviceAccount string, ok bool) {
	if !strings.HasPrefix(principal, "system:serviceaccount:") {
		return "", "", false
	}
	raw := strings.TrimPrefix(principal, "system:serviceaccount:")
	parts := strings.Split(raw, ":")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

