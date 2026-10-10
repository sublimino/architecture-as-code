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
	"net"
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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/netlink"
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

// Standard sensitive filesystem prefixes monitored by the correlator. This is
// the ONE source of the table: bpf/sensitive_prefixes.h, which the probe uses
// to keep never-sensitive opens out of the ring buffer, is generated from it
// (`go run ./cmd/gen-sensitive-prefixes`, then `bpf/build.sh sentinel`), and
// TestSensitivePrefixesHeaderIsGeneratedFromTheGoTable fails on drift.
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
	reasonFn   func(pod *corev1.Pod, syscall, target string) error
}

// NewReasonedFreezeManager creates a FreezeManager that hands every freeze,
// with the syscall and target that caused it, to fn. The caller owns the
// freeze and can record why it happened.
func NewReasonedFreezeManager(fn func(pod *corev1.Pod, syscall, target string) error) *FreezeManager {
	return &FreezeManager{reasonFn: fn}
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
	return fm.FreezePodFor(pod, "", "")
}

// FreezePodFor is FreezePod with the syscall and target that caused it.
func (fm *FreezeManager) FreezePodFor(pod *corev1.Pod, syscall, target string) error {
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

	if fm.reasonFn != nil {
		return fm.reasonFn(pod, syscall, target)
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

// WithSpoolDir overrides the default spool directory.
func WithSpoolDir(dir string) Option {
	return func(m *SentinelProbeManager) {
		m.spoolDir = dir
	}
}

// WithSpoolMaxBytes overrides the default spool max byte cap.
func WithSpoolMaxBytes(maxBytes int64) Option {
	return func(m *SentinelProbeManager) {
		m.spoolMaxBytes = maxBytes
	}
}

// WithSpoolMaxAge overrides the default spool max age.
func WithSpoolMaxAge(maxAge time.Duration) Option {
	return func(m *SentinelProbeManager) {
		m.spoolMaxAge = maxAge
	}
}

// WithBatchMax overrides the maximum observation count per batch.
func WithBatchMax(batchMax int) Option {
	return func(m *SentinelProbeManager) {
		m.batchMax = batchMax
	}
}

// WithBatchLinger overrides the batch linger duration.
func WithBatchLinger(batchLinger time.Duration) Option {
	return func(m *SentinelProbeManager) {
		m.batchLinger = batchLinger
	}
}

// WithClock overrides the clock (used for testing with mockClock).
func WithClock(clk Clock) Option {
	return func(m *SentinelProbeManager) {
		m.clock = clk
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

// WithBearerTokenSource sets a function the sender asks for the bearer on
// every post, for a key that is not available at start (the Secret mounted
// late, or a key file that appears later). While the source returns "" the
// sender SPOOLS every batch instead of dropping it, and the spool is drained
// once a token appears. A fixed WithBearerToken takes precedence when set.
func WithBearerTokenSource(source func() string) Option {
	return func(m *SentinelProbeManager) {
		m.tokenSource = source
	}
}

// token is the bearer to post with right now: the fixed token, else what the
// source currently returns, else "".
func (m *SentinelProbeManager) token() string {
	if m.bearerToken != "" {
		return m.bearerToken
	}
	if m.tokenSource != nil {
		return strings.TrimSpace(m.tokenSource())
	}
	return ""
}

// IngestTokenConfigured reports whether observations can be posted at all.
func (m *SentinelProbeManager) IngestTokenConfigured() bool {
	return m.token() != ""
}

// WithSensitiveList overrides the default sensitive prefix list. It can only
// narrow what the live probe reports: the kernel prefilter passes the opens
// that DefaultSensitivePrefixes could match (bpf/sensitive_prefixes.h), so a
// wider list needs the table changed, regenerated and the probe rebuilt.
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

// WithSelf overrides the sentinel's own identity (default: the downward API).
func WithSelf(self filter.Self) Option {
	return func(m *SentinelProbeManager) {
		m.self = self
	}
}

// WithDNSCache sets the DNS resolution cache for egress correlation (SLWD Phase 2).
func WithDNSCache(cache *DNSCache) Option {
	return func(m *SentinelProbeManager) {
		m.dnsCache = cache
	}
}

// WithNetlinkResolver sets the netlink veth resolver for ifindex-to-pod correlation (SLWD Phase 2).
func WithNetlinkResolver(r *netlink.Resolver) Option {
	return func(m *SentinelProbeManager) {
		m.netlinkResolver = r
	}
}

// WithPresentationFilter sets the 3-tier presentation volume filter (SLWD Phase 3).
func WithPresentationFilter(pf *PresentationFilter) Option {
	return func(m *SentinelProbeManager) {
		m.presentationFilter = pf
	}
}

// WithDNSHeuristicsEngine sets the anomaly heuristics evaluation engine (SLWD Phase 2).
func WithDNSHeuristicsEngine(engine *DNSHeuristicsEngine) Option {
	return func(m *SentinelProbeManager) {
		m.heuristicsEngine = engine
	}
}

// ifindexEntry stores the pod identity mapped from a host veth interface index.
type ifindexEntry struct {
	PodUID     string
	PodName    string
	Namespace  string
	CgroupPath string
	IndexedAt  time.Time
}

// fromSelf drops, and counts, a record from this sentinel's own pod.
func (m *SentinelProbeManager) fromSelf(pod *corev1.Pod) bool {
	if !m.self.Is(pod) {
		return false
	}
	m.stats.selfExcluded.Add(1)
	return true
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
	tokenSource   func() string // WithBearerTokenSource; nil without one
	procRoot      string
	tenants       *TenantMap

	mu      sync.RWMutex
	podMap  map[string]*corev1.Pod // keyed by pod UID (dashed, underscored) and container IDs
	queue   chan TelemetryObservation
	workers int
	wg      sync.WaitGroup
	rateLim chan struct{}

	stats pipelineStats

	spoolDir      string
	spoolMaxBytes int64
	spoolMaxAge   time.Duration
	batchMax      int
	batchLinger   time.Duration
	clock         Clock
	spool         *Spool
	sender        *Sender

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

	// self is this sentinel's own pod (downward API). A record from it is
	// never a detection: its tc execs tripped the burst detector live.
	self filter.Self

	// runtimeBinaries locate the node's runc (runtime_lookup.go).
	runtimeBinaries []string
	// containerdConfigs locate the node's OCI hooks (runtime_hooks.go).
	containerdConfigs []string
	// bundleRoots hold each container's OCI bundle (runtime_hooks.go).
	bundleRoots []string

	// dnsCache holds the in-memory DNS resolution cache for egress correlation (SLWD Phase 2).
	dnsCache *DNSCache

	// netlinkResolver resolves container host veth interfaces for ifindex attribution (SLWD Phase 2).
	netlinkResolver *netlink.Resolver
	ifindexMap      map[uint32]ifindexEntry // host ifindex -> pod & cgroup
	ifindexMu       sync.RWMutex

	// presentationFilter enforces the 3-tier presentation volume filter (SLWD Phase 3).
	presentationFilter *PresentationFilter

	// heuristicsEngine evaluates DNS and TLS anomaly heuristics (SLWD Phase 2).
	heuristicsEngine *DNSHeuristicsEngine
}

// NewSentinelProbeManager constructs a SentinelProbeManager instance.
func NewSentinelProbeManager(informer cache.SharedIndexInformer, ingestURL string, fm *FreezeManager, opts ...Option) *SentinelProbeManager {
	if ingestURL == "" {
		ingestURL = DefaultIngestURL
	}

	m := &SentinelProbeManager{
		informer:          informer,
		ingestURL:         ingestURL,
		sensitiveList:     append([]string(nil), DefaultSensitivePrefixes...),
		freezeManager:     fm,
		procRoot:          DefaultProcRoot,
		podMap:            make(map[string]*corev1.Pod),
		ifindexMap:        make(map[uint32]ifindexEntry),
		queue:             make(chan TelemetryObservation, DefaultQueueSize),
		workers:           1,
		rateLim:           make(chan struct{}, DefaultRateCapacity),
		burst:             newBurstTracker(),
		burstThreshold:    DefaultEvasiveBurstThreshold,
		burstWindow:       DefaultEvasiveBurstWindow,
		self:              filter.SelfFromEnv(),
		runtimeBinaries:   DefaultRuntimeBinaries,
		containerdConfigs: DefaultContainerdConfigs,
		bundleRoots:       DefaultBundleRoots,
		spoolDir:          DefaultSpoolDir,
		spoolMaxBytes:     DefaultSpoolMaxBytes,
		spoolMaxAge:       DefaultSpoolMaxAge,
		batchMax:          DefaultBatchMax,
		batchLinger:       DefaultBatchLinger,
		clock:             realClock{},
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

	// Initialize default presentation filter if none was provided via options
	if m.presentationFilter == nil {
		m.presentationFilter = NewPresentationFilter(
			WithPresentationFilterDNSCache(m.dnsCache),
			WithPresentationFilterClock(m.clock),
		)
	}

	spool, _ := NewSpool(m.spoolDir, m.spoolMaxBytes, m.spoolMaxAge, m.clock, &m.stats)
	m.spool = spool
	m.sender = newSender(m, spool, m.batchMax, m.batchLinger, m.clock)

	m.initInformer()
	return m
}

// PresentationFilter returns the configured PresentationFilter.
func (m *SentinelProbeManager) PresentationFilter() *PresentationFilter {
	return m.presentationFilter
}

// DNSCache returns the configured DNSCache.
func (m *SentinelProbeManager) DNSCache() *DNSCache {
	return m.dnsCache
}

// DNSHeuristicsEngine returns the configured DNSHeuristicsEngine.
func (m *SentinelProbeManager) DNSHeuristicsEngine() *DNSHeuristicsEngine {
	return m.heuristicsEngine
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

// podKey formats a pod's namespace/name identifier, falling back to name or UID.
func podKey(pod *corev1.Pod) string {
	if pod == nil {
		return ""
	}
	if pod.Namespace != "" && pod.Name != "" {
		return pod.Namespace + "/" + pod.Name
	}
	if pod.Name != "" {
		return pod.Name
	}
	return string(pod.UID)
}

// SetIfindexMapping binds a host interface index to a pod and cgroup path.
func (m *SentinelProbeManager) SetIfindexMapping(ifindex uint32, pod *corev1.Pod, cgroupPath string) {
	if ifindex == 0 || pod == nil {
		return
	}
	m.ifindexMu.Lock()
	defer m.ifindexMu.Unlock()

	m.ifindexMap[ifindex] = ifindexEntry{
		PodUID:     string(pod.UID),
		PodName:    pod.Name,
		Namespace:  pod.Namespace,
		CgroupPath: cgroupPath,
		IndexedAt:  m.clock.Now(),
	}
}

// LookupPodByIfindex returns the pod and cgroup path mapped to ifindex.
// Returns (nil, "", false) if unmapped or if the pod has been deleted.
func (m *SentinelProbeManager) LookupPodByIfindex(ifindex uint32) (*corev1.Pod, string, bool) {
	if ifindex == 0 {
		return nil, "", false
	}
	m.ifindexMu.RLock()
	entry, ok := m.ifindexMap[ifindex]
	m.ifindexMu.RUnlock()
	if !ok {
		return nil, "", false
	}

	// Verify pod still exists in podMap (has not been deleted)
	pod := m.podByUID(entry.PodUID)
	if pod == nil && entry.Namespace != "" && entry.PodName != "" {
		m.mu.RLock()
		for _, p := range m.podMap {
			if p.Namespace == entry.Namespace && p.Name == entry.PodName {
				pod = p
				break
			}
		}
		m.mu.RUnlock()
	}
	if pod == nil {
		return nil, "", false
	}

	return pod, entry.CgroupPath, true
}

// ResolveIfindex resolves an ifindex to pod, pod key (namespace/name), and cgroup path.
func (m *SentinelProbeManager) ResolveIfindex(ifindex uint32) (*corev1.Pod, string, string, bool) {
	pod, cgroupPath, ok := m.LookupPodByIfindex(ifindex)
	if !ok || pod == nil {
		return nil, "", "", false
	}
	return pod, podKey(pod), cgroupPath, true
}

// findPIDForContainer scans /proc to find a PID belonging to containerID.
func (m *SentinelProbeManager) findPIDForContainer(containerID string) int {
	if containerID == "" || m.procRoot == "" {
		return 0
	}
	entries, err := os.ReadDir(m.procRoot)
	if err != nil {
		return 0
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		cgroupFile := filepath.Join(m.procRoot, entry.Name(), "cgroup")
		data, err := os.ReadFile(cgroupFile)
		if err != nil {
			continue
		}
		if strings.Contains(string(data), containerID) {
			return pid
		}
	}
	return 0
}

// indexPodIfindex resolves the host veth ifindex for pod via the netlink resolver and updates the ifindex map.
func (m *SentinelProbeManager) indexPodIfindex(pod *corev1.Pod) {
	if m.netlinkResolver == nil || pod == nil {
		return
	}

	// 1. Try resolving via cgroup path
	var cgroupPath string
	if m.cgroupRoot != "" {
		m.cgMu.Lock()
		uid := string(pod.UID)
		dashedUID := strings.ReplaceAll(uid, "_", "-")
		for _, p := range m.cgroupPaths {
			if strings.Contains(p, dashedUID) || strings.Contains(p, uid) {
				cgroupPath = p
				break
			}
		}
		m.cgMu.Unlock()
	}

	if cgroupPath != "" {
		fullCgPath := filepath.Join(m.cgroupRoot, strings.TrimPrefix(cgroupPath, "/"))
		if res, err := m.netlinkResolver.ResolveCgroup(context.Background(), fullCgPath); err == nil && res.HostIndex > 0 {
			m.SetIfindexMapping(uint32(res.HostIndex), pod, cgroupPath)
			return
		}
	}

	// 2. Try resolving via container PIDs in /proc
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.ContainerID == "" {
			continue
		}
		parts := strings.Split(cs.ContainerID, "://")
		cid := cs.ContainerID
		if len(parts) == 2 {
			cid = parts[1]
		}
		if pid := m.findPIDForContainer(cid); pid > 0 {
			if res, err := m.netlinkResolver.Resolve(context.Background(), pid); err == nil && res.HostIndex > 0 {
				m.SetIfindexMapping(uint32(res.HostIndex), pod, cgroupPath)
				return
			}
		}
	}
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

	if m.netlinkResolver != nil {
		m.indexPodIfindex(pod)
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

	// Evict ifindex mappings for this pod to prevent misattribution on kernel ifindex reuse
	m.ifindexMu.Lock()
	for ifindex, entry := range m.ifindexMap {
		if (uid != "" && entry.PodUID == uid) ||
			(pod.Name != "" && entry.PodName == pod.Name && entry.Namespace == pod.Namespace) {
			delete(m.ifindexMap, ifindex)
		}
	}
	m.ifindexMu.Unlock()
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

	// Severity: a sensitive open, exec or burst is CRITICAL and freezes; a
	// connect is WARN, reported for correlation (docs/EAP/enforcement.md).
	// Its target is the remote endpoint the probe captured, not a path.
	target, severity := filename, SeverityCritical
	if raw.Type == SyscallTypeConnect {
		target, severity = raw.RemoteEndpoint(), SeverityWarn
	}
	obs := TelemetryObservation{
		Timestamp:      eventWallTime(raw.TsNs).UTC().Format(time.RFC3339Nano),
		Syscall:        syscallName,
		Target:         target,
		Severity:       severity,
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

		// The actor is the pod's service account, never a label: labels are
		// written by whoever creates the pod, so `signalloom.ai/agent-name:
		// kusari-agent` on any watched pod used to credit kusari's agent. Same
		// residual as tenancy: anyone who can create pods in a namespace can
		// run them as any SA there, so the namespace is the real boundary.
		obs.ActorID = pod.Spec.ServiceAccountName
		if obs.ActorID == "" {
			obs.ActorID = "default" // what the API server admits an unset name as
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

	// Start single asynchronous dispatch sender goroutine (SLTM-P2-1)
	m.wg.Add(1)
	go m.sender.run(ctx)

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
	raw.Family, raw.DestPort, raw.DestAddr = ev.Family, ev.DestPort, ev.DestAddr
	filename := ev.Filename
	targetPID := ev.PID

	// A connect carries an endpoint, not a path: it bypasses the sensitive
	// path filter and the runtime-lookup exemption, is reported at WARN, and
	// never freezes. Before this it died here with an empty filename.
	if raw.Type == SyscallTypeConnect {
		return m.reportConnect(raw, ev)
	}

	// SLAAT-P2-4: evasive-burst detection runs independently of, and before,
	// the sensitive-path filter below. A rapid process-spawn flood (and the
	// forked child an unshare(CLONE_NEWPID) escape leaves behind) has no
	// sensitive path to open, so the filter alone never sees it -- the rate
	// itself is the signal. See SLAAT-P1-4/F1 and the live reproduction at
	// SLAAT-P2-PRE's SENTINEL-F1.
	opener := &OpenerIdentity{Comm: ev.Comm, TGID: ev.TGID, UID: ev.UID, ExeIno: ev.ExeIno, ExeSize: ev.ExeSize}
	if raw.Type == SyscallTypeExecve && m.burst.observe(ev.CgroupID, time.Now(), m.burstThreshold, m.burstWindow) {
		if obs, ok := m.reportEvasiveBurst(raw, targetPID, ev.CgroupID, opener); ok {
			return obs, true
		}
	}

	resolved, ok := m.sensitiveTarget(filename, targetPID, ev.CgroupID)
	if !ok {
		m.stats.notSensitive.Add(1)
		return TelemetryObservation{}, false
	}
	// The container runtime resolving the container's user, before the
	// entrypoint runs: neither a detection nor a freeze (runtime_lookup.go).
	if exempt, atEvent := m.runtimeUserLookup(resolved, targetPID, ev.CgroupID, ev.ExeIno, ev.ExeSize, ev.Comm); exempt {
		m.stats.runtimeLookups.Add(1)
		if atEvent {
			m.stats.runtimeLookupsAtEvent.Add(1)
		}
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
	if m.fromSelf(pod) {
		return TelemetryObservation{}, false
	}
	m.stats.matched.Add(1)

	obs := m.NormalizeObservation(raw, pod)
	obs.CgroupPath = m.cgroupPathFor(ev.CgroupID, targetPID)
	// A setup open that reached here was NOT exempted as the runtime's: say
	// what it was compared against (live, 2026-10-03, cpai-engineer-0).
	if runtimeSetupOpens[resolved] {
		opener.NodeRuntime = m.nodeRuntimeIdentities(ev.CgroupID)
	}
	obs.Opener = opener

	// Direct in-sentinel reactive freeze containment
	if isAgentPod(pod) && m.freezeManager != nil {
		if err := m.freezeManager.FreezePodFor(pod, obs.Syscall, obs.Target); err == nil {
			obs.DirectReaction = ReactionCgroupFrozen
		}
	}
	return obs, true
}

// reportConnect builds the WARN observation for a connect from a watched
// pod. ok is false when the destination is unset (the probe filters to
// AF_INET/AF_INET6, so this is drift) or no owning pod resolves.
func (m *SentinelProbeManager) reportConnect(raw SyscallEvent, ev *ebpf.SyscallEvent) (TelemetryObservation, bool) {
	if raw.RemoteEndpoint() == "" {
		m.stats.notSensitive.Add(1)
		return TelemetryObservation{}, false
	}
	var pod *corev1.Pod
	if m.cgroupRoot != "" {
		pod = m.lookupPodByCgroupID(ev.CgroupID)
	} else {
		pod = m.lookupPodByPID(ev.PID)
		if pod == nil && raw.TGID != 0 {
			pod = m.lookupPodByPID(raw.TGID)
		}
	}
	if pod == nil {
		m.stats.noPod.Add(1)
		return TelemetryObservation{}, false
	}
	if m.fromSelf(pod) {
		return TelemetryObservation{}, false
	}
	m.stats.matched.Add(1)
	obs := m.NormalizeObservation(raw, pod)
	obs.CgroupPath = m.cgroupPathFor(ev.CgroupID, ev.PID)
	obs.Opener = &OpenerIdentity{Comm: ev.Comm, TGID: ev.TGID, UID: ev.UID, ExeIno: ev.ExeIno, ExeSize: ev.ExeSize}

	// Enrich with domain from DNSCache if available (SLWD Phase 2)
	if m.dnsCache != nil && len(raw.DestAddr) > 0 {
		destIP := ipToString(raw.DestAddr)
		if destIP != "" {
			podIdentifier := podKey(pod)
			domain, found := m.dnsCache.Lookup(podIdentifier, destIP)
			if !found && string(pod.UID) != "" && string(pod.UID) != podIdentifier {
				domain, found = m.dnsCache.Lookup(string(pod.UID), destIP)
			}
			if !found && obs.CgroupPath != "" {
				domain, found = m.dnsCache.Lookup(obs.CgroupPath, destIP)
			}
			if found && domain != "" {
				obs.Domain = domain
			}
		}
	}

	return obs, true
}

// ProcessDNSResolution records a DNS resolution in DNSCache and filters its presentation telemetry
// using the 3-tier presentation volume defense (SLWD Phase 3).
//
// Returns (obs, true) if the resolution observation should be emitted (first encounter or expired),
// or (TelemetryObservation{}, false) if suppressed by the 3-tier presentation filter.
func (m *SentinelProbeManager) ProcessDNSResolution(
	pod *corev1.Pod,
	podOrCgroup string,
	answers []net.IP,
	ttls []uint32,
	qname, cname string,
) (TelemetryObservation, bool) {
	if podOrCgroup == "" && pod != nil {
		podOrCgroup = podKey(pod)
	}

	// 1. Insert into DNSCache (indexes every answer IP with per-record floored/ceiled TTLs)
	if m.dnsCache != nil {
		m.dnsCache.Insert(podOrCgroup, answers, ttls, qname, cname)
	}

	var rawTTL uint32
	if len(ttls) > 0 {
		rawTTL = ttls[0]
	}

	// 2. Build DNS resolution observation
	obs := BuildDNSResolutionObservation(pod, qname, answers, m.clock)

	// 3. Filter presentation (Tier 2: emit once per unique name within TTL)
	if m.presentationFilter != nil {
		filteredObs, emit := m.presentationFilter.FilterObservation(podOrCgroup, qname, rawTTL, obs)
		if !emit || filteredObs == nil {
			return TelemetryObservation{}, false
		}
		return *filteredObs, true
	}

	return *obs, true
}

// reportEvasiveBurst builds the telemetry observation for a detected
// execve-rate burst and, for a governed agent pod, triggers the same direct
// freeze containment the sensitive-path path uses. ok is false when no
// owning pod can be resolved -- there is nothing to report or freeze.
func (m *SentinelProbeManager) reportEvasiveBurst(raw SyscallEvent, targetPID uint32, cgroupID uint64, opener *OpenerIdentity) (TelemetryObservation, bool) {
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
	if m.fromSelf(pod) {
		return TelemetryObservation{}, false
	}
	m.stats.matched.Add(1)

	obs := m.NormalizeObservation(raw, pod)
	obs.Syscall = SyscallNameEvasiveBurst
	obs.Target = fmt.Sprintf(">=%d execve in %s from one cgroup", m.burstThreshold, m.burstWindow)
	obs.Severity = SeverityCritical
	obs.CgroupPath = m.cgroupPathFor(cgroupID, targetPID)
	obs.Opener = opener

	if isAgentPod(pod) && m.freezeManager != nil {
		if err := m.freezeManager.FreezePodFor(pod, obs.Syscall, obs.Target); err == nil {
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
	token := m.token()
	if token == "" {
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
	req.Header.Set("Authorization", "Bearer "+token)

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
