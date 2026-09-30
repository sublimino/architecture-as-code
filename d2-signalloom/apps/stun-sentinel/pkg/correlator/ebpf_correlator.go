// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/cilium/ebpf/ringbuf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/cache"
)

// Default paths and endpoints
const (
	DefaultIngestURL    = "http://signal-ingest:8082"
	DefaultBearerToken  = "sentinel-in-cluster-token"
	DefaultProcRoot     = "/proc"
	DefaultQueueSize    = 10000
	DefaultWorkerCount  = 8
	DefaultHTTPTimeout  = 3 * time.Second
	DefaultRateCapacity = 500
)

// Standard sensitive filesystem prefixes monitored by the correlator
var DefaultSensitivePrefixes = []string{
	"/etc/passwd",
	"/etc/shadow",
	"/var/run/secrets/kubernetes.io/serviceaccount",
	"/root/.ssh",
}

// Regex to extract pod UUIDs from systemd or cgroupfs cgroup paths
// Matches pod<UUID> or pod_<UUID> or pod-<UUID> with dashed or underscored hex
var podUIDRegex = regexp.MustCompile(`pod[_\-]?([0-9a-fA-F]{8}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{12})`)

// FreezeManager encapsulates cgroup freeze containment for Kubernetes pods.
type FreezeManager struct {
	freezer  *cgroup.Freezer
	freezeFn func(pod *corev1.Pod) error
}

// NewFreezeManager creates a FreezeManager backed by the provided cgroup.Freezer.
func NewFreezeManager(freezer *cgroup.Freezer) *FreezeManager {
	return &FreezeManager{freezer: freezer}
}

// NewMockFreezeManager creates a FreezeManager backed by a custom callback function for testing.
func NewMockFreezeManager(freezeFn func(pod *corev1.Pod) error) *FreezeManager {
	return &FreezeManager{freezeFn: freezeFn}
}

// FreezePod halts execution of all processes inside the target pod's cgroup.
// It verifies that the pod is in Running phase before executing containment.
func (fm *FreezeManager) FreezePod(pod *corev1.Pod) error {
	if fm == nil {
		return errors.New("freezeManager is nil")
	}
	if pod == nil {
		return errors.New("pod is nil")
	}

	// Owner-record phase gating (PF-5): Sentinel must verify pod status.phase is Running
	// before attempting cgroup freeze; freezing during ContainerCreating causes permanent wedging.
	if pod.Status.Phase != "" && pod.Status.Phase != corev1.PodRunning {
		return fmt.Errorf("pod %s/%s phase is %s, refusing freeze outside Running phase", pod.Namespace, pod.Name, pod.Status.Phase)
	}

	if fm.freezeFn != nil {
		return fm.freezeFn(pod)
	}

	if fm.freezer != nil {
		_, err := fm.freezer.FreezePod(string(pod.UID), "in-sentinel-governance")
		return err
	}

	return nil
}

// Option configures SentinelProbeManager.
type Option func(*SentinelProbeManager)

// WithProcRoot overrides the default /proc directory path (used for testing).
func WithProcRoot(procRoot string) Option {
	return func(m *SentinelProbeManager) {
		m.procRoot = procRoot
	}
}

// WithBearerToken overrides the default Authorization Bearer token.
func WithBearerToken(token string) Option {
	return func(m *SentinelProbeManager) {
		m.bearerToken = token
	}
}

// WithSensitiveList overrides the default sensitive prefix list.
func WithSensitiveList(list []string) Option {
	return func(m *SentinelProbeManager) {
		m.sensitiveList = list
	}
}

// WithHTTPClient overrides the HTTP client.
func WithHTTPClient(client *http.Client) Option {
	return func(m *SentinelProbeManager) {
		m.httpClient = client
	}
}

// SentinelProbeManager correlates raw eBPF kernel events with Kubernetes pod context,
// executes acute cgroup freeze containment, and streams normalized JSON telemetry to signal-ingest.
type SentinelProbeManager struct {
	informer      cache.SharedIndexInformer
	ingestURL     string
	sensitiveList []string
	freezeManager *FreezeManager
	httpClient    *http.Client
	bearerToken   string
	procRoot      string

	mu      sync.RWMutex
	podMap  map[string]*corev1.Pod // keyed by pod UID (dashed, underscored) and container IDs
	queue   chan TelemetryObservation
	workers int
	wg      sync.WaitGroup
	rateLim chan struct{}
}

// NewSentinelProbeManager constructs a SentinelProbeManager instance.
func NewSentinelProbeManager(informer cache.SharedIndexInformer, ingestURL string, fm *FreezeManager, opts ...Option) *SentinelProbeManager {
	if ingestURL == "" {
		ingestURL = DefaultIngestURL
	}

	m := &SentinelProbeManager{
		informer:      informer,
		ingestURL:     ingestURL,
		sensitiveList: append([]string(nil), DefaultSensitivePrefixes...),
		freezeManager: fm,
		bearerToken:   DefaultBearerToken,
		procRoot:      DefaultProcRoot,
		podMap:        make(map[string]*corev1.Pod),
		queue:         make(chan TelemetryObservation, DefaultQueueSize),
		workers:       DefaultWorkerCount,
		rateLim:       make(chan struct{}, DefaultRateCapacity),
		httpClient: &http.Client{
			Timeout: DefaultHTTPTimeout,
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 20,
				IdleConnTimeout:     90 * time.Second,
			},
		},
	}

	for _, opt := range opts {
		opt(m)
	}

	m.initInformer()
	return m
}

// initInformer registers event handlers to synchronize the pod index cache.
func (m *SentinelProbeManager) initInformer() {
	if m.informer == nil {
		return
	}

	m.informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			if pod, ok := obj.(*corev1.Pod); ok {
				m.indexPod(pod)
			}
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			if pod, ok := newObj.(*corev1.Pod); ok {
				m.indexPod(pod)
			}
		},
		DeleteFunc: func(obj interface{}) {
			if pod, ok := obj.(*corev1.Pod); ok {
				m.removePod(pod)
			}
		},
	})
}

// indexPod adds a pod to the internal lookup index.
func (m *SentinelProbeManager) indexPod(pod *corev1.Pod) {
	if pod == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	uid := string(pod.UID)
	if uid != "" {
		m.podMap[uid] = pod
		m.podMap[strings.ReplaceAll(uid, "-", "_")] = pod
	}
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.ContainerID != "" {
			m.podMap[cs.ContainerID] = pod
			parts := strings.Split(cs.ContainerID, "://")
			if len(parts) == 2 {
				m.podMap[parts[1]] = pod
			}
		}
	}
}

// removePod removes a pod from the internal lookup index.
func (m *SentinelProbeManager) removePod(pod *corev1.Pod) {
	if pod == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	uid := string(pod.UID)
	if uid != "" {
		delete(m.podMap, uid)
		delete(m.podMap, strings.ReplaceAll(uid, "-", "_"))
	}
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.ContainerID != "" {
			delete(m.podMap, cs.ContainerID)
			parts := strings.Split(cs.ContainerID, "://")
			if len(parts) == 2 {
				delete(m.podMap, parts[1])
			}
		}
	}
}

// IsSensitivePath evaluates whether a given file path targets a sensitive system prefix.
func (m *SentinelProbeManager) IsSensitivePath(path string) bool {
	for _, prefix := range m.sensitiveList {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

// lookupPodByPID inspects /proc/<pid>/cgroup, parses container runtime cgroup paths,
// and extracts the matching Kubernetes pod identity.
func (m *SentinelProbeManager) lookupPodByPID(pid uint32) *corev1.Pod {
	cgroupPath := filepath.Join(m.procRoot, fmt.Sprintf("%d", pid), "cgroup")
	data, err := os.ReadFile(cgroupPath)
	if err != nil {
		return nil
	}
	cgroupStr := string(data)

	// Check local indexed cache first
	m.mu.RLock()
	for key, pod := range m.podMap {
		if key != "" && strings.Contains(cgroupStr, key) {
			m.mu.RUnlock()
			return pod
		}
	}
	m.mu.RUnlock()

	// Extract pod UID via regex
	if match := podUIDRegex.FindStringSubmatch(cgroupStr); len(match) > 1 {
		rawUID := match[1]
		dashedUID := strings.ReplaceAll(rawUID, "_", "-")
		underscoredUID := strings.ReplaceAll(rawUID, "-", "_")

		m.mu.RLock()
		if pod, ok := m.podMap[dashedUID]; ok {
			m.mu.RUnlock()
			return pod
		}
		if pod, ok := m.podMap[underscoredUID]; ok {
			m.mu.RUnlock()
			return pod
		}
		m.mu.RUnlock()

		// Fallback: search informer store directly
		if m.informer != nil {
			for _, obj := range m.informer.GetStore().List() {
				pod, ok := obj.(*corev1.Pod)
				if !ok || pod == nil {
					continue
				}
				podUID := string(pod.UID)
				if strings.EqualFold(podUID, dashedUID) || strings.EqualFold(podUID, rawUID) {
					m.indexPod(pod)
					return pod
				}
			}
		}
	}

	// Direct search across informer store for substring matching
	if m.informer != nil {
		for _, obj := range m.informer.GetStore().List() {
			pod, ok := obj.(*corev1.Pod)
			if !ok || pod == nil {
				continue
			}
			uid := string(pod.UID)
			if uid != "" {
				underscored := strings.ReplaceAll(uid, "-", "_")
				if strings.Contains(cgroupStr, uid) || strings.Contains(cgroupStr, underscored) {
					m.indexPod(pod)
					return pod
				}
			}
			for _, cs := range pod.Status.ContainerStatuses {
				if cs.ContainerID != "" {
					parts := strings.Split(cs.ContainerID, "://")
					cid := cs.ContainerID
					if len(parts) == 2 {
						cid = parts[1]
					}
					if strings.Contains(cgroupStr, cid) {
						m.indexPod(pod)
						return pod
					}
				}
			}
		}
	}

	return nil
}

// isAgentPod determines whether a pod is an active governed AI agent pod.
func isAgentPod(pod *corev1.Pod) bool {
	if pod == nil || pod.Labels == nil {
		return false
	}
	if pod.Labels["signalloom.ai/agent"] == "true" ||
		pod.Labels["signalloom.ai/agent-name"] != "" ||
		pod.Labels["tenant"] != "" ||
		pod.Labels["kusari"] != "" {
		return true
	}
	return false
}

// NormalizeObservation transforms a raw SyscallEvent and Pod into a TelemetryObservation.
func (m *SentinelProbeManager) NormalizeObservation(raw SyscallEvent, pod *corev1.Pod) TelemetryObservation {
	filename := strings.TrimRight(string(raw.Filename[:]), "\x00")

	syscallName := SyscallNameOpenat
	switch raw.Type {
	case SyscallTypeExecve:
		syscallName = SyscallNameExecve
	case SyscallTypeConnect:
		syscallName = SyscallNameConnect
	case SyscallTypeOpenat:
		syscallName = SyscallNameOpenat
	}

	obs := TelemetryObservation{
		Timestamp:      time.Now().UTC().Format(time.RFC3339Nano),
		Syscall:        syscallName,
		Target:         filename,
		Severity:       SeverityCritical,
		DirectReaction: ReactionNone,
	}

	if pod != nil {
		obs.PodName = pod.Name
		obs.Namespace = pod.Namespace
		obs.Labels = pod.Labels

		if pod.Labels != nil {
			if actor, ok := pod.Labels["signalloom.ai/agent-name"]; ok && actor != "" {
				obs.ActorID = actor
			} else if actor, ok := pod.Labels["agent-name"]; ok && actor != "" {
				obs.ActorID = actor
			} else if actor, ok := pod.Labels["app"]; ok && actor != "" {
				obs.ActorID = actor
			}

			// Canonical Tenant Vector (Shared Pattern 1)
			if tenant, ok := pod.Labels["tenant"]; ok && tenant != "" {
				if tenant == "kurasi" {
					// Legacy typo forbidden; canonicalize to kusari
					obs.TenantID = DefaultTenantID
				} else {
					obs.TenantID = tenant
				}
			} else if tenant, ok := pod.Labels["kusari"]; ok && tenant != "" {
				obs.TenantID = DefaultTenantID
			}
		}
	}

	if obs.TenantID == "" {
		obs.TenantID = DefaultTenantID
	}

	return obs
}

// Start initiates the ring buffer event consumption loop and worker pool.
func (m *SentinelProbeManager) Start(ctx context.Context, rd *ringbuf.Reader) error {
	if m.informer != nil {
		go m.informer.Run(ctx.Done())
		cache.WaitForCacheSync(ctx.Done(), m.informer.HasSynced)
	}

	// Start asynchronous dispatch worker pool
	for i := 0; i < m.workers; i++ {
		m.wg.Add(1)
		go m.dispatchWorker(ctx)
	}

	defer func() {
		close(m.queue)
		m.wg.Wait()
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		record, err := rd.Read()
		if err != nil {
			if errors.Is(err, ringbuf.ErrClosed) {
				return nil
			}
			continue
		}

		var raw SyscallEvent
		if err := binary.Read(bytes.NewReader(record.RawSample), binary.LittleEndian, &raw); err != nil {
			continue
		}

		filename := strings.TrimRight(string(raw.Filename[:]), "\x00")
		if !m.IsSensitivePath(filename) {
			continue
		}

		pod := m.lookupPodByPID(raw.PID)
		if pod == nil {
			continue
		}

		obs := m.NormalizeObservation(raw, pod)

		// Direct in-sentinel reactive freeze containment
		if isAgentPod(pod) && m.freezeManager != nil {
			if err := m.freezeManager.FreezePod(pod); err == nil {
				obs.DirectReaction = ReactionCgroupFrozen
			}
		}

		// Enqueue observation for non-blocking asynchronous streaming
		select {
		case m.queue <- obs:
		default:
			// Queue full under extreme pressure: drop non-blocking to protect kernel ringbuf
		}
	}
}

// dispatchWorker consumes telemetry observations from the internal queue and sends them to signal-ingest.
func (m *SentinelProbeManager) dispatchWorker(ctx context.Context) {
	defer m.wg.Done()

	for {
		select {
		case <-ctx.Done():
			return
		case obs, ok := <-m.queue:
			if !ok {
				return
			}
			_ = m.dispatchObservation(obs)
		}
	}
}

// dispatchObservation transmits a single TelemetryObservation to signal-ingest via HTTP POST.
func (m *SentinelProbeManager) dispatchObservation(obs TelemetryObservation) error {
	payload, err := json.Marshal(obs)
	if err != nil {
		return err
	}

	url := strings.TrimRight(m.ingestURL, "/") + "/api/v1/observations"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")
	if m.bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+m.bearerToken)
	}

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("signal-ingest returned HTTP status %d", resp.StatusCode)
	}

	return nil
}
