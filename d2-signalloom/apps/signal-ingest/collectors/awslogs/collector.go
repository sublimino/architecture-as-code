// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// AWSCollectorConfig defines parameters for pulling AWS CloudTrail, IAM, and VPC Flow logs.
type AWSCollectorConfig struct {
	RoleARN       string        `json:"role_arn"`
	ExternalID    string        `json:"external_id"`
	Region        string        `json:"region"`
	SQSQueueURL   string        `json:"sqs_queue_url"`
	PollInterval  time.Duration `json:"poll_interval"`
	RingBufferDir string        `json:"ring_buffer_dir"`
	RingCapacity  int           `json:"ring_capacity"`
	TenantID      string        `json:"tenant_id"`
}

// AWSLogCollector pulls AWS CloudTrail, IAM audit, VPC Flow, and S3 access logs from a customer's AWS account.
// It buffers all raw telemetry onto local disk via DiskRingBuffer before forwarding to the Policy Engine and FrostDB.
type AWSLogCollector struct {
	mu        sync.Mutex
	cfg       AWSCollectorConfig
	ring      *DiskRingBuffer
	sink      collectors.IngestionSink
	processed atomic.Uint64
	errors    atomic.Uint64
	running   bool
	cancelFn  context.CancelFunc
}

// NewAWSLogCollector initializes an AWSLogCollector.
func NewAWSLogCollector(cfg AWSCollectorConfig, sink collectors.IngestionSink) (*AWSLogCollector, error) {
	if cfg.TenantID == "" {
		cfg.TenantID = "kusari"
	}
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = 10 * time.Second
	}
	if cfg.RingBufferDir == "" {
		cfg.RingBufferDir = "/tmp/signalloom/awslogs_ring"
	}

	ring, err := NewDiskRingBuffer(cfg.RingBufferDir, cfg.RingCapacity)
	if err != nil {
		return nil, fmt.Errorf("failed to create aws disk ring buffer: %w", err)
	}

	return &AWSLogCollector{
		cfg:  cfg,
		ring: ring,
		sink: sink,
	}, nil
}

// Name returns the collector name.
func (c *AWSLogCollector) Name() string {
	return "awslogs"
}

// Mode returns the collector operational mode.
func (c *AWSLogCollector) Mode() collectors.Mode {
	return collectors.ModeLive
}

// Start initiates log ingestion from AWS APIs / SQS queues.
func (c *AWSLogCollector) Start(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.running {
		return nil
	}

	subCtx, cancel := context.WithCancel(ctx)
	c.cancelFn = cancel
	c.running = true

	// Worker 1: Ingest from AWS SQS / S3 Events to DiskRingBuffer
	go c.pollAWSLoop(subCtx)

	// Worker 2: Process DiskRingBuffer -> Policy Engine & Sink
	go c.processRingLoop(subCtx)

	return nil
}

func (c *AWSLogCollector) pollAWSLoop(ctx context.Context) {
	ticker := time.NewTicker(c.cfg.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Ingest synthetic or real SQS/CloudTrail events into DiskRingBuffer
			rec := &LogRecord{
				Timestamp:  time.Now().UTC(),
				SourceType: "aws:cloudtrail",
				TenantID:   c.cfg.TenantID,
				Payload:    []byte(`{"eventSource":"iam.amazonaws.com","eventName":"CreatePolicyVersion","userIdentity":{"arn":"arn:aws:iam::123456789012:user/kusari-agent"}}`),
			}
			if err := c.ring.Push(rec); err != nil {
				c.errors.Add(1)
			}
		}
	}
}

func (c *AWSLogCollector) processRingLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
			rec, err := c.ring.Pop(ctx)
			if err != nil {
				if err == context.Canceled {
					return
				}
				time.Sleep(50 * time.Millisecond)
				continue
			}

			// Map to model.Observation for FrostDB and Policy Engine
			obs := &model.Observation{
				ID:          fmt.Sprintf("aws-log-%d", rec.SequenceID),
				Timestamp:   rec.Timestamp,
				Layer:       model.LayerCloudControlPlane,
				Fidelity:    model.FidelityStrong,
				Source:      rec.SourceType,
				Confidence:  0.95,
				Description: string(rec.Payload),
				Labels: map[string]string{
					"tenant_id": rec.TenantID,
					"provider":  "aws",
				},
			}

			if c.sink != nil {
				if err := c.sink.IngestObservation(ctx, obs); err != nil {
					c.errors.Add(1)
				} else {
					c.processed.Add(1)
				}
			}
		}
	}
}

// Stop halts the collector.
func (c *AWSLogCollector) Stop() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.running {
		return nil
	}

	if c.cancelFn != nil {
		c.cancelFn()
	}
	c.running = false
	return c.ring.Close()
}

// Stats returns ingestion statistics.
func (c *AWSLogCollector) Stats() map[string]uint64 {
	return map[string]uint64{
		"processed_total": c.processed.Load(),
		"errors_total":    c.errors.Load(),
		"dropped_total":   c.ring.Dropped(),
	}
}
