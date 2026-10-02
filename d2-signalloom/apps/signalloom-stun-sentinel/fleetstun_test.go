// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
	}))
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
	st := newFleetStunner(url, key)
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
		reason: "stun-sentinel detection: sys_enter_openat /etc/passwd"}
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
	st := newFleetStunner(fleet.srv.URL, testStunKey)
	st.stillHeld = h.holds.awaitingRecord
	st.backoff = func(int) time.Duration {
		h.reconcile(h.setLabels(stunTriple)) // the record lands between attempts
		return 0
	}
	h.detect()
	st.stun(h.live.DeepCopy(), "stun-sentinel detection: sys_enter_openat /etc/passwd")
	if n := len(fleet.snapshot()); n != 1 {
		t.Fatalf("%d calls; retries must stop once the pod is seen stunned", n)
	}
}

func TestAnUnconfiguredStunnerHoldsTheFreezeAndSaysSo(t *testing.T) {
	for _, cfg := range [][2]string{{"", testStunKey}, {"http://fleet-manager:8082", ""}} {
		h := newHoldHarness(t)
		st, done := wireStunner(h, cfg[0], cfg[1])
		h.detectAndWait(done)
		if st.failures.Load() != 1 || !strings.Contains(h.log.String(), `"kind":"unconfigured"`) {
			t.Fatalf("cfg %q: failures=%d, log:\n%s", cfg, st.failures.Load(), h.log.String())
		}
		if !h.frozen() {
			t.Fatal("an unconfigured stunner thawed the pod")
		}
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
