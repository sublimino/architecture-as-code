// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// TCP State Constants matching Linux kernel definitions
const (
	TCPEstablished = 1
	TCPSynSent     = 2
	TCPClose       = 7

	AF_INET  = 2
	AF_INET6 = 10
)

// FlowEvent captures an outbound network flow transition emitted by the kernel probe.
type FlowEvent struct {
	TimestampNs uint64    `json:"timestamp_ns"`
	Time        time.Time `json:"time"`
	CgroupID    uint64    `json:"cgroup_id"`
	SockCookie  uint64    `json:"sock_cookie"`
	SeqNum      uint64    `json:"seq_num"`
	SrcIP       net.IP    `json:"src_ip"`
	DstIP       net.IP    `json:"dst_ip"`
	SrcPort     uint16    `json:"src_port"`
	DstPort     uint16    `json:"dst_port"`
	Family      uint16    `json:"family"`
	OldState    uint8     `json:"old_state"`
	NewState    uint8     `json:"new_state"`
	BytesSent   uint64    `json:"bytes_sent"`
	BytesRecv   uint64    `json:"bytes_recv"`
}

// DropStats reports kernel drop and total event metrics.
type DropStats struct {
	RingbufDrops uint64 `json:"ringbuf_drops"`
	TotalEvents  uint64 `json:"total_events"`
	LastPolled   time.Time `json:"last_polled"`
}

// ProbeManager handles the lifecycle of the eBPF socket tracing probe.
type ProbeManager interface {
	Start(ctx context.Context) error
	Stop() error
	Events() <-chan FlowEvent
	GetDropStats() (DropStats, error)
	SimulateEvent(ev FlowEvent)
	SimulateDrop(count uint64)
}

type probeManagerImpl struct {
	mu           sync.RWMutex
	eventsCh     chan FlowEvent
	dropsCount   uint64
	totalEvents  uint64
	running      bool
	cancelFunc   context.CancelFunc
	wg           sync.WaitGroup
	simulatedSeq uint64
}

// NewProbeManager creates a new instance of ProbeManager.
func NewProbeManager(bufferSize int) ProbeManager {
	if bufferSize <= 0 {
		bufferSize = 10000
	}
	return &probeManagerImpl{
		eventsCh: make(chan FlowEvent, bufferSize),
	}
}

func (p *probeManagerImpl) Start(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.running {
		return fmt.Errorf("probe manager already running")
	}

	subCtx, cancel := context.WithCancel(ctx)
	p.cancelFunc = cancel
	p.running = true

	// Background worker routine
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		<-subCtx.Done()
	}()

	return nil
}

func (p *probeManagerImpl) Stop() error {
	p.mu.Lock()
	if !p.running {
		p.mu.Unlock()
		return nil
	}
	p.running = false
	if p.cancelFunc != nil {
		p.cancelFunc()
	}
	p.mu.Unlock()

	p.wg.Wait()
	return nil
}

func (p *probeManagerImpl) Events() <-chan FlowEvent {
	return p.eventsCh
}

func (p *probeManagerImpl) GetDropStats() (DropStats, error) {
	return DropStats{
		RingbufDrops: atomic.LoadUint64(&p.dropsCount),
		TotalEvents:  atomic.LoadUint64(&p.totalEvents),
		LastPolled:   time.Now().UTC(),
	}, nil
}

func (p *probeManagerImpl) SimulateEvent(ev FlowEvent) {
	if ev.TimestampNs == 0 {
		ev.TimestampNs = uint64(time.Now().UnixNano())
	}
	if ev.Time.IsZero() {
		ev.Time = time.Now().UTC()
	}
	if ev.SeqNum == 0 {
		ev.SeqNum = atomic.AddUint64(&p.simulatedSeq, 1)
	}

	atomic.AddUint64(&p.totalEvents, 1)

	select {
	case p.eventsCh <- ev:
	default:
		// Channel full, increment drop count
		atomic.AddUint64(&p.dropsCount, 1)
	}
}

func (p *probeManagerImpl) SimulateDrop(count uint64) {
	atomic.AddUint64(&p.dropsCount, count)
}

// DecodeRawEvent decodes raw binary flow_event_t bytes from kernel ring buffer.
func DecodeRawEvent(data []byte) (*FlowEvent, error) {
	if len(data) < 56 {
		return nil, fmt.Errorf("event buffer too short: %d bytes (expected >= 56)", len(data))
	}

	ev := &FlowEvent{
		TimestampNs: binary.LittleEndian.Uint64(data[0:8]),
		Time:        time.Now().UTC(),
		CgroupID:    binary.LittleEndian.Uint64(data[8:16]),
		SockCookie:  binary.LittleEndian.Uint64(data[16:24]),
		SeqNum:      binary.LittleEndian.Uint64(data[24:32]),
		SrcPort:     binary.LittleEndian.Uint16(data[40:42]),
		DstPort:     binary.LittleEndian.Uint16(data[42:44]),
		Family:      binary.LittleEndian.Uint16(data[44:46]),
		OldState:    data[46],
		NewState:    data[47],
		BytesSent:   binary.LittleEndian.Uint64(data[48:56]),
	}

	if ev.Family == AF_INET {
		ev.SrcIP = net.IPv4(data[32], data[33], data[34], data[35])
		ev.DstIP = net.IPv4(data[36], data[37], data[38], data[39])
	}

	return ev, nil
}
