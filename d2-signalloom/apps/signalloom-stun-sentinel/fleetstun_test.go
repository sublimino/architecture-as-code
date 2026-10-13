// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode"
	"unicode/utf8"

	corev1 "k8s.io/api/core/v1"
)

const testStunKey = "fleet-stun-key-0123456789abcdef"

type stunCall struct{ path, auth, reason string }

// fakeFleet records every stun POST and answers with the queued statuses
// (the last one repeats).
type fakeFleet struct {
	mu       sync.Mutex
	calls    []stunCall
	statuses []int
	srv      *httptest.Server
}

func newFakeFleet(t *testing.T, statuses ...int) *fakeFleet {
	t.Helper()
	f := &fakeFleet{statuses: statuses}
	f.srv = httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		b, _ := io.ReadAll(r.Body)
		var body struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(b, &body)
		f.mu.Lock()
		f.calls = append(f.calls, stunCall{path: r.URL.Path, auth: r.Header.Get("Authorization"), reason: body.Reason})
		status := f.statuses[len(f.statuses)-1]
		if len(f.calls) <= len(f.statuses) {
			status = f.statuses[len(f.calls)-1]
		}
		f.mu.Unlock()
		w.WriteHeader(status)
	})))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeFleet) snapshot() []stunCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]stunCall(nil), f.calls...)
}

// wireStunner connects a stunner to the harness's holds. Each finished
// delivery (success or give-up) is signalled on the returned channel, so a test
// asserts only after the goroutine freezeFor started has completed.
func wireStunner(h *holdHarness, url, key string) (*fleetStunner, <-chan struct{}) {
	st := newFleetStunner(url, func() string { return key }, nil)
	st.backoff = func(int) time.Duration { return 0 }
	st.stillHeld = h.holds.awaitingRecord
	done := make(chan struct{}, 8)
	h.holds.recordStun = func(p *corev1.Pod, reason string) { st.stun(p, reason); done <- struct{}{} }
	return st, done
}

// detectAndWait runs a correlator freeze and waits for its stun delivery.
func (h *holdHarness) detectAndWait(done <-chan struct{}) {
	h.t.Helper()
	h.detect()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		h.t.Fatal("the stun delivery never finished")
	}
}

func TestANewCorrelatorFreezeIsStunnedThroughFleetManagerExactlyOnce(t *testing.T) {
	h := newHoldHarness(t)
	fleet := newFakeFleet(t, http.StatusOK)
	_, done := wireStunner(h, fleet.srv.URL, testStunKey)
	h.detectAndWait(done)
	h.detect() // a second sensitive syscall under the same hold
	select {
	case <-done:
		t.Fatal("a second detection under the same hold started a second stun")
	case <-time.After(50 * time.Millisecond):
	}

	calls := fleet.snapshot()
	if len(calls) != 1 {
		t.Fatalf("fleet-manager saw %d stun calls for one hold; want exactly 1", len(calls))
	}
	want := stunCall{path: "/api/v1/fleet/stun/" + h.live.Name, auth: "Bearer " + testStunKey,
		reason: "signalloom-warden detection: sys_enter_openat /etc/passwd"}
	if calls[0] != want {
		t.Fatalf("stun call = %+v\nwant         %+v", calls[0], want)
	}
	if !h.frozen() {
		t.Fatal("the freeze must hold whatever fleet-manager does")
	}
}

func TestARefusedStunIsLoudNotRetriedAndTheFreezeHolds(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound} {
		h := newHoldHarness(t)
		fleet := newFakeFleet(t, status)
		st, done := wireStunner(h, fleet.srv.URL, testStunKey)
		h.detectAndWait(done)
		if n := len(fleet.snapshot()); n != 1 {
			t.Fatalf("%d: %d calls; a refusal is not retried", status, n)
		}
		if st.failures.Load() != 1 || !strings.Contains(h.log.String(), `"event":"fleet_stun_failed"`) {
			t.Fatalf("%d: failures=%d, log:\n%s", status, st.failures.Load(), h.log.String())
		}
		h.reconcile(h.live.DeepCopy())
		if !h.frozen() {
			t.Fatalf("%d: a refused stun record let the reconciler thaw the pod", status)
		}
	}
}

func TestATransientFleetFailureIsRetriedUntilDelivered(t *testing.T) {
	h := newHoldHarness(t)
	fleet := newFakeFleet(t, http.StatusServiceUnavailable, http.StatusBadGateway, http.StatusOK)
	st, done := wireStunner(h, fleet.srv.URL, testStunKey)
	h.detectAndWait(done)
	if n, d := len(fleet.snapshot()), st.delivered.Load(); n != 3 || d != 1 {
		t.Fatalf("%d calls, %d delivered; want 3 calls and one delivery", n, d)
	}
}

func TestRetriesStopOnceTheStunIsRecorded(t *testing.T) {
	h := newHoldHarness(t)
	fleet := newFakeFleet(t, http.StatusServiceUnavailable)
	st := newFleetStunner(fleet.srv.URL, func() string { return testStunKey }, nil)
	st.stillHeld = h.holds.awaitingRecord
	st.backoff = func(int) time.Duration {
		h.reconcile(h.setLabels(stunTriple)) // the record lands between attempts
		return 0
	}
	h.detect()
	st.stun(h.live.DeepCopy(), "signalloom-warden detection: sys_enter_openat /etc/passwd")
	if n := len(fleet.snapshot()); n != 1 {
		t.Fatalf("%d calls; retries must stop once the pod is seen stunned", n)
	}
}

func TestAnUnconfiguredStunnerHoldsTheFreezeAndSaysSo(t *testing.T) {
	h := newHoldHarness(t)
	st, done := wireStunner(h, "", testStunKey)
	h.detectAndWait(done)
	if st.failures.Load() != 1 || !strings.Contains(h.log.String(), `"kind":"unconfigured"`) {
		t.Fatalf("failures=%d, log:\n%s", st.failures.Load(), h.log.String())
	}
	if !h.frozen() {
		t.Fatal("an unconfigured stunner thawed the pod")
	}
}

// A missing key is not an unconfigured stunner: it is waited for across the
// attempts (keys.go) and the freeze is held throughout.
func TestAMissingKeyIsWaitedForNotTreatedAsUnconfigured(t *testing.T) {
	h := newHoldHarness(t)
	st, done := wireStunner(h, "http://fleet-manager:8082", "")
	h.detectAndWait(done)
	if n := strings.Count(h.log.String(), `"kind":"key_missing"`); n != fleetStunMaxAttempts {
		t.Fatalf("want %d key_missing retries, got %d:\n%s", fleetStunMaxAttempts, n, h.log.String())
	}
	if strings.Contains(h.log.String(), `"kind":"unconfigured"`) || !strings.Contains(h.log.String(), `"kind":"exhausted"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
	if st.failures.Load() != fleetStunMaxAttempts+1 || !h.frozen() {
		t.Fatalf("failures=%d frozen=%v", st.failures.Load(), h.frozen())
	}
}

func TestTheStunKeyNeverReachesTheLog(t *testing.T) {
	h := newHoldHarness(t)
	fleet := newFakeFleet(t, http.StatusUnauthorized)
	_, done := wireStunner(h, fleet.srv.URL, testStunKey)
	h.detectAndWait(done)
	if strings.Contains(h.log.String(), testStunKey) {
		t.Fatalf("the stun key was logged:\n%s", h.log.String())
	}
}

func TestAHostileTargetBecomesAReasonFleetManagerAccepts(t *testing.T) {
	got := stunReasonFor("sys_enter_openat", "/etc/passwd\n\x1b[31m‮"+strings.Repeat("x", 1000))
	if utf8.RuneCountInString(got) != fleetStunMaxReason {
		t.Fatalf("reason has %d runes, want the %d cap", utf8.RuneCountInString(got), fleetStunMaxReason)
	}
	for _, r := range got {
		if !unicode.IsPrint(r) {
			t.Fatalf("reason keeps non-printable %U, which fleet-manager rejects with 400: %q", r, got)
		}
	}
}

// A fleet key that has not arrived is waited for while the hold stands, not
// reported as unconfigured; the delivery lands once it does.
func TestFleetStunWaitsForALateKey(t *testing.T) {
	fleet := newFakeFleet(t, http.StatusOK)
	var log bytes.Buffer
	SetAuditOutput(&log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })
	var mu sync.Mutex
	key := ""
	calls := 0
	st := newFleetStunner(fleet.srv.URL, func() string { mu.Lock(); defer mu.Unlock(); return key }, nil)
	st.backoff = func(int) time.Duration {
		mu.Lock()
		defer mu.Unlock()
		calls++
		if calls == 2 {
			key = testStunKey
		}
		return 0
	}
	st.stun(&corev1.Pod{}, "r")
	got := fleet.snapshot()
	if len(got) != 1 || got[0].auth != "Bearer "+testStunKey {
		t.Fatalf("calls = %+v", got)
	}
	if n := strings.Count(log.String(), `"kind":"key_missing"`); n != 2 {
		t.Fatalf("want two key_missing retries, got %d:\n%s", n, log.String())
	}
	if strings.Contains(log.String(), "unconfigured") {
		t.Fatal("a late key is not an unconfigured stunner")
	}
}

func TestFakeFleetHEADAndMethodGates(t *testing.T) {
	fl := newFakeFleet(t, http.StatusOK)

	// 1. HEAD request on POST-only fleet endpoint returns 405 Method Not Allowed with Allow: POST and 0 body bytes
	headReq, err := http.NewRequest(http.MethodHead, fl.srv.URL+"/api/v1/fleet/stun", nil)
	if err != nil {
		t.Fatalf("failed creating HEAD request: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	headBody, err := io.ReadAll(headResp.Body)
	_ = headResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading HEAD body: %v", err)
	}
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed on HEAD, got %d", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if len(headBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD 405, got %d: %q", len(headBody), string(headBody))
	}

	// 2. GET request returns 405 with Allow: POST and non-empty error body
	getReq, err := http.NewRequest(http.MethodGet, fl.srv.URL+"/api/v1/fleet/stun", nil)
	if err != nil {
		t.Fatalf("failed creating GET request: %v", err)
	}
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET request failed: %v", err)
	}
	getBody, err := io.ReadAll(getResp.Body)
	_ = getResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading GET body: %v", err)
	}
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 on GET, got %d", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if len(getBody) == 0 {
		t.Fatal("expected non-empty body on GET 405")
	}
}
