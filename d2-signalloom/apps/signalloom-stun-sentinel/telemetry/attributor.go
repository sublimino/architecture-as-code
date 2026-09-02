// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package telemetry

import (
	"fmt"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/ebpf"
)

// PodAttributor maps kernel flow events to rich Kubernetes and AI identity context.
type PodAttributor interface {
	RegisterPod(cgroupID uint64, meta *PodMetadata)
	UnregisterPod(cgroupID uint64)
	Enrich(ev ebpf.FlowEvent, domain string) EnrichedFlowEvent
	GetPod(cgroupID uint64) (*PodMetadata, bool)
}

type podAttributorImpl struct {
	mu         sync.RWMutex
	livePods   map[uint64]*PodMetadata
	tombstones TombstoneCache
	classifier AIProviderClassifier
}

// NewPodAttributor creates a new PodAttributor with the given tombstone TTL.
func NewPodAttributor(tombstoneTTL time.Duration) PodAttributor {
	return &podAttributorImpl{
		livePods:   make(map[uint64]*PodMetadata),
		tombstones: NewTombstoneCache(tombstoneTTL),
		classifier: NewAIProviderClassifier(),
	}
}

func (a *podAttributorImpl) RegisterPod(cgroupID uint64, meta *PodMetadata) {
	if meta == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	// Ensure SPIFFE ID is populated
	if meta.SPIFFEID == "" && meta.PodNamespace != "" && meta.ServiceAccount != "" {
		meta.SPIFFEID = fmt.Sprintf("spiffe://cluster.local/ns/%s/sa/%s", meta.PodNamespace, meta.ServiceAccount)
	}

	a.livePods[cgroupID] = meta
}

func (a *podAttributorImpl) UnregisterPod(cgroupID uint64) {
	a.mu.Lock()
	defer a.mu.Unlock()

	meta, ok := a.livePods[cgroupID]
	if ok {
		// Move to tombstone cache to retain 60s attribution window for late close events
		a.tombstones.Put(cgroupID, meta)
		delete(a.livePods, cgroupID)
	}
}

func (a *podAttributorImpl) GetPod(cgroupID uint64) (*PodMetadata, bool) {
	a.mu.RLock()
	meta, ok := a.livePods[cgroupID]
	a.mu.RUnlock()

	if ok {
		return meta, true
	}

	// Fallback to tombstone cache
	return a.tombstones.Get(cgroupID)
}

func (a *podAttributorImpl) Enrich(ev ebpf.FlowEvent, domain string) EnrichedFlowEvent {
	meta, _ := a.GetPod(ev.CgroupID)

	provider, class := a.classifier.Classify(ev.DstIP, ev.DstPort, domain)

	enriched := EnrichedFlowEvent{
		FlowEvent:      ev,
		Provider:       provider,
		Classification: class,
		Domain:         domain,
		EnrichedAt:     time.Now().UTC(),
	}

	if meta != nil {
		enriched.PodName = meta.PodName
		enriched.PodNamespace = meta.PodNamespace
		enriched.PodUID = meta.PodUID
		enriched.ServiceAccount = meta.ServiceAccount
		enriched.SPIFFEID = meta.SPIFFEID
		enriched.AgentRole = meta.AgentRole
	} else {
		enriched.PodName = fmt.Sprintf("unattributed-cgroup-%d", ev.CgroupID)
		enriched.PodNamespace = "unknown"
	}

	return enriched
}
