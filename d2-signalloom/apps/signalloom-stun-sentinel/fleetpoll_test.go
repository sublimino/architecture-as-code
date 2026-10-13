// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// fakeStunState is fleet-manager's stun-state and ack endpoints.
type fakeStunState struct {
	mu      sync.Mutex
	records []fleetStunRecord
	acks    []fleetAck
	gets    int
	ackCode int
	srv     *httptest.Server
}

func newFakeStunState(t *testing.T) *fakeStunState {
	t.Helper()
	f := &fakeStunState{ackCode: http.StatusOK}
	f.srv = httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+testStunKey {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.URL.Path == "/api/v1/fleet/stun-state":
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				w.Header().Set("Allow", "GET, HEAD")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
				return
			}
			f.gets++
			if r.URL.Query().Get("cluster_id") != "kusari-prod" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(f.records)
		case r.URL.Path == "/api/v1/fleet/stun-state/ack":
			if r.Method != http.MethodPost {
				w.Header().Set("Allow", "POST")
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusMethodNotAllowed)
				_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
				return
			}
			b, _ := io.ReadAll(r.Body)
			var ack fleetAck
			_ = json.Unmarshal(b, &ack)
			f.acks = append(f.acks, ack)
			w.WriteHeader(f.ackCode)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeStunState) set(recs ...fleetStunRecord) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.records = recs
}

func (f *fakeStunState) ackList() []fleetAck {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fleetAck(nil), f.acks...)
}

// remoteHarness is the hold harness with the pod scheduled on this node, a
// controller that reconciles synchronously on notify, and a persisted store.
type remoteHarness struct {
	*holdHarness
	fleet  *fakeStunState
	poller *fleetPoller
	spool  string
}

func newRemoteHarness(t *testing.T) *remoteHarness {
	t.Helper()
	h := newHoldHarness(t)
	h.live.Spec.NodeName = "node-a"
	h.holds.notify = func(string) { _ = h.r.reconcile(h.live.DeepCopy()) }
	spool := t.TempDir()
	h.holds.remote = newRemoteStunStore(spool)
	fleet := newFakeStunState(t)
	p := newFleetPoller(fleet.srv.URL, func() string { return testStunKey }, nil, "kusari-prod", "node-a", time.Hour, h.holds)
	p.findPod = func(ns, name string) *corev1.Pod {
		if ns == h.live.Namespace && name == h.live.Name {
			return h.live.DeepCopy()
		}
		return nil
	}
	p.sleep = func(time.Duration) {}
	p.now = func() time.Time { return time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC) }
	return &remoteHarness{holdHarness: h, fleet: fleet, poller: p, spool: spool}
}

func stunRecord(id, state string) fleetStunRecord {
	return fleetStunRecord{ID: id, ClusterID: "kusari-prod", Namespace: "fe-signalloom-agents", Name: "agent-kusari-5685ff664b-kv25k",
		Reason: "operator: suspected exfil", RequestedBy: "alice", State: state}
}

func TestRemoteStunFreezesTheNamedPodAndAcksStunned(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.set(stunRecord("st-1", stunStateRequested))
	h.poller.poll(context.Background())

	if !h.frozen() {
		t.Fatal("stun_requested must freeze the pod")
	}
	acks := h.fleet.ackList()
	if len(acks) != 1 || acks[0] != (fleetAck{ID: "st-1", State: "stunned", Node: "node-a", At: "2026-10-04T12:00:00Z"}) {
		t.Fatalf("acks = %+v", acks)
	}
	if h.holds.remoteHoldID(h.live.UID) != "st-1" {
		t.Fatal("hold must record the fleet stun id")
	}
	if _, err := os.Stat(filepath.Join(h.spool, remoteStunSubdir, holdPodUID+".json")); err != nil {
		t.Fatalf("remote hold must be persisted: %v", err)
	}

	// The next resync sees an unlabelled, frozen pod: the hold keeps it.
	if err := h.r.reconcile(h.live.DeepCopy()); err != nil {
		t.Fatal(err)
	}
	if !h.frozen() {
		t.Fatal("resync must not thaw a remote stun")
	}
	if !strings.Contains(h.log.String(), `"event":"thaw_refused_correlator_hold"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
	if strings.Contains(h.log.String(), "fleet_stun_") {
		t.Fatal("a remote stun must not be posted back as a new stun")
	}
}

func TestRemoteStunRepeatedForTheSameIdAcksWithoutANewFreeze(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.ackCode = http.StatusBadGateway
	h.fleet.set(stunRecord("st-1", stunStateRequested))
	h.poller.poll(context.Background())
	if !h.frozen() || h.poller.failures.Load() != 1 {
		t.Fatalf("frozen=%v failures=%d", h.frozen(), h.poller.failures.Load())
	}
	h.fleet.ackCode = http.StatusOK
	h.poller.poll(context.Background())
	acks := h.fleet.ackList()
	if len(acks) != 2 || acks[1].State != "stunned" || h.poller.acked.Load() != 1 {
		t.Fatalf("acks = %+v acked=%d", acks, h.poller.acked.Load())
	}
	if n := strings.Count(h.log.String(), `"event":"remote_stun_held"`); n != 1 {
		t.Fatalf("the second poll acks the standing hold without a second freeze, got %d holds:\n%s", n, h.log.String())
	}
}

func TestRemoteResumeReleasesThroughTheReconcilerAndAcksResumed(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.set(stunRecord("st-1", stunStateRequested))
	h.poller.poll(context.Background())
	if !h.frozen() {
		t.Fatal("precondition: frozen")
	}
	h.fleet.set(stunRecord("st-1", stunStateResume))
	h.poller.poll(context.Background())
	if h.frozen() {
		t.Fatal("resume_requested must thaw the pod")
	}
	if h.holds.isHeld(h.live.UID) {
		t.Fatal("hold must be released")
	}
	if h.tcDeletes == 0 {
		t.Fatal("release must go through the reconciler's network release")
	}
	acks := h.fleet.ackList()
	if len(acks) != 2 || acks[1].State != "resumed" || acks[1].ID != "st-1" {
		t.Fatalf("acks = %+v", acks)
	}
	if _, err := os.Stat(filepath.Join(h.spool, remoteStunSubdir, holdPodUID+".json")); !os.IsNotExist(err) {
		t.Fatalf("persisted hold must be removed on release: %v", err)
	}
}

func TestRemoteResumeAlsoReleasesALocalDetectionHold(t *testing.T) {
	h := newRemoteHarness(t)
	h.detect() // local correlator freeze: unrecorded, never adoptable on a remote cluster
	h.fleet.set(stunRecord("st-9", stunStateResume))
	h.poller.poll(context.Background())
	if h.frozen() || h.holds.isHeld(h.live.UID) {
		t.Fatal("fleet-manager's resume is the only release a remote cluster has")
	}
	if acks := h.fleet.ackList(); len(acks) != 1 || acks[0].State != "resumed" {
		t.Fatalf("acks = %+v", acks)
	}
}

func TestRemoteResumeWithNothingHeldAcksResumed(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.set(stunRecord("st-2", stunStateResume))
	h.poller.poll(context.Background())
	if acks := h.fleet.ackList(); len(acks) != 1 || acks[0].State != "resumed" || acks[0].ID != "st-2" {
		t.Fatalf("acks = %+v", acks)
	}
}

func TestRemoteResumeStillHeldAfterTheWaitIsLeftForTheNextPoll(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.set(stunRecord("st-1", stunStateRequested))
	h.poller.poll(context.Background())
	h.holds.notify = nil // the controller is not reconciling
	clock := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	h.poller.now = func() time.Time { clock = clock.Add(time.Second); return clock }
	h.fleet.set(stunRecord("st-1", stunStateResume))
	h.poller.poll(context.Background())
	if acks := h.fleet.ackList(); len(acks) != 1 {
		t.Fatalf("no resumed ack while the hold stands: %+v", acks)
	}
	if !strings.Contains(h.log.String(), `"event":"remote_resume_pending"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
	if !h.frozen() {
		t.Fatal("pod stays frozen until the reconciler releases it")
	}
}

func TestRemoteRecordsForOtherNodesOrClustersAreIgnored(t *testing.T) {
	h := newRemoteHarness(t)
	other := stunRecord("st-3", stunStateRequested)
	other.Name = "someone-else"
	elsewhere := stunRecord("st-4", stunStateRequested)
	elsewhere.ClusterID = "other-cluster"
	h.fleet.set(other, elsewhere)
	h.poller.poll(context.Background())
	if h.frozen() || len(h.fleet.ackList()) != 0 || h.poller.failures.Load() != 0 {
		t.Fatalf("frozen=%v acks=%+v failures=%d", h.frozen(), h.fleet.ackList(), h.poller.failures.Load())
	}
	h.live.Spec.NodeName = "node-b"
	h.fleet.set(stunRecord("st-5", stunStateRequested))
	h.poller.poll(context.Background())
	if h.frozen() || len(h.fleet.ackList()) != 0 {
		t.Fatal("a pod on another node is that node's warden's")
	}
}

func TestRemoteStunNeverTargetsTheWarden(t *testing.T) {
	h := newRemoteHarness(t)
	h.live.Spec.ServiceAccountName = wardenServiceAccount
	h.fleet.set(stunRecord("st-6", stunStateRequested))
	h.poller.poll(context.Background())
	if h.frozen() || len(h.fleet.ackList()) != 0 || h.poller.failures.Load() != 1 {
		t.Fatalf("frozen=%v acks=%+v failures=%d", h.frozen(), h.fleet.ackList(), h.poller.failures.Load())
	}
}

func TestRemoteHoldIsRestoredAfterARestart(t *testing.T) {
	h := newRemoteHarness(t)
	h.fleet.set(stunRecord("st-1", stunStateRequested))
	h.poller.poll(context.Background())

	// Restart: new holds over the same freezer and store; the kernel freeze
	// may or may not have survived, so thaw it to prove the restore re-asserts.
	if err := os.WriteFile(filepath.Join(h.cg, "cgroup.freeze"), []byte("0"), 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * time.Millisecond)
	fresh := newStunHolds(h.r.freezer)
	fresh.remote = newRemoteStunStore(h.spool)
	fresh.getPod = h.holds.getPod
	restoreRemoteHolds(fresh)
	if !fresh.isHeld(h.live.UID) || fresh.remoteHoldID(h.live.UID) != "st-1" {
		t.Fatal("persisted remote hold must be restored")
	}
	if !h.frozen() {
		t.Fatal("restore must re-assert the freeze")
	}
	h.r.holds = fresh
	if err := h.r.reconcile(h.live.DeepCopy()); err != nil {
		t.Fatal(err)
	}
	if !h.frozen() {
		t.Fatal("the first resync after a restart must not thaw a remote stun")
	}
	if !strings.Contains(h.log.String(), `"event":"remote_stun_restored"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
}

func TestRemoteHoldRestoreDropsARecordWhosePodIsGone(t *testing.T) {
	h := newRemoteHarness(t)
	store := newRemoteStunStore(h.spool)
	gone := remoteStunRecord{ID: "st-7", UID: "0f0f0f0f-1111-2222-3333-444444444444", Namespace: "x", Name: "gone", At: "2026-10-04T12:00:00Z"}
	if err := store.save(gone); err != nil {
		t.Fatal(err)
	}
	fresh := newStunHolds(h.r.freezer)
	fresh.remote = store
	restoreRemoteHolds(fresh)
	if fresh.isHeld("0f0f0f0f-1111-2222-3333-444444444444") {
		t.Fatal("a pod without a cgroup cannot be held")
	}
	if _, err := os.Stat(store.path(gone.UID)); !os.IsNotExist(err) {
		t.Fatal("stale record must be dropped")
	}
	recs, err := store.load()
	if err != nil || len(recs) != 0 {
		t.Fatalf("recs=%v err=%v", recs, err)
	}
}

func TestRemoteStunStoreSkipsMalformedFiles(t *testing.T) {
	store := newRemoteStunStore(t.TempDir())
	if err := store.save(remoteStunRecord{ID: "a", UID: "u1"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.dir, "junk.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	recs, err := store.load()
	if err == nil || len(recs) != 1 || recs[0].UID != "u1" {
		t.Fatalf("recs=%v err=%v", recs, err)
	}
	if err := store.delete("u1"); err != nil || store.delete("u1") != nil {
		t.Fatalf("delete must be idempotent: %v", err)
	}
}

func TestFleetPollFailureIsLoggedAndNeverBlocksEnforcement(t *testing.T) {
	h := newRemoteHarness(t)
	h.poller.baseURL = "http://127.0.0.1:1"
	h.poller.poll(context.Background())
	if h.poller.failures.Load() != 1 || !strings.Contains(h.log.String(), `"event":"fleet_poll_failed"`) {
		t.Fatalf("failures=%d log=%s", h.poller.failures.Load(), h.log.String())
	}
	h.detect() // the local path is unaffected
	if !h.frozen() {
		t.Fatal("local detection must still freeze")
	}
}

func TestFleetPollRunsAtStartAndEveryInterval(t *testing.T) {
	h := newRemoteHarness(t)
	h.poller.interval = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { h.poller.run(ctx); close(done) }()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		h.fleet.mu.Lock()
		n := h.fleet.gets
		h.fleet.mu.Unlock()
		if n >= 3 {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	cancel()
	<-done
	if h.fleet.gets < 3 {
		t.Fatalf("gets = %d", h.fleet.gets)
	}
}

func TestFleetStunStateHEADAndMethodGates(t *testing.T) {
	st := newFakeStunState(t)
	st.set(fleetStunRecord{ID: "test-stun-01", ClusterID: "kusari-prod", Namespace: "default", Name: "test-pod"})

	// 1. Valid HEAD request to /api/v1/fleet/stun-state returns 200, Content-Type, 0 body bytes
	headReq, err := http.NewRequest(http.MethodHead, st.srv.URL+"/api/v1/fleet/stun-state?cluster_id=kusari-prod", nil)
	if err != nil {
		t.Fatalf("failed creating HEAD request: %v", err)
	}
	headReq.Header.Set("Authorization", "Bearer "+testStunKey)
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	headBody, err := io.ReadAll(headResp.Body)
	_ = headResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading HEAD body: %v", err)
	}
	if headResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK on HEAD, got %d", headResp.StatusCode)
	}
	if len(headBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD, got %d bytes: %q", len(headBody), string(headBody))
	}
	if ct := headResp.Header.Get("Content-Type"); ct != "application/json" {
		t.Fatalf("expected Content-Type application/json, got %q", ct)
	}

	// 2. Unsupported POST on stun-state route returns 405 Method Not Allowed with Allow: GET, HEAD
	postReq, err := http.NewRequest(http.MethodPost, st.srv.URL+"/api/v1/fleet/stun-state", nil)
	if err != nil {
		t.Fatalf("failed creating POST request: %v", err)
	}
	postReq.Header.Set("Authorization", "Bearer "+testStunKey)
	postResp, err := http.DefaultClient.Do(postReq)
	if err != nil {
		t.Fatalf("POST request failed: %v", err)
	}
	_ = postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed on POST, got %d", postResp.StatusCode)
	}
	if allow := postResp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("expected Allow: GET, HEAD, got %q", allow)
	}

	// 3. HEAD on ack endpoint (POST-only) returns 405 with Allow: POST and 0 body bytes
	headAckReq, err := http.NewRequest(http.MethodHead, st.srv.URL+"/api/v1/fleet/stun-state/ack", nil)
	if err != nil {
		t.Fatalf("failed creating HEAD ack request: %v", err)
	}
	headAckReq.Header.Set("Authorization", "Bearer "+testStunKey)
	headAckResp, err := http.DefaultClient.Do(headAckReq)
	if err != nil {
		t.Fatalf("HEAD ack request failed: %v", err)
	}
	ackBody, err := io.ReadAll(headAckResp.Body)
	_ = headAckResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading HEAD ack body: %v", err)
	}
	if headAckResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed on HEAD ack, got %d", headAckResp.StatusCode)
	}
	if allow := headAckResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if len(ackBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD ack 405, got %d: %q", len(ackBody), string(ackBody))
	}
}
