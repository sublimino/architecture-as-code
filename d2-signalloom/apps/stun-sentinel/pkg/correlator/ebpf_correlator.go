// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cilium/ebpf/ringbuf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/filter"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/cache"
)

// Default paths and endpoints
const (
	DefaultIngestURL    = "http://signal-ingest:8082"
	DefaultProcRoot     = "/proc"
	DefaultQueueSize    = 10000
	DefaultWorkerCount  = 8
	DefaultHTTPTimeout  = 3 * time.Second
	DefaultRateCapacity = 500

	// DefaultEvasiveBurstThreshold and DefaultEvasiveBurstWindow (SLAAT-P2-4):
	// the execve-rate signal used to catch a process-spawn flood that opens
	// no sensitive path. Chosen well above ordinary tool-invocation churn
	// (a shell running a handful of commands) and comfortably below the
	// 200-spawn burst the card's probe-sentinel-evasion.sh drives.
	DefaultEvasiveBurstThreshold = 20
	DefaultEvasiveBurstWindow    = 1 * time.Second
)

// Standard sensitive filesystem prefixes monitored by the correlator
var DefaultSensitivePrefixes = []string{
	"/etc/passwd",
	"/etc/shadow",
	"/var/run/secrets/kubernetes.io/serviceaccount",
	"/run/secrets/kubernetes.io/serviceaccount", // /var/run is a symlink to /run
	"/root/.ssh",
}

// Regex to extract pod UUIDs from systemd or cgroupfs cgroup paths
// Matches pod<UUID> or pod_<UUID> or pod-<UUID> with dashed or underscored hex
var podUIDRegex = regexp.MustCompile(`pod[_\-]?([0-9a-fA-F]{8}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{4}[_\-][0-9a-fA-F]{12})`)

// FreezeManager encapsulates cgroup freeze containment for Kubernetes pods.
type FreezeManager struct {
	freezer    *cgroup.Freezer
	credential string
	freezeFn   func(pod *corev1.Pod) error
}

// NewFreezeManager creates a FreezeManager backed by the provided
// cgroup.Freezer, presenting credential to its freeze validator.
func NewFreezeManager(freezer *cgroup.Freezer, credential string) *FreezeManager {
	return &FreezeManager{freezer: freezer, credential: credential}
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

	// Owner-record phase gating (PF-5) & Self/Infra Exclusion (SLDC-P1-3)
	if err := filter.Default().CheckFreezable(pod); err != nil {
		return err
	}

	if fm.freezeFn != nil {
		return fm.freezeFn(pod)
	}

	if fm.freezer != nil {
		_, err := fm.freezer.FreezePod(string(pod.UID), fm.credential)
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

// ErrIngestTokenMissing is returned instead of posting when no ingest
// credential is configured. There is deliberately no default: the old one,
// "sentinel-in-cluster-token", was a public string in this file.
var ErrIngestTokenMissing = errors.New("no signal-ingest bearer configured (SIGNAL_INGEST_TOKEN from Secret stun-sentinel-ingest-token); observation not posted")

// WithBearerToken sets the signal-ingest bearer. Surrounding whitespace (a
// trailing newline from a Secret file) is dropped; a blank token is no token.
func WithBearerToken(token string) Option {
	return func(m *SentinelProbeManager) {
		m.bearerToken = strings.TrimSpace(token)
	}
}

// IngestTokenConfigured reports whether observations can be posted at all.
func (m *SentinelProbeManager) IngestTokenConfigured() bool {
	return m.bearerToken != ""
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

// WithEvasiveBurstThreshold overrides the default execve-rate burst
// detection parameters (SLAAT-P2-4). Exposed mainly for tests that need a
// burst to trip inside a handful of synthetic events rather than twenty.
func WithEvasiveBurstThreshold(threshold int, window time.Duration) Option {
	return func(m *SentinelProbeManager) {
		m.burstThreshold = threshold
		m.burstWindow = window
	}
}

// burstTracker counts EXECVE events per cgroup within a sliding window, to
// catch a rapid process-spawn flood that never touches a sensitive path
// (SLAAT-P2-4/F1; reproduced live as SLAAT-P2-PRE's SENTINEL-F1: a
// 200-process-spawn burst generated zero telemetry under the
// sensitive-path-only filter). The signal here is RATE, not WHICH path was
// opened, so it runs independently of IsSensitivePath.
type burstTracker struct {
	mu          sync.Mutex
	windowStart map[uint64]time.Time
	count       map[uint64]int
}

func newBurstTracker() *burstTracker {
	return &burstTracker{
		windowStart: make(map[uint64]time.Time),
		count:       make(map[uint64]int),
	}
}

// observe records one EXECVE event for cgroupID at ts and reports whether
// threshold was reached within window. Reaching it resets the window for
// that cgroup, so a sustained attacker is re-flagged every window rather
// than alerting once and then falling silent for the rest of the cgroup's
// life -- each reset is itself a fresh detection, not a suppression.
func (b *burstTracker) observe(cgroupID uint64, ts time.Time, threshold int, window time.Duration) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	start, ok := b.windowStart[cgroupID]
	if !ok || ts.Sub(start) > window {
		b.windowStart[cgroupID] = ts
		b.count[cgroupID] = 1
		return false
	}
	b.count[cgroupID]++
	if b.count[cgroupID] >= threshold {
		delete(b.windowStart, cgroupID)
		delete(b.count, cgroupID)
		return true
	}
	return false
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
	tenants       *TenantMap

	mu      sync.RWMutex
	podMap  map[string]*corev1.Pod // keyed by pod UID (dashed, underscored) and container IDs
	queue   chan TelemetryObservation
	workers int
	wg      sync.WaitGroup
	rateLim chan struct{}

	stats pipelineStats

	cgroupRoot      string
	cgMu            sync.Mutex
	cgroupIndex     map[uint64]string // cgroup inode -> pod UID
	cgroupPaths     map[uint64]string // cgroup inode -> path below the cgroup root
	cgroupIndexedAt time.Time
	cgroupMisses    map[uint64]time.Time // inode -> until when it is a known miss
	cgroupWalks     atomic.Uint64

	burst          *burstTracker
	burstThreshold int
	burstWindow    time.Duration
}

// NewSentinelProbeManager constructs a SentinelProbeManager instance.
func NewSentinelProbeManager(informer cache.SharedIndexInformer, ingestURL string, fm *FreezeManager, opts ...Option) *SentinelProbeManager {
	if ingestURL == "" {
		ingestURL = DefaultIngestURL
	}

	m := &SentinelProbeManager{
		informer:       informer,
		ingestURL:      ingestURL,
		sensitiveList:  append([]string(nil), DefaultSensitivePrefixes...),
		freezeManager:  fm,
		procRoot:       DefaultProcRoot,
		podMap:         make(map[string]*corev1.Pod),
		queue:          make(chan TelemetryObservation, DefaultQueueSize),
		workers:        DefaultWorkerCount,
		rateLim:        make(chan struct{}, DefaultRateCapacity),
		burst:          newBurstTracker(),
		burstThreshold: DefaultEvasiveBurstThreshold,
		burstWindow:    DefaultEvasiveBurstWindow,
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
			if tomb, ok := obj.(cache.DeletedFinalStateUnknown); ok {
				obj = tomb.Obj
			}
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

// IsSensitivePath reports whether an absolute path, once lexically cleaned,
// is a sensitive prefix or lies beneath one. Matching is per path component:
// /etc/passwd covers /etc/passwd/x but not /etc/passwdX. Relative paths are
// never sensitive here; see sensitiveTarget.
func (m *SentinelProbeManager) IsSensitivePath(p string) bool {
	if !path.IsAbs(p) {
		return false
	}
	p = path.Clean(p)
	for _, prefix := range m.sensitiveList {
		prefix = path.Clean(prefix)
		if p == prefix || strings.HasPrefix(p, prefix+"/") {
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
		Timestamp:      eventWallTime(raw.TsNs).UTC().Format(time.RFC3339Nano),
		Syscall:        syscallName,
		Target:         filename,
		Severity:       SeverityCritical,
		DirectReaction: ReactionNone,
	}

	if pod != nil {
		obs.PodName = pod.Name
		obs.Namespace = pod.Namespace
		// A copy: pod.Labels is the informer's cached map, and the wire
		// payload adds keys to the observation's labels.
		obs.Labels = make(map[string]string, len(pod.Labels))
		for k, v := range pod.Labels {
			obs.Labels[k] = v
		}

		if pod.Labels != nil {
			if actor, ok := pod.Labels["signalloom.ai/agent-name"]; ok && actor != "" {
				obs.ActorID = actor
			} else if actor, ok := pod.Labels["agent-name"]; ok && actor != "" {
				obs.ActorID = actor
			} else if actor, ok := pod.Labels["app"]; ok && actor != "" {
				obs.ActorID = actor
			}
		}
	}

	// Tenancy comes from the operator's map, keyed by where the pod runs and
	// as whom -- never from its labels, which its creator writes (review M5).
	// An unmapped workload is marked, not dropped and not defaulted.
	obs.TenantID = UnattributedTenantID
	if pod != nil {
		obs.TenantID = m.tenants.Resolve(pod.Namespace, pod.Spec.ServiceAccountName)
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
			m.stats.readErrors.Add(1)
			continue
		}
		m.stats.recordsRead.Add(1)

		obs, ok := m.handleRecord(record.RawSample)
		if !ok {
			continue
		}

		// Enqueue observation for non-blocking asynchronous streaming
		select {
		case m.queue <- obs:
			m.stats.enqueued.Add(1)
		default:
			m.stats.queueDropped.Add(1)
			// Queue full under extreme pressure: drop non-blocking to protect kernel ringbuf
		}
	}
}

// handleRecord turns one raw ring-buffer record into an observation,
// freezing the owning agent pod when policy allows. ok is false when the
// record carries nothing to report.
func (m *SentinelProbeManager) handleRecord(sample []byte) (TelemetryObservation, bool) {
	// Records that do not decode as syscall_event_t are dropped: guessing at
	// another layout would feed misaligned PIDs and paths into a freeze.
	ev, err := ebpf.DecodeSyscallEvent(sample)
	if err != nil {
		m.stats.decodeErrors.Add(1)
		return TelemetryObservation{}, false
	}
	var raw SyscallEvent
	raw.TsNs = ev.TimestampNs
	raw.PID = ev.PID
	raw.TGID = ev.TGID
	raw.UID = ev.UID
	raw.Type = uint8(ev.Type)
	copy(raw.Comm[:], ev.Comm)
	copy(raw.Filename[:], ev.Filename)
	filename := ev.Filename
	targetPID := ev.PID

	// SLAAT-P2-4: evasive-burst detection runs independently of, and before,
	// the sensitive-path filter below. A rapid process-spawn flood (and the
	// forked child an unshare(CLONE_NEWPID) escape leaves behind) has no
	// sensitive path to open, so the filter alone never sees it -- the rate
	// itself is the signal. See SLAAT-P1-4/F1 and the live reproduction at
	// SLAAT-P2-PRE's SENTINEL-F1.
	if raw.Type == SyscallTypeExecve && m.burst.observe(ev.CgroupID, time.Now(), m.burstThreshold, m.burstWindow) {
		if obs, ok := m.reportEvasiveBurst(raw, targetPID, ev.CgroupID); ok {
			return obs, true
		}
	}

	if _, ok := m.sensitiveTarget(filename, targetPID, ev.CgroupID); !ok {
		m.stats.notSensitive.Add(1)
		return TelemetryObservation{}, false
	}

	// With a cgroup root the inode is authoritative: it is the same in every
	// namespace. The PID is the kernel's root-namespace PID, which on a nested
	// node can name an unrelated process, so falling back to it froze the
	// wrong pod (review H1). The PID path remains only for a sentinel run
	// without a cgroup root, where nothing better exists.
	var pod *corev1.Pod
	if m.cgroupRoot != "" {
		pod = m.lookupPodByCgroupID(ev.CgroupID)
	} else {
		pod = m.lookupPodByPID(targetPID)
		if pod == nil && raw.TGID != 0 {
			pod = m.lookupPodByPID(raw.TGID)
		}
	}
	if pod == nil {
		m.stats.noPod.Add(1)
		return TelemetryObservation{}, false
	}
	m.stats.matched.Add(1)

	obs := m.NormalizeObservation(raw, pod)
	obs.CgroupPath = m.cgroupPathFor(ev.CgroupID, targetPID)

	// Direct in-sentinel reactive freeze containment
	if isAgentPod(pod) && m.freezeManager != nil {
		if err := m.freezeManager.FreezePod(pod); err == nil {
			obs.DirectReaction = ReactionCgroupFrozen
		}
	}
	return obs, true
}

// reportEvasiveBurst builds the telemetry observation for a detected
// execve-rate burst and, for a governed agent pod, triggers the same direct
// freeze containment the sensitive-path path uses. ok is false when no
// owning pod can be resolved -- there is nothing to report or freeze.
func (m *SentinelProbeManager) reportEvasiveBurst(raw SyscallEvent, targetPID uint32, cgroupID uint64) (TelemetryObservation, bool) {
	var pod *corev1.Pod
	if m.cgroupRoot != "" {
		pod = m.lookupPodByCgroupID(cgroupID)
	} else {
		pod = m.lookupPodByPID(targetPID)
		if pod == nil && raw.TGID != 0 {
			pod = m.lookupPodByPID(raw.TGID)
		}
	}
	if pod == nil {
		m.stats.noPod.Add(1)
		return TelemetryObservation{}, false
	}
	m.stats.matched.Add(1)

	obs := m.NormalizeObservation(raw, pod)
	obs.Syscall = SyscallNameEvasiveBurst
	obs.Target = fmt.Sprintf(">=%d execve in %s from one cgroup", m.burstThreshold, m.burstWindow)
	obs.Severity = SeverityCritical
	obs.CgroupPath = m.cgroupPathFor(cgroupID, targetPID)

	if isAgentPod(pod) && m.freezeManager != nil {
		if err := m.freezeManager.FreezePod(pod); err == nil {
			obs.DirectReaction = ReactionCgroupFrozen
		}
	}
	return obs, true
}

// sensitiveTarget resolves filename as pid would see it and reports whether
// it is sensitive. The probe captures the raw argument, so a relative path is
// joined to the process cwd; if the cwd is unreadable the process has exited
// and there is nothing left to freeze. dirfd-relative opens and symlinks are
// not resolved here (the probe does not capture dirfd or the opened inode).
func (m *SentinelProbeManager) sensitiveTarget(filename string, pid uint32, cgroupID uint64) (string, bool) {
	if filename != "" && !path.IsAbs(filename) {
		// A relative path needs the process's cwd. Trust the PID only once it
		// is proven to be in the event's cgroup (review H1).
		if m.cgroupRoot != "" && (m.lookupPodByCgroupID(cgroupID) == nil || !m.pidInEventCgroup(pid, cgroupID)) {
			return "", false
		}
		cwd, err := os.Readlink(filepath.Join(m.procRoot, strconv.FormatUint(uint64(pid), 10), "cwd"))
		if err != nil || !path.IsAbs(cwd) {
			return "", false
		}
		filename = path.Join(cwd, filename)
	}
	return path.Clean(filename), m.IsSensitivePath(filename)
}

// dispatchWorker consumes telemetry observations from the internal queue,
// logs each one to stdout, and sends it to signal-ingest.
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
			logObservation(obs)
			err := m.dispatchObservation(obs)
			if errors.Is(err, ErrIngestTokenMissing) {
				// Not a dispatch failure: nothing was sent. Counted on its own
				// so the stats line says why dispatch_ok is not moving.
				m.stats.ingestTokenMissing.Add(1)
				continue
			}
			m.recordDispatch(err)
			if err != nil {
				logDispatchFailure(obs, err)
			}
		}
	}
}

// correlatorLogOut and correlatorLogMu back logObservation/logDispatchFailure.
// A package-level var (not a field) because handleRecord/dispatchWorker run
// across both daemon binaries that embed this package, and tests need a
// seam to capture output without threading a writer through every call.
var (
	correlatorLogOut io.Writer = os.Stdout
	correlatorLogMu  sync.Mutex
)

// correlatorEvent is the structured JSON audit line emitted to stdout for
// every observation, independent of whether the signal-ingest HTTP POST
// that follows succeeds (SLAAT-P2-4). Previously an observation's only
// trace was that POST: dispatchWorker discarded dispatchObservation's error
// outright, so a detected sensitive-path access or evasive burst left zero
// evidence anywhere `kubectl logs` could show if signal-ingest happened to
// be unreachable. A detection that can be lost to a downstream outage is
// not "generating immediate alarms".
type correlatorEvent struct {
	Timestamp   string               `json:"timestamp"`
	Event       string               `json:"event"`
	Observation TelemetryObservation `json:"observation"`
	Error       string               `json:"error,omitempty"`
}

func logObservation(obs TelemetryObservation) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp:   time.Now().UTC().Format(time.RFC3339Nano),
		Event:       "ebpf_detection",
		Observation: obs,
	})
}

func logDispatchFailure(obs TelemetryObservation, err error) {
	writeCorrelatorEvent(correlatorEvent{
		Timestamp:   time.Now().UTC().Format(time.RFC3339Nano),
		Event:       "ebpf_detection_dispatch_failed",
		Observation: obs,
		Error:       err.Error(),
	})
}

func writeCorrelatorEvent(ev correlatorEvent) {
	correlatorLogMu.Lock()
	defer correlatorLogMu.Unlock()
	_ = json.NewEncoder(correlatorLogOut).Encode(ev)
}

// dispatchObservation transmits a single TelemetryObservation to signal-ingest via HTTP POST.
func (m *SentinelProbeManager) dispatchObservation(obs TelemetryObservation) error {
	if m.bearerToken == "" {
		return ErrIngestTokenMissing
	}
	payload, err := json.Marshal([]ingestObservation{obs.toIngest()})
	if err != nil {
		return err
	}

	url := strings.TrimRight(m.ingestURL, "/") + "/api/v1/observations"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+m.bearerToken)

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
