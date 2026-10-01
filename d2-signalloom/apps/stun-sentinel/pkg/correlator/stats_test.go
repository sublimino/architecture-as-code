// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

// The correlator had no logging and dropped records at five places without a
// trace, so on a live node (2026-10-01) a provoked /etc/passwd read produced no
// observation and nothing said which stage discarded it. Each stage now counts,
// so the drop point is a number rather than a guess.

func TestStatsCountEachDropPointInHandleRecord(t *testing.T) {
	m, _ := pipeline(t, agentPod("tenant-kusari"), nil)

	m.handleRecord([]byte{1, 2, 3})                                           // undecodable
	m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/tmp/harmless"))        // not sensitive
	m.handleRecord(rawRecord(ebpf.EventOpenat, 4242, "/etc/passwd"))          // no such pid -> no pod
	_, ok := m.handleRecord(rawRecord(ebpf.EventOpenat, 1001, "/etc/passwd")) // full match
	if !ok {
		t.Fatal("the sensitive open by the agent pod must produce an observation")
	}

	s := m.Stats()
	if s.DecodeErrors != 1 || s.NotSensitive != 1 || s.NoPod != 1 || s.Matched != 1 {
		t.Fatalf("stats = %+v, want decode=1 notSensitive=1 noPod=1 matched=1", s)
	}
}

func TestStatsRecordDispatchFailureInsteadOfSwallowingIt(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil)

	m.recordDispatch(m.dispatchObservation(TelemetryObservation{}))

	s := m.Stats()
	if s.DispatchErrors != 1 || s.DispatchOK != 0 {
		t.Fatalf("stats = %+v, want exactly one dispatch error", s)
	}
	if !strings.Contains(s.LastDispatchError, "401") {
		t.Fatalf("last dispatch error %q must name the status, so a 401 is visible in the logs", s.LastDispatchError)
	}
}

func TestStatsRecordDispatchSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil)

	m.recordDispatch(m.dispatchObservation(TelemetryObservation{}))

	if s := m.Stats(); s.DispatchOK != 1 || s.DispatchErrors != 0 || s.LastDispatchError != "" {
		t.Fatalf("stats = %+v, want exactly one success and no error", s)
	}
}

func TestDispatchWorkerCountsFailuresItUsedToDiscard(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	m := NewSentinelProbeManager(NewMockSharedIndexInformer(), srv.URL, nil)

	m.queue <- TelemetryObservation{}
	close(m.queue)
	m.wg.Add(1)
	m.dispatchWorker(context.Background())

	if s := m.Stats(); s.DispatchErrors != 1 {
		t.Fatalf("the worker must count the 401 it receives, stats = %+v", s)
	}
}
