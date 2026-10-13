// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	corev1 "k8s.io/api/core/v1"
)

// canonical test vectors from Shared Patterns Phase 2:
const (
	batch1Body = `[{"id":"stun-sentinel:fe-signalloom-agents/agent-kusari-7d9f:2026-10-01T22:35:33.123456789Z:sys_enter_openat:74acf31844532670","timestamp":"2026-10-01T22:35:33.123456789Z","layer":"endpoint_host","fidelity":"strong","source":"stun-sentinel","confidence":0.95,"actor_id":"kusari-agent","raw_evidence_ref":"ebpf://sys_enter_openat/74acf31844532670","labels":{"cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable-pod771fb437.slice","direct_reaction":"cgroup_frozen","namespace":"fe-signalloom-agents","pod_name":"agent-kusari-7d9f","severity":"CRITICAL","syscall":"sys_enter_openat","target":"/etc/passwd","tenant_id":"kusari"},"description":"sys_enter_openat target 74acf31844532670 by fe-signalloom-agents/agent-kusari-7d9f"}]`
	batch1Hash = "81ff916f0fdf3d8d7cb6a133070f18a8e3b1579867ae131727314e147a635aa0"

	batch2Body = `[{"id":"stun-sentinel:fe-signalloom-agents/agent-cardvault-5b7c:2026-10-01T22:35:34.000000000Z:sys_enter_openat:74acf31844532670","timestamp":"2026-10-01T22:35:34.000000000Z","layer":"endpoint_host","fidelity":"strong","source":"stun-sentinel","confidence":0.95,"actor_id":"cardvault-agent","raw_evidence_ref":"ebpf://sys_enter_openat/74acf31844532670","labels":{"cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable-pod771fb437.slice","direct_reaction":"cgroup_frozen","namespace":"fe-signalloom-agents","pod_name":"agent-cardvault-5b7c","severity":"CRITICAL","syscall":"sys_enter_openat","target":"/etc/shadow","tenant_id":"__unattributed__"},"description":"sys_enter_openat target 74acf31844532670 by fe-signalloom-agents/agent-cardvault-5b7c"},{"id":"stun-sentinel:fe-signalloom-agents/agent-kusari-7d9f:2026-10-01T22:35:35.000000000Z:sys_enter_execve:1234567890abcdef","timestamp":"2026-10-01T22:35:35.000000000Z","layer":"endpoint_host","fidelity":"strong","source":"stun-sentinel","confidence":0.95,"actor_id":"kusari-agent","raw_evidence_ref":"ebpf://sys_enter_execve/1234567890abcdef","labels":{"cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable-pod771fb437.slice","namespace":"fe-signalloom-agents","pod_name":"agent-kusari-7d9f","severity":"CRITICAL","syscall":"sys_enter_execve","target":"/bin/busybox","tenant_id":"kusari"},"description":"sys_enter_execve target 1234567890abcdef by fe-signalloom-agents/agent-kusari-7d9f"}]`
	batch2Hash = "8e0b5ada5165abbbdaf691f152a3e6a4dd392aab67da7522a61976cd147f831a"

	batch3Body = `[{"id":"stun-sentinel:fe-signalloom-agents/agent-kusari-7d9f:2026-10-01T22:35:36.000000000Z:evasive_syscall_burst:fedcba0987654321","timestamp":"2026-10-01T22:35:36.000000000Z","layer":"endpoint_host","fidelity":"strong","source":"stun-sentinel","confidence":0.95,"actor_id":"kusari-agent","raw_evidence_ref":"ebpf://evasive_syscall_burst/fedcba0987654321","labels":{"cgroup_path":"/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable-pod771fb437.slice","namespace":"fe-signalloom-agents","pod_name":"agent-kusari-7d9f","severity":"CRITICAL","syscall":"evasive_syscall_burst","target":">=20 execve in 1s from one cgroup","tenant_id":"kusari"},"description":"evasive_syscall_burst target fedcba0987654321 by fe-signalloom-agents/agent-kusari-7d9f"}]`
	batch3Hash = "95651ec386a92c31c12056ef512dd5b09b315a3627eb02f9cf9525d790de2657"
)

type receivedRequest struct {
	Epoch string
	Seq   string
	Prev  string
	Body  string
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestBatchChainHeaders(t *testing.T) {
	// Verify SHA-256 test vector hashes match exactly
	if h := sha256Hex([]byte(batch1Body)); h != batch1Hash {
		t.Fatalf("batch1 hash = %s, want %s", h, batch1Hash)
	}
	if h := sha256Hex([]byte(batch2Body)); h != batch2Hash {
		t.Fatalf("batch2 hash = %s, want %s", h, batch2Hash)
	}
	if h := sha256Hex([]byte(batch3Body)); h != batch3Hash {
		t.Fatalf("batch3 hash = %s, want %s", h, batch3Hash)
	}

	var reqs []receivedRequest
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bodyBytes, _ := io.ReadAll(r.Body)
		mu.Lock()
		reqs = append(reqs, receivedRequest{
			Epoch: r.Header.Get("X-SignalLoom-Batch-Epoch"),
			Seq:   r.Header.Get("X-SignalLoom-Batch-Seq"),
			Prev:  r.Header.Get("X-SignalLoom-Batch-Prev"),
			Body:  string(bodyBytes),
		})
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	spoolDir := t.TempDir()
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
		WithBatchMax(1),
		WithBatchLinger(10*time.Millisecond),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	m.wg.Add(1)
	go m.sender.run(ctx)

	// Send 3 observations
	obs1 := TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd", Severity: "CRITICAL"}
	obs2 := TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/shadow", Severity: "CRITICAL"}
	obs3 := TelemetryObservation{Syscall: "sys_enter_execve", Target: "/bin/busybox", Severity: "CRITICAL"}

	m.queue <- obs1
	m.queue <- obs2
	m.queue <- obs3

	// Wait for 3 requests to arrive
	for i := 0; i < 50; i++ {
		mu.Lock()
		count := len(reqs)
		mu.Unlock()
		if count >= 3 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	cancel()
	m.wg.Wait()

	mu.Lock()
	defer mu.Unlock()

	if len(reqs) != 3 {
		t.Fatalf("received %d requests, want 3", len(reqs))
	}

	// Check epoch is 32 lowercase hex chars
	epoch := reqs[0].Epoch
	if len(epoch) != 32 || strings.ToLower(epoch) != epoch {
		t.Fatalf("invalid epoch %q: must be 32 lowercase hex chars", epoch)
	}
	for i, req := range reqs {
		if req.Epoch != epoch {
			t.Fatalf("req[%d] epoch = %q, want %q", i, req.Epoch, epoch)
		}
	}

	// Check sequences 1, 2, 3
	if reqs[0].Seq != "1" || reqs[1].Seq != "2" || reqs[2].Seq != "3" {
		t.Fatalf("sequences = [%s, %s, %s], want [1, 2, 3]", reqs[0].Seq, reqs[1].Seq, reqs[2].Seq)
	}

	// Check Prev hashes
	if reqs[0].Prev != "" {
		t.Fatalf("req[0] prev = %q, want empty string for Seq 1", reqs[0].Prev)
	}
	expectedPrev2 := sha256Hex([]byte(reqs[0].Body))
	if reqs[1].Prev != expectedPrev2 {
		t.Fatalf("req[1] prev = %q, want %q", reqs[1].Prev, expectedPrev2)
	}
	expectedPrev3 := sha256Hex([]byte(reqs[1].Body))
	if reqs[2].Prev != expectedPrev3 {
		t.Fatalf("req[2] prev = %q, want %q", reqs[2].Prev, expectedPrev3)
	}
}

func TestBatchEpochIsRandomPerStart(t *testing.T) {
	m1 := NewSentinelProbeManager(NewMockSharedIndexInformer(), unreachableIngestURL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(t.TempDir()),
	)
	m2 := NewSentinelProbeManager(NewMockSharedIndexInformer(), unreachableIngestURL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(t.TempDir()),
	)

	e1 := m1.sender.epoch
	e2 := m2.sender.epoch

	if len(e1) != 32 || len(e2) != 32 {
		t.Fatalf("invalid epoch lengths: e1=%d, e2=%d (want 32)", len(e1), len(e2))
	}
	if e1 == e2 {
		t.Fatalf("epochs must be random and unique per start, got e1 == e2 == %q", e1)
	}
}

func TestSpoolRetainsBatchesAcrossIngestOutage(t *testing.T) {
	var requestCount atomic.Int64
	var failOutage atomic.Bool
	failOutage.Store(true)

	var received []receivedRequest
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestCount.Add(1)
		if failOutage.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		bodyBytes, _ := io.ReadAll(r.Body)
		mu.Lock()
		received = append(received, receivedRequest{
			Epoch: r.Header.Get("X-SignalLoom-Batch-Epoch"),
			Seq:   r.Header.Get("X-SignalLoom-Batch-Seq"),
			Prev:  r.Header.Get("X-SignalLoom-Batch-Prev"),
			Body:  string(bodyBytes),
		})
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	spoolDir := t.TempDir()
	clk := newMockClock(time.Now())

	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
		WithBatchMax(1),
		WithBatchLinger(10*time.Millisecond),
		WithClock(clk),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	m.wg.Add(1)
	go m.sender.run(ctx)

	// Send N=3 batches during outage
	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd"}
	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/shadow"}
	m.queue <- TelemetryObservation{Syscall: "sys_enter_execve", Target: "/bin/sh"}

	// Wait for batches to be spooled. The budget is wall time scaled by
	// TEST_TIMEOUT_SCALE, not a fixed iteration count: three batches on disk is
	// the assertion, and how many times the sender goroutine got scheduled on
	// the way there is not.
	waitForCond(t, 4*time.Second, func() { clk.Advance(1 * time.Second) }, func() bool {
		return m.Stats().SpoolBatches >= 3
	})

	if m.Stats().SpoolBatches < 3 {
		t.Fatalf("spool_batches = %d, want at least 3", m.Stats().SpoolBatches)
	}

	// Recover ingest
	failOutage.Store(false)
	clk.Advance(2 * time.Second)

	// Wait for replay to complete
	waitForCond(t, 4*time.Second, func() { clk.Advance(1 * time.Second) }, func() bool {
		mu.Lock()
		cnt := len(received)
		mu.Unlock()
		return cnt >= 3 && m.Stats().SpoolBatches == 0
	})

	cancel()
	m.wg.Wait()

	mu.Lock()
	defer mu.Unlock()

	if len(received) != 3 {
		t.Fatalf("received %d replayed requests, want 3", len(received))
	}
	if received[0].Seq != "1" || received[1].Seq != "2" || received[2].Seq != "3" {
		t.Fatalf("replayed sequences = [%s, %s, %s], want [1, 2, 3]", received[0].Seq, received[1].Seq, received[2].Seq)
	}
	if m.Stats().SpoolReplayed < 3 {
		t.Fatalf("spool_replayed = %d, want at least 3", m.Stats().SpoolReplayed)
	}
}

func TestSpoolReplayAfterRestartKeepsOriginalChain(t *testing.T) {
	spoolDir := t.TempDir()

	// 1. First run: probe spools 2 batches and stops before ingest responds
	stats1 := &pipelineStats{}
	spool1, err := NewSpool(spoolDir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats1)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	oldEpoch := "aaaa1111bbbb2222cccc3333dddd4444"
	env1 := sampleEnvelope(oldEpoch, 1, "", 1)
	env2 := sampleEnvelope(oldEpoch, 2, "prev-hash-1", 1)

	if _, err := spool1.WriteBatch(env1); err != nil {
		t.Fatalf("WriteBatch 1: %v", err)
	}
	if _, err := spool1.WriteBatch(env2); err != nil {
		t.Fatalf("WriteBatch 2: %v", err)
	}

	// 2. Restart probe on same spool directory with healthy ingest
	var received []receivedRequest
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bodyBytes, _ := io.ReadAll(r.Body)
		mu.Lock()
		received = append(received, receivedRequest{
			Epoch: r.Header.Get("X-SignalLoom-Batch-Epoch"),
			Seq:   r.Header.Get("X-SignalLoom-Batch-Seq"),
			Prev:  r.Header.Get("X-SignalLoom-Batch-Prev"),
			Body:  string(bodyBytes),
		})
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	m2 := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
		WithBatchMax(1),
		WithBatchLinger(10*time.Millisecond),
	)

	newEpoch := m2.sender.epoch
	if newEpoch == oldEpoch {
		t.Fatal("new epoch must differ from old epoch")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	m2.wg.Add(1)
	go m2.sender.run(ctx)

	// Send a live batch after restart
	m2.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/hosts"}

	// Wait for all 3 batches (2 replayed + 1 live)
	waitForCond(t, 4*time.Second, nil, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(received) >= 3
	})

	cancel()
	m2.wg.Wait()

	mu.Lock()
	defer mu.Unlock()

	if len(received) != 3 {
		t.Fatalf("received %d requests, want 3 (2 replayed + 1 live)", len(received))
	}

	// Batch 1 & 2 must preserve old epoch & sequence
	if received[0].Epoch != oldEpoch || received[0].Seq != "1" || received[0].Prev != "" {
		t.Fatalf("batch 0 = %+v, want oldEpoch seq=1 prev=''", received[0])
	}
	if received[1].Epoch != oldEpoch || received[1].Seq != "2" || received[1].Prev != "prev-hash-1" {
		t.Fatalf("batch 1 = %+v, want oldEpoch seq=2 prev='prev-hash-1'", received[1])
	}

	// Batch 3 must carry NEW epoch and seq 1 with empty prev
	if received[2].Epoch != newEpoch || received[2].Seq != "1" || received[2].Prev != "" {
		t.Fatalf("batch 2 = %+v, want newEpoch seq=1 prev=''", received[2])
	}
}

func TestSpoolCrashAfter2xxBeforeDeleteResendsIdenticalBytes(t *testing.T) {
	spoolDir := t.TempDir()

	var attempts []receivedRequest
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bodyBytes, _ := io.ReadAll(r.Body)
		mu.Lock()
		attempts = append(attempts, receivedRequest{
			Epoch: r.Header.Get("X-SignalLoom-Batch-Epoch"),
			Seq:   r.Header.Get("X-SignalLoom-Batch-Seq"),
			Prev:  r.Header.Get("X-SignalLoom-Batch-Prev"),
			Body:  string(bodyBytes),
		})
		mu.Unlock()
		// Returns 201 Created
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	stats := &pipelineStats{}
	spool, err := NewSpool(spoolDir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	env := sampleEnvelope("crash-epoch", 1, "", 1)
	filePath, err := spool.WriteBatch(env)
	if err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	// Replay attempt 1: send to ingest, but simulate crash before deletion
	sender := &Sender{
		bearerToken: testIngestToken,
		ingestURL:   srv.URL,
		client:      srv.Client(),
		clock:       realClock{},
		stats:       stats,
	}

	res, _, err := sender.sendEnvelope(context.Background(), env)
	if err != nil || res != resultSuccess {
		t.Fatalf("sendEnvelope 1 = (%v, %v), want (resultSuccess, nil)", res, err)
	}

	// File is still in spool (simulating crash before delete)
	if _, err := os.Stat(filePath); err != nil {
		t.Fatalf("file should still exist: %v", err)
	}

	// Replay attempt 2 (after recovery): re-send the exact file
	batches, err := spool.ListBatches()
	if err != nil || len(batches) != 1 {
		t.Fatalf("ListBatches = (%v, len=%d), want 1", err, len(batches))
	}

	res2, _, err := sender.sendEnvelope(context.Background(), batches[0].Envelope)
	if err != nil || res2 != resultSuccess {
		t.Fatalf("sendEnvelope 2 = (%v, %v)", res2, err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(attempts) != 2 {
		t.Fatalf("attempts = %d, want 2", len(attempts))
	}

	if attempts[0].Epoch != attempts[1].Epoch ||
		attempts[0].Seq != attempts[1].Seq ||
		attempts[0].Prev != attempts[1].Prev ||
		attempts[0].Body != attempts[1].Body {
		t.Fatalf("attempt 2 differed from attempt 1:\natt1=%+v\natt2=%+v", attempts[0], attempts[1])
	}
}

func TestSpoolDoesNotRetry401Or403(t *testing.T) {
	for _, statusCode := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		t.Run(fmt.Sprintf("Status_%d", statusCode), func(t *testing.T) {
			var requestCount atomic.Int64
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				requestCount.Add(1)
				w.WriteHeader(statusCode)
			}))
			defer srv.Close()

			spoolDir := t.TempDir()
			m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
				WithBearerToken(testIngestToken),
				WithSpoolDir(spoolDir),
				WithBatchMax(1),
				WithBatchLinger(10*time.Millisecond),
			)

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			m.wg.Add(1)
			go m.sender.run(ctx)

			m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd"}

			// Wait a bit
			time.Sleep(100 * time.Millisecond)

			cancel()
			m.wg.Wait()

			// Must be attempted exactly once
			if count := requestCount.Load(); count != 1 {
				t.Fatalf("request count = %d, want exactly 1 (never retried)", count)
			}

			// Spool directory must remain empty
			entries, _ := os.ReadDir(spoolDir)
			if len(entries) != 0 {
				t.Fatalf("spool dir has %d entries, want 0 (never spooled)", len(entries))
			}

			if m.Stats().DispatchAuthRefused != 1 {
				t.Fatalf("dispatch_auth_refused = %d, want 1", m.Stats().DispatchAuthRefused)
			}
		})
	}
}

func TestSpoolDoesNotRetryPoison400Or413(t *testing.T) {
	for _, statusCode := range []int{http.StatusBadRequest, http.StatusRequestEntityTooLarge} {
		t.Run(fmt.Sprintf("Status_%d", statusCode), func(t *testing.T) {
			var requestCount atomic.Int64
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				cnt := requestCount.Add(1)
				if cnt == 1 {
					w.WriteHeader(statusCode) // poison record
					return
				}
				w.WriteHeader(http.StatusCreated) // subsequent healthy records
			}))
			defer srv.Close()

			spoolDir := t.TempDir()
			m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
				WithBearerToken(testIngestToken),
				WithSpoolDir(spoolDir),
				WithBatchMax(1),
				WithBatchLinger(10*time.Millisecond),
			)

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			m.wg.Add(1)
			go m.sender.run(ctx)

			// Send poison record then healthy record
			m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/poison"}
			m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/healthy"}

			// Wait for both to be processed
			for i := 0; i < 50; i++ {
				if requestCount.Load() >= 2 {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}

			cancel()
			m.wg.Wait()

			if requestCount.Load() != 2 {
				t.Fatalf("request count = %d, want 2", requestCount.Load())
			}
			if m.Stats().DispatchRejected != 1 {
				t.Fatalf("dispatch_rejected = %d, want 1", m.Stats().DispatchRejected)
			}
			if m.Stats().DispatchOK != 1 {
				t.Fatalf("dispatch_ok = %d, want 1", m.Stats().DispatchOK)
			}
		})
	}
}

func TestSpoolHonoursRetryAfter(t *testing.T) {
	testCases := []struct {
		name         string
		headerValFn  func(clk Clock) string
		expectedWait time.Duration
	}{
		{
			name:         "integer seconds",
			headerValFn:  func(_ Clock) string { return "2" },
			expectedWait: 2 * time.Second,
		},
		{
			name: "http date",
			headerValFn: func(clk Clock) string {
				return clk.Now().Add(5 * time.Second).UTC().Format(http.TimeFormat)
			},
			expectedWait: 5 * time.Second,
		},
		{
			name:         "capped absurd value",
			headerValFn:  func(_ Clock) string { return "9999999" },
			expectedWait: 300 * time.Second,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			clk := newMockClock(time.Now())
			headerVal := tc.headerValFn(clk)
			var reqCount atomic.Int64

			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				cnt := reqCount.Add(1)
				if cnt == 1 {
					w.Header().Set("Retry-After", headerVal)
					w.WriteHeader(http.StatusTooManyRequests)
					return
				}
				w.WriteHeader(http.StatusCreated)
			}))
			defer srv.Close()

			spoolDir := t.TempDir()
			m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
				WithBearerToken(testIngestToken),
				WithSpoolDir(spoolDir),
				WithBatchMax(1),
				WithBatchLinger(10*time.Millisecond),
				WithClock(clk),
			)

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()

			m.wg.Add(1)
			go m.sender.run(ctx)

			m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/etc/passwd"}

			// Wait for 429 response
			waitForCond(t, 4*time.Second, nil, func() bool {
				return reqCount.Load() >= 1 && m.Stats().RetryAfterWaits >= 1
			})

			if m.Stats().RetryAfterWaits != 1 {
				t.Fatalf("retry_after_waits = %d, want 1 (reqCount=%d)", m.Stats().RetryAfterWaits, reqCount.Load())
			}

			// Advance clock past the expected wait
			clk.Advance(tc.expectedWait + 100*time.Millisecond)

			// Wait for retry
			waitForCond(t, 4*time.Second, func() { clk.Advance(1 * time.Second) }, func() bool {
				return reqCount.Load() >= 2
			})

			cancel()
			m.wg.Wait()

			if reqCount.Load() < 2 {
				t.Fatalf("request count = %d, want >= 2", reqCount.Load())
			}
		})
	}
}

func TestSenderBatchesByMaxAndLinger(t *testing.T) {
	var reqBodies [][]byte
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		reqBodies = append(reqBodies, b)
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	clk := newMockClock(time.Now())
	spoolDir := t.TempDir()

	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
		WithBatchMax(100),
		WithBatchLinger(250*time.Millisecond),
		WithClock(clk),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	m.wg.Add(1)
	go m.sender.run(ctx)

	// Send 101 observations: should flush 100 immediately by max, then 1 by linger
	for i := 0; i < 101; i++ {
		m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: fmt.Sprintf("/file-%d", i)}
	}

	// Wait for first batch of 100
	for i := 0; i < 50; i++ {
		mu.Lock()
		cnt := len(reqBodies)
		mu.Unlock()
		if cnt >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	mu.Lock()
	if len(reqBodies) != 1 {
		mu.Unlock()
		t.Fatalf("len(reqBodies) = %d, want 1 before linger", len(reqBodies))
	}
	var b1 []ingestObservation
	_ = json.Unmarshal(reqBodies[0], &b1)
	if len(b1) != 100 {
		mu.Unlock()
		t.Fatalf("batch 1 size = %d, want 100", len(b1))
	}
	mu.Unlock()

	// Advance clock past linger (250ms) to flush the remaining 1
	clk.Advance(300 * time.Millisecond)

	for i := 0; i < 50; i++ {
		mu.Lock()
		cnt := len(reqBodies)
		mu.Unlock()
		if cnt >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	m.wg.Wait()

	mu.Lock()
	defer mu.Unlock()

	if len(reqBodies) != 2 {
		t.Fatalf("total batches = %d, want 2", len(reqBodies))
	}
	var b2 []ingestObservation
	_ = json.Unmarshal(reqBodies[1], &b2)
	if len(b2) != 1 {
		t.Fatalf("batch 2 size = %d, want 1", len(b2))
	}
}

func TestSenderAppendsBehindNonEmptySpool(t *testing.T) {
	spoolDir := t.TempDir()

	// Plant an old spooled file
	stats := &pipelineStats{}
	spool, err := NewSpool(spoolDir, DefaultSpoolMaxBytes, DefaultSpoolMaxAge, realClock{}, stats)
	if err != nil {
		t.Fatalf("NewSpool: %v", err)
	}

	envOld := sampleEnvelope("old-epoch", 1, "", 1)
	if _, err := spool.WriteBatch(envOld); err != nil {
		t.Fatalf("WriteBatch: %v", err)
	}

	var reqOrder []string
	var mu sync.Mutex

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		reqOrder = append(reqOrder, r.Header.Get("X-SignalLoom-Batch-Epoch"))
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()

	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
		WithBatchMax(1),
		WithBatchLinger(10*time.Millisecond),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	m.wg.Add(1)
	go m.sender.run(ctx)

	// Send live observation
	m.queue <- TelemetryObservation{Syscall: "sys_enter_openat", Target: "/live"}

	// Wait for both to be received
	for i := 0; i < 50; i++ {
		mu.Lock()
		cnt := len(reqOrder)
		mu.Unlock()
		if cnt >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	cancel()
	m.wg.Wait()

	mu.Lock()
	defer mu.Unlock()

	if len(reqOrder) != 2 {
		t.Fatalf("reqOrder len = %d, want 2", len(reqOrder))
	}
	if reqOrder[0] != "old-epoch" {
		t.Fatalf("reqOrder[0] = %q, want 'old-epoch' (replayed first)", reqOrder[0])
	}
	if reqOrder[1] == "old-epoch" {
		t.Fatalf("reqOrder[1] = %q, want new epoch", reqOrder[1])
	}
}

func TestFreezeNotBlockedBySpool(t *testing.T) {
	// Ingest blocks indefinitely until released
	blockCh := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		<-blockCh
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	defer close(blockCh)

	frozenPodCh := make(chan string, 1)
	mockFM := NewMockFreezeManager(func(pod *corev1.Pod) error {
		frozenPodCh <- pod.Name
		return nil
	})

	spoolDir := filepath.Join(t.TempDir(), "unwritable-spool")
	_ = os.Mkdir(spoolDir, 0500)
	defer os.Chmod(spoolDir, 0700)

	pod := agentPod("fe-signalloom-agents")
	m, _ := pipelineWithOpts(t, pod, nil,
		WithBearerToken(testIngestToken),
		WithSpoolDir(spoolDir),
	)
	m.ingestURL = srv.URL
	m.freezeManager = mockFM

	// Direct freeze in handleRecord
	obs, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd"))
	if !ok {
		t.Fatal("handleRecord returned ok=false")
	}

	select {
	case name := <-frozenPodCh:
		if name != pod.Name {
			t.Fatalf("frozen pod = %s, want %s", name, pod.Name)
		}
	default:
		t.Fatal("freeze must happen synchronously in handleRecord without waiting for spool or network I/O")
	}

	if obs.DirectReaction != ReactionCgroupFrozen {
		t.Fatalf("DirectReaction = %q, want %q", obs.DirectReaction, ReactionCgroupFrozen)
	}
}
