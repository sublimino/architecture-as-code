// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package netebpf

import (
	"context"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// IngestionSink receives converted observations.
type IngestionSink interface {
	IngestObservation(ctx context.Context, obs *model.Observation) error
}

// InboundFlowEvent represents the wire format of an enriched socket event streamed from Sentinel.
type InboundFlowEvent struct {
	TimestampNs    uint64    `json:"timestamp_ns"`
	Time           time.Time `json:"time"`
	CgroupID       uint64    `json:"cgroup_id"`
	SockCookie     uint64    `json:"sock_cookie"`
	SeqNum         uint64    `json:"seq_num"`
	SrcIP          string    `json:"src_ip"`
	DstIP          string    `json:"dst_ip"`
	SrcPort        uint16    `json:"src_port"`
	DstPort        uint16    `json:"dst_port"`
	Family         uint16    `json:"family"`
	OldState       uint8     `json:"old_state"`
	NewState       uint8     `json:"new_state"`
	BytesSent      uint64    `json:"bytes_sent"`
	BytesRecv      uint64    `json:"bytes_recv"`
	PodName        string    `json:"pod_name"`
	PodNamespace   string    `json:"pod_namespace"`
	PodUID         string    `json:"pod_uid"`
	ServiceAccount string    `json:"service_account"`
	SPIFFEID       string    `json:"spiffe_id"`
	AgentRole      string    `json:"agent_role"`
	Provider       string    `json:"provider"`
	Classification string    `json:"classification"`
	Domain         string    `json:"domain,omitempty"`
	NodeName       string    `json:"node_name,omitempty"`
}

// InboundDropAlert carries kernel drop reports from Sentinel nodes.
type InboundDropAlert struct {
	NodeName     string    `json:"node_name"`
	DroppedCount uint64    `json:"dropped_count"`
	TotalEvents  uint64    `json:"total_events"`
	Timestamp    time.Time `json:"timestamp"`
	Reason       string    `json:"reason"`
}

// LiveNetworkEgressCollector ingests eBPF socket traces and detects sequence gaps.
type LiveNetworkEgressCollector struct {
	sink          IngestionSink
	seqTrackerMu  sync.RWMutex
	lastSeqByNode map[string]uint64
	lastDropByNode map[string]uint64
	receivedCount uint64
	gapCount      uint64
	ingestedCount uint64
	ctx           context.Context
	cancel        context.CancelFunc
}

// NewLiveNetworkEgressCollector creates a new eBPF network telemetry collector.
func NewLiveNetworkEgressCollector(ctx context.Context, sink IngestionSink) *LiveNetworkEgressCollector {
	cCtx, cancel := context.WithCancel(ctx)
	return &LiveNetworkEgressCollector{
		sink:           sink,
		lastSeqByNode:  make(map[string]uint64),
		lastDropByNode: make(map[string]uint64),
		ctx:            cCtx,
		cancel:         cancel,
	}
}

// ProcessFlowEvent validates stream sequence and converts the socket trace into a model.Observation.
func (c *LiveNetworkEgressCollector) ProcessFlowEvent(ctx context.Context, ev *InboundFlowEvent) error {
	if ev == nil {
		return fmt.Errorf("nil flow event")
	}

	atomic.AddUint64(&c.receivedCount, 1)

	nodeKey := ev.NodeName
	if nodeKey == "" {
		nodeKey = "default-node"
	}

	// 1. Sequence Gap Detection
	c.seqTrackerMu.Lock()
	lastSeq, exists := c.lastSeqByNode[nodeKey]
	if exists && ev.SeqNum > lastSeq+1 {
		// Synthesize TELEMETRY_GAP observation
		gapSize := ev.SeqNum - lastSeq - 1
		c.lastSeqByNode[nodeKey] = ev.SeqNum
		c.seqTrackerMu.Unlock()

		atomic.AddUint64(&c.gapCount, 1)
		gapObs := c.createGapObservation(nodeKey, lastSeq+1, ev.SeqNum-1, gapSize, "missing_sequence_numbers")
		if c.sink != nil {
			_ = c.sink.IngestObservation(ctx, gapObs)
		}
	} else {
		c.lastSeqByNode[nodeKey] = ev.SeqNum
		c.seqTrackerMu.Unlock()
	}

	// 2. Convert FlowEvent to model.Observation
	obs := c.flowToObservation(ev)

	if c.sink != nil {
		if err := c.sink.IngestObservation(ctx, obs); err != nil {
			return fmt.Errorf("sink ingestion failed: %w", err)
		}
	}

	atomic.AddUint64(&c.ingestedCount, 1)
	return nil
}

// ProcessDropAlert synthesizes a TELEMETRY_GAP observation when kernel drops occur.
func (c *LiveNetworkEgressCollector) ProcessDropAlert(ctx context.Context, alert *InboundDropAlert) error {
	if alert == nil {
		return fmt.Errorf("nil drop alert")
	}

	nodeKey := alert.NodeName
	if nodeKey == "" {
		nodeKey = "default-node"
	}

	c.seqTrackerMu.Lock()
	lastDrops := c.lastDropByNode[nodeKey]
	if alert.DroppedCount <= lastDrops {
		c.seqTrackerMu.Unlock()
		return nil // no new drops
	}
	deltaDrops := alert.DroppedCount - lastDrops
	c.lastDropByNode[nodeKey] = alert.DroppedCount
	c.seqTrackerMu.Unlock()

	atomic.AddUint64(&c.gapCount, 1)
	gapObs := c.createGapObservation(nodeKey, 0, 0, deltaDrops, alert.Reason)
	if c.sink != nil {
		return c.sink.IngestObservation(ctx, gapObs)
	}
	return nil
}

func (c *LiveNetworkEgressCollector) flowToObservation(ev *InboundFlowEvent) *model.Observation {
	ts := ev.Time
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	labels := map[string]string{
		"pod_name":        ev.PodName,
		"namespace":       ev.PodNamespace,
		"pod_uid":         ev.PodUID,
		"service_account": ev.ServiceAccount,
		"spiffe_id":       ev.SPIFFEID,
		"agent_role":      ev.AgentRole,
		"provider":        ev.Provider,
		"classification":  ev.Classification,
		"src_ip":          ev.SrcIP,
		"dst_ip":          ev.DstIP,
		"src_port":        fmt.Sprintf("%d", ev.SrcPort),
		"dst_port":        fmt.Sprintf("%d", ev.DstPort),
		"destination":     net.JoinHostPort(ev.DstIP, fmt.Sprintf("%d", ev.DstPort)),
		"seq_num":         fmt.Sprintf("%d", ev.SeqNum),
		"cgroup_id":       fmt.Sprintf("%d", ev.CgroupID),
		"bytes_sent":      fmt.Sprintf("%d", ev.BytesSent),
	}
	if ev.Domain != "" {
		labels["domain"] = ev.Domain
	}

	obs := &model.Observation{
		ID:         fmt.Sprintf("netebpf-%s-%d-%d", ev.PodName, ev.CgroupID, ev.SeqNum),
		Timestamp:  ts,
		Layer:      model.LayerNetworkEgress,
		Fidelity:   model.FidelityStrong,
		Confidence: 0.85,
		Source:     "sentinel.ebpf.socket_trace",
		Labels:     labels,
	}

	return obs
}

func (c *LiveNetworkEgressCollector) createGapObservation(nodeKey string, startSeq, endSeq, dropCount uint64, reason string) *model.Observation {
	return &model.Observation{
		ID:         fmt.Sprintf("telemetry-gap-%s-%d", nodeKey, time.Now().UnixNano()),
		Timestamp:  time.Now().UTC(),
		Layer:      model.LayerNetworkEgress,
		Fidelity:   model.FidelitySuggestive,
		Confidence: 0.40,
		Source:     "sentinel.ebpf.gap_detector",
		Labels: map[string]string{
			"type":            "telemetry_gap",
			"node_name":       nodeKey,
			"gap_start_seq":   fmt.Sprintf("%d", startSeq),
			"gap_end_seq":     fmt.Sprintf("%d", endSeq),
			"dropped_count":   fmt.Sprintf("%d", dropCount),
			"reason":          reason,
			"coverage_status": "degraded_fail_closed",
		},
	}
}

// Stats returns collector ingestion metrics.
func (c *LiveNetworkEgressCollector) Stats() (received, gaps, ingested uint64) {
	return atomic.LoadUint64(&c.receivedCount), atomic.LoadUint64(&c.gapCount), atomic.LoadUint64(&c.ingestedCount)
}

// Close gracefully stops the collector.
func (c *LiveNetworkEgressCollector) Close() {
	if c.cancel != nil {
		c.cancel()
	}
}
