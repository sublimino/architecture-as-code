// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package agentnono

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// CollectorName is the canonical registration identifier.
const CollectorName = "agentnono"

// IngestionSink receives converted model observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// CollectorConfig holds tuning and operational parameters for agentnono collector.
type CollectorConfig struct {
	Capacity       int
	FilePath       string
	TrustDomain    string
	TrustBundlePEM []byte
	Logger         *slog.Logger
}

// Collector manages live log tailing, bounded ring buffering, cryptographic verification,
// and transformation of agent-nono-evidenced audit sessions into model observations.
type Collector struct {
	mode        string
	sink        IngestionSink
	cfg         CollectorConfig
	ringBuffer  *RingBuffer
	verifier    *AuditVerifier
	metrics     *Metrics
	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	running     uint32
	started     uint32
	healthErr   error
	mu          sync.RWMutex
}

// NewCollector constructs an agentnono collector.
func NewCollector(mode string, sink IngestionSink, cfg CollectorConfig) *Collector {
	if cfg.Capacity <= 0 {
		cfg.Capacity = 1000
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}

	verifierCfg := VerifierConfig{
		TrustDomain:    cfg.TrustDomain,
		TrustBundlePEM: cfg.TrustBundlePEM,
	}

	return &Collector{
		mode:       mode,
		sink:       sink,
		cfg:        cfg,
		ringBuffer: NewRingBuffer(cfg.Capacity),
		verifier:   NewAuditVerifier(verifierCfg),
		metrics:    NewMetrics(),
	}
}

// Name satisfies collectors.Collector.
func (c *Collector) Name() string {
	return CollectorName
}

// Mode returns the collector mode.
func (c *Collector) Mode() string {
	return c.mode
}

// Metrics returns the Prometheus counter collector.
func (c *Collector) Metrics() *Metrics {
	if c.metrics == nil {
		return NewMetrics()
	}
	return c.metrics
}

// Verifier returns the internal audit verifier.
func (c *Collector) Verifier() *AuditVerifier {
	return c.verifier
}

// RingBuffer returns the internal bounded ring buffer.
func (c *Collector) RingBuffer() *RingBuffer {
	return c.ringBuffer
}

// Start initiates worker loops and live file/stream ingestion.
func (c *Collector) Start(ctx context.Context) error {
	if !atomic.CompareAndSwapUint32(&c.started, 0, 1) {
		return nil
	}

	c.ctx, c.cancel = context.WithCancel(ctx)

	switch c.mode {
	case "off", "":
		return nil

	case "fixture":
		c.wg.Add(1)
		go func() {
			defer c.wg.Done()
			fixtures := AgentNonoFixtures(time.Now().UTC())
			for _, obs := range fixtures {
				o := obs
				if c.sink != nil {
					if err := c.sink.IngestObservation(c.ctx, &o); err == nil {
						c.metrics.IncSignalsIngested()
					} else {
						c.metrics.IncSignatureErrors()
					}
				}
			}
		}()
		return nil

	case "live":
		atomic.StoreUint32(&c.running, 1)
		c.wg.Add(1)
		go c.workerLoop(c.ctx)

		if c.cfg.FilePath != "" {
			c.wg.Add(1)
			go c.tailFileLoop(c.ctx, c.cfg.FilePath)
		}
		return nil
	}

	return nil
}

// Stop gracefully shuts down the collector.
func (c *Collector) Stop() {
	if atomic.CompareAndSwapUint32(&c.running, 1, 0) {
		if c.cancel != nil {
			c.cancel()
		}
		if c.ringBuffer != nil {
			c.ringBuffer.Close()
		}
		c.wg.Wait()
	}
}

// Health satisfies collectors.HealthChecker.
func (c *Collector) Health(ctx context.Context) error {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.healthErr
}

// IngestRawLine parses and deposits a single JSON line into the bounded ring buffer.
func (c *Collector) IngestRawLine(ctx context.Context, line []byte) error {
	line = []byte(strings.TrimSpace(string(line)))
	if len(line) == 0 {
		return nil
	}

	c.metrics.IncEventsReceived()

	var event NonoAuditEvent
	if err := json.Unmarshal(line, &event); err != nil {
		c.metrics.IncSignatureErrors()
		return fmt.Errorf("unmarshal nono audit event: %w", err)
	}

	return c.IngestEvent(ctx, &event)
}

// IngestEvent deposits a parsed audit event into the bounded ring buffer with drop-tail handling.
func (c *Collector) IngestEvent(ctx context.Context, event *NonoAuditEvent) error {
	if event == nil {
		return nil
	}

	if !c.ringBuffer.Push(event) {
		c.metrics.AddEventsDropped(1)
		return nil // Drop-tail guarantee under high volume bursts
	}

	return nil
}

// workerLoop drains events from the ring buffer, validates cryptographic signatures,
// and transforms them into model.Observation records for the sink.
func (c *Collector) workerLoop(ctx context.Context) {
	defer c.wg.Done()
	for {
		event, ok := c.ringBuffer.Pop()
		if !ok {
			return
		}

		c.processEvent(ctx, event)
	}
}

// processEvent performs verification and sink emission.
func (c *Collector) processEvent(ctx context.Context, event *NonoAuditEvent) {
	result := c.verifier.VerifyEvent(event)

	fidelity := model.FidelityDefinitive
	confidence := 1.0

	switch result.Status {
	case StatusVerified:
		fidelity = model.FidelityDefinitive
		confidence = 1.0
	case StatusTampered:
		fidelity = model.FidelityCircumstantial
		confidence = 0.0
		c.metrics.IncSignatureErrors()
		c.metrics.IncTamperedSignals()
		c.cfg.Logger.Warn("agent-nono audit event tampered or broken hash chain",
			"session_id", event.AuditSessionID,
			"seq", event.Seq,
			"spiffe_id", event.SPIFFEID,
			"error", result.Error)
	case StatusUnverified, StatusUnsigned:
		fidelity = model.FidelityCircumstantial
		confidence = 0.2
		c.metrics.IncUnverifiedSignals()
		if result.Error != nil {
			c.metrics.IncSignatureErrors()
		}
	}

	obs := &model.Observation{
		ID:             fmt.Sprintf("nono-%s-%d", event.AuditSessionID, event.Seq),
		Timestamp:      event.Timestamp,
		Layer:          model.LayerEndpointHost,
		Fidelity:       fidelity,
		Source:         "agent-nono-evidenced",
		Confidence:     confidence,
		ActorHint:      event.SPIFFEID,
		RawEvidenceRef: fmt.Sprintf("nono://session/%s/event/%d", event.AuditSessionID, event.Seq),
		SessionID:      event.AuditSessionID,
		ActorID:        event.AgentID,
		Description:    fmt.Sprintf("Nono Landlock audit session event #%d (%s) [%s]", event.Seq, event.EventType, result.Status),
		Labels: map[string]string{
			"event_type":          event.EventType,
			"spiffe_id":           event.SPIFFEID,
			"agent_id":            event.AgentID,
			"verification_status": string(result.Status),
			"hash_chain_digest":   result.CalculatedDigest,
			"prev_digest":         event.PrevDigest,
			"signature_gitoid":    result.SignatureGitOID,
			"landlock_status":     event.Landlock.Status,
			"landlock_abi":        fmt.Sprintf("%d", event.Landlock.ABIVersion),
			"nono_available":      fmt.Sprintf("%t", event.NonoCapabilityAvailable),
		},
	}

	if event.DelegationChainID != "" {
		obs.Labels["delegation_chain_id"] = event.DelegationChainID
	}
	if event.Syscall != "" {
		obs.Labels["syscall"] = event.Syscall
	}
	if event.Path != "" {
		obs.Labels["path"] = event.Path
	}
	if event.DenialReason != "" {
		obs.Labels["denial_reason"] = event.DenialReason
	}

	if c.sink != nil {
		if err := c.sink.IngestObservation(ctx, obs); err != nil {
			c.cfg.Logger.Error("failed to ingest observation into sink", "error", err)
			return
		}
	}

	c.metrics.IncSignalsIngested()
}

// tailFileLoop tails a local session log file with periodic polling and reopen on rotation.
func (c *Collector) tailFileLoop(ctx context.Context, path string) {
	defer c.wg.Done()
	var file *os.File
	var reader *bufio.Reader
	var offset int64

	for {
		select {
		case <-ctx.Done():
			if file != nil {
				_ = file.Close()
			}
			return
		default:
		}

		if file == nil {
			f, err := os.Open(path)
			if err != nil {
				time.Sleep(500 * time.Millisecond)
				continue
			}
			file = f
			_, _ = file.Seek(offset, io.SeekStart)
			reader = bufio.NewReader(file)
		}

		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				time.Sleep(200 * time.Millisecond)
				continue
			}
			_ = file.Close()
			file = nil
			time.Sleep(500 * time.Millisecond)
			continue
		}

		offset += int64(len(line))
		_ = c.IngestRawLine(ctx, line)
	}
}
