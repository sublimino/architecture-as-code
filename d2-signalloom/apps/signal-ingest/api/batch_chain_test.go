package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

const (
	testProbeKey     = "test-static-key-32-bytes-long-random-val"
	testProbeSubject = "static-key/stun-sentinel"
	testProbeTenant  = "kusari"
)

func newTestChainRouter(t *testing.T, aw audit.AuditWriter) (*ProtectedRouter, store.SignalStore, *Handlers) {
	t.Helper()
	st := store.NewMemoryStore()
	h := &Handlers{
		Store: st,
		Audit: aw,
	}
	p := Principal{
		Subject:     testProbeSubject,
		TenantID:    testProbeTenant,
		Permissions: map[Permission]bool{
			PermissionObservationWrite: true,
			PermissionCrossTenantWrite: true,
		},
	}
	authn := staticAuthenticator{principal: p}
	router, err := NewProtectedRouter(h, authn, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatalf("failed to create protected router: %v", err)
	}
	return router, st, h
}

func makeBatchObservation(id, target string) []byte {
	return makeBatchObservationWithTenant(id, target, testProbeTenant)
}

func makeBatchObservationWithTenant(id, target, tenant string) []byte {
	obs := []model.Observation{{
		ID:              id,
		Timestamp:       time.Now().UTC(),
		Layer:           model.LayerEndpointHost,
		Fidelity:        model.FidelityStrong,
		Source:          "stun-sentinel",
		Confidence:      0.95,
		ActorID:         "kusari-agent",
		RawEvidenceRef:  "ebpf://sys_enter_openat/" + id,
		Labels: map[string]string{
			"namespace": "fe-signalloom-agents",
			"pod_name":  "agent-kusari-7d9f",
			"target":    target,
			"tenant_id": tenant,
		},
		Description: "test observation for " + target,
	}}
	b, _ := json.Marshal(obs)
	return b
}

func makeChainRequest(token string, epoch string, seq uint64, prev string, body []byte) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	if epoch != "" {
		r.Header.Set(HeaderBatchEpoch, epoch)
	}
	if seq > 0 {
		r.Header.Set(HeaderBatchSeq, fmt.Sprintf("%d", seq))
	}
	r.Header.Set(HeaderBatchPrev, prev)
	return r
}

// T1 Tests

func TestBatchChainContiguousIsAcceptedWithNoAnomaly(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	epoch := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	var prev string

	for seq := uint64(1); seq <= 5; seq++ {
		body := makeBatchObservation(fmt.Sprintf("obs-%d", seq), fmt.Sprintf("/etc/target-%d", seq))
		r := makeChainRequest(testProbeKey, epoch, seq, prev, body)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)

		if w.Code != http.StatusCreated {
			t.Fatalf("seq %d: expected status 201, got %d: %s", seq, w.Code, w.Body.String())
		}
		var resp map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("seq %d: invalid response json: %v", seq, err)
		}
		if resp["ingested"] != float64(1) {
			t.Fatalf("seq %d: expected ingested=1, got %v", seq, resp["ingested"])
		}

		sum := sha256.Sum256(body)
		prev = hex.EncodeToString(sum[:])
	}

	// First batch emits 1 epoch_started event; seq 2..5 emit ZERO anomaly events (contiguous)
	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 batch_chain audit event (epoch_started), got %d", len(events))
	}

	var detail BatchChainDetail
	if err := json.Unmarshal(events[0].Detail, &detail); err != nil {
		t.Fatalf("failed to decode audit detail: %v", err)
	}
	if detail.Outcome != OutcomeEpochStarted {
		t.Errorf("expected outcome %q, got %q", OutcomeEpochStarted, detail.Outcome)
	}

	// Verify store has all 5 observations
	q := store.Query{}
	obs, err := st.QueryRange(context.Background(), q)
	if err != nil {
		t.Fatalf("query store failed: %v", err)
	}
	if len(obs) != 5 {
		t.Fatalf("expected 5 stored observations, got %d", len(obs))
	}
}

func TestBatchChainReplayIsAuditedNotRejected(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	epoch := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	body := makeBatchObservation("obs-replay-1", "/etc/shadow")

	// 1. First send: seq 1
	r1 := makeChainRequest(testProbeKey, epoch, 1, "", body)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("first send: expected 201, got %d: %s", w1.Code, w1.Body.String())
	}

	// Store count should be 1
	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) != 1 {
		t.Fatalf("expected 1 stored observation, got %d", len(obs))
	}

	// 2. Second send: exact duplicate
	r2 := makeChainRequest(testProbeKey, epoch, 1, "", body)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("replay send: expected 201, got %d: %s", w2.Code, w2.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &resp); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if resp["ingested"] != float64(0) {
		t.Errorf("expected ingested=0, got %v", resp["ingested"])
	}
	if resp["duplicate"] != true {
		t.Errorf("expected duplicate=true, got %v", resp["duplicate"])
	}

	// Store observation count MUST NOT grow
	obs2, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs2) != 1 {
		t.Fatalf("store grew on duplicate replay! expected 1 observation, got %d", len(obs2))
	}

	// Verify replay audit event
	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 { // 1 epoch_started + 1 replayed
		t.Fatalf("expected 2 batch_chain events, got %d", len(events))
	}
	var replayDetail BatchChainDetail
	if err := json.Unmarshal(events[1].Detail, &replayDetail); err != nil {
		t.Fatalf("failed to decode detail: %v", err)
	}
	if replayDetail.Outcome != OutcomeReplayed {
		t.Errorf("expected outcome %q, got %q", OutcomeReplayed, replayDetail.Outcome)
	}
}

func TestBatchChainSameSeqDifferentBodyIsConflict(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	epoch := "cccccccccccccccccccccccccccccccc"
	bodyA := makeBatchObservation("obs-conflict-1", "/etc/passwd")
	bodyB := makeBatchObservation("obs-conflict-2", "/etc/sudoers")

	r1 := makeChainRequest(testProbeKey, epoch, 1, "", bodyA)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("first batch: expected 201, got %d", w1.Code)
	}

	r2 := makeChainRequest(testProbeKey, epoch, 1, "", bodyB)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("conflict batch: expected 201, got %d", w2.Code)
	}

	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) != 2 {
		t.Fatalf("expected 2 observations stored for conflict, got %d", len(obs))
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 { // 1 epoch_started + 1 conflict
		t.Fatalf("expected 2 batch_chain events, got %d", len(events))
	}
	var conflictDetail BatchChainDetail
	_ = json.Unmarshal(events[1].Detail, &conflictDetail)
	if conflictDetail.Outcome != OutcomeConflict {
		t.Errorf("expected outcome %q, got %q", OutcomeConflict, conflictDetail.Outcome)
	}
}

func TestBatchChainReorderIsAudited(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epoch := "dddddddddddddddddddddddddddddddd"
	body1 := makeBatchObservation("obs-1", "/etc/1")
	body2 := makeBatchObservation("obs-2", "/etc/2")
	body3 := makeBatchObservation("obs-3", "/etc/3")

	h1 := sha256.Sum256(body1)
	p1 := hex.EncodeToString(h1[:])
	h2 := sha256.Sum256(body2)
	p2 := hex.EncodeToString(h2[:])

	// Send seq 1
	r1 := makeChainRequest(testProbeKey, epoch, 1, "", body1)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("seq 1: expected 201, got %d", w1.Code)
	}

	// Send seq 3 (gap)
	r3 := makeChainRequest(testProbeKey, epoch, 3, p2, body3)
	w3 := httptest.NewRecorder()
	router.ServeHTTP(w3, r3)
	if w3.Code != http.StatusCreated {
		t.Fatalf("seq 3: expected 201, got %d", w3.Code)
	}

	// Send seq 2 (reordered / late)
	r2 := makeChainRequest(testProbeKey, epoch, 2, p1, body2)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("seq 2: expected 201, got %d", w2.Code)
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 3 { // epoch_started + gap + reordered
		t.Fatalf("expected 3 events, got %d", len(events))
	}

	var dGap, dReorder BatchChainDetail
	_ = json.Unmarshal(events[1].Detail, &dGap)
	_ = json.Unmarshal(events[2].Detail, &dReorder)

	if dGap.Outcome != OutcomeGap {
		t.Errorf("expected event 1 outcome %q, got %q", OutcomeGap, dGap.Outcome)
	}
	if dReorder.Outcome != OutcomeReordered {
		t.Errorf("expected event 2 outcome %q, got %q", OutcomeReordered, dReorder.Outcome)
	}
	if dReorder.PrevMatches == nil || !*dReorder.PrevMatches {
		t.Errorf("expected PrevMatches to be true for seq 2 checked against seq 1")
	}
}

func TestBatchChainGapIsAudited(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epoch := "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	body1 := makeBatchObservation("obs-1", "/etc/1")
	body4 := makeBatchObservation("obs-4", "/etc/4")

	h1 := sha256.Sum256(body1)
	p1 := hex.EncodeToString(h1[:])

	// Seq 1
	r1 := makeChainRequest(testProbeKey, epoch, 1, "", body1)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("seq 1: expected 201, got %d", w1.Code)
	}

	// Seq 4 (gap: missing 2-3)
	r4 := makeChainRequest(testProbeKey, epoch, 4, p1, body4)
	w4 := httptest.NewRecorder()
	router.ServeHTTP(w4, r4)
	if w4.Code != http.StatusCreated {
		t.Fatalf("seq 4: expected 201, got %d", w4.Code)
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}

	var dGap BatchChainDetail
	_ = json.Unmarshal(events[1].Detail, &dGap)
	if dGap.Outcome != OutcomeGap {
		t.Errorf("expected outcome %q, got %q", OutcomeGap, dGap.Outcome)
	}
	if dGap.MissingFrom != 2 || dGap.MissingTo != 3 {
		t.Errorf("expected missing range 2..3, got %d..%d", dGap.MissingFrom, dGap.MissingTo)
	}
	if dGap.ExpectedSeq != 2 {
		t.Errorf("expected expected_seq=2, got %d", dGap.ExpectedSeq)
	}
}

func TestBatchChainBrokenPrevIsAudited(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epoch := "ffffffffffffffffffffffffffffffff"
	body1 := makeBatchObservation("obs-1", "/etc/1")
	body2 := makeBatchObservation("obs-2", "/etc/2")

	// Seq 1
	r1 := makeChainRequest(testProbeKey, epoch, 1, "", body1)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("seq 1: expected 201, got %d", w1.Code)
	}

	// Seq 2 with wrong prev (64 hex characters of zeroes)
	wrongPrev := strings.Repeat("0", 64)
	r2 := makeChainRequest(testProbeKey, epoch, 2, wrongPrev, body2)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("seq 2: expected 201, got %d", w2.Code)
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}

	var dBroken BatchChainDetail
	_ = json.Unmarshal(events[1].Detail, &dBroken)
	if dBroken.Outcome != OutcomeBroken {
		t.Errorf("expected outcome %q, got %q", OutcomeBroken, dBroken.Outcome)
	}
	if dBroken.PrevMatches == nil || *dBroken.PrevMatches {
		t.Errorf("expected prev_matches=false, got %v", dBroken.PrevMatches)
	}
}

func TestBatchChainNewEpochIsNotAForgery(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epochOld := "11111111111111111111111111111111"
	body1 := makeBatchObservation("obs-old-1", "/etc/old")
	r1 := makeChainRequest(testProbeKey, epochOld, 1, "", body1)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("old epoch: expected 201, got %d", w1.Code)
	}

	epochNew := "22222222222222222222222222222222"
	body2 := makeBatchObservation("obs-new-1", "/etc/new")
	r2 := makeChainRequest(testProbeKey, epochNew, 1, "", body2)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("new epoch: expected 201, got %d", w2.Code)
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 {
		t.Fatalf("expected 2 events (one epoch_started per epoch), got %d", len(events))
	}
	var d1, d2 BatchChainDetail
	_ = json.Unmarshal(events[0].Detail, &d1)
	_ = json.Unmarshal(events[1].Detail, &d2)
	if d1.Outcome != OutcomeEpochStarted || d2.Outcome != OutcomeEpochStarted {
		t.Errorf("both events must be epoch_started: got %q and %q", d1.Outcome, d2.Outcome)
	}
}

func TestBatchChainSpoolReplayIsAContiguousContinuation(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epochOld := "33333333333333333333333333333333"
	epochNew := "44444444444444444444444444444444"

	// Old epoch seq 1..3
	var prevOld string
	for seq := uint64(1); seq <= 3; seq++ {
		body := makeBatchObservation(fmt.Sprintf("obs-old-%d", seq), fmt.Sprintf("/etc/old-%d", seq))
		r := makeChainRequest(testProbeKey, epochOld, seq, prevOld, body)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != http.StatusCreated {
			t.Fatalf("old seq %d: expected 201, got %d", seq, w.Code)
		}
		h := sha256.Sum256(body)
		prevOld = hex.EncodeToString(h[:])
	}

	// New epoch starts (seq 1, 2)
	bodyNew1 := makeBatchObservation("obs-new-1", "/etc/new-1")
	rNew1 := makeChainRequest(testProbeKey, epochNew, 1, "", bodyNew1)
	wNew1 := httptest.NewRecorder()
	router.ServeHTTP(wNew1, rNew1)
	if wNew1.Code != http.StatusCreated {
		t.Fatalf("new seq 1: expected 201, got %d", wNew1.Code)
	}

	// Old epoch spool replay arrives: seq 4..6 with correct prevOld
	for seq := uint64(4); seq <= 6; seq++ {
		body := makeBatchObservation(fmt.Sprintf("obs-spool-%d", seq), fmt.Sprintf("/etc/spool-%d", seq))
		r := makeChainRequest(testProbeKey, epochOld, seq, prevOld, body)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != http.StatusCreated {
			t.Fatalf("spool replay seq %d: expected 201, got %d", seq, w.Code)
		}
		h := sha256.Sum256(body)
		prevOld = hex.EncodeToString(h[:])
	}

	// Check audit events: only epoch_started for old (seq 1) and new (seq 1). No gap or reorder events!
	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 {
		t.Fatalf("expected 2 events (epoch_started only), got %d: %+v", len(events), events)
	}
	for i, e := range events {
		var d BatchChainDetail
		_ = json.Unmarshal(e.Detail, &d)
		if d.Outcome != OutcomeEpochStarted {
			t.Errorf("event %d: expected epoch_started, got %q", i, d.Outcome)
		}
	}
}

// T2 Tests

func TestBatchChainAbsentHeadersAreAcceptedAndRecorded(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	body := makeBatchObservation("obs-unchained", "/var/log/syslog")
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+testProbeKey)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201 for unchained sender, got %d: %s", w.Code, w.Body.String())
	}

	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) != 1 {
		t.Fatalf("expected 1 observation stored, got %d", len(obs))
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 1 {
		t.Fatalf("expected 1 unchained audit event, got %d", len(events))
	}
	var d BatchChainDetail
	_ = json.Unmarshal(events[0].Detail, &d)
	if d.Outcome != OutcomeUnchained {
		t.Errorf("expected outcome %q, got %q", OutcomeUnchained, d.Outcome)
	}
}

func TestBatchChainPartialOrMalformedHeaders(t *testing.T) {
	validEpoch := "55555555555555555555555555555555"
	validPrev := strings.Repeat("a", 64)
	body := makeBatchObservation("obs-malformed", "/etc/test")

	tests := []struct {
		name      string
		epoch     *string
		seq       *string
		prev      *string
		wantCode  int
		wantStored bool
	}{
		{
			name:       "all headers absent (unchained)",
			epoch:      nil,
			seq:        nil,
			prev:       nil,
			wantCode:   http.StatusCreated,
			wantStored: true,
		},
		{
			name:       "only epoch present",
			epoch:      &validEpoch,
			seq:        nil,
			prev:       nil,
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "only seq present",
			epoch:      nil,
			seq:        strPtr("1"),
			prev:       nil,
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "only prev present",
			epoch:      nil,
			seq:        nil,
			prev:       &validPrev,
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "epoch and seq present, prev absent",
			epoch:      &validEpoch,
			seq:        strPtr("1"),
			prev:       nil,
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq is 0",
			epoch:      &validEpoch,
			seq:        strPtr("0"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq is negative",
			epoch:      &validEpoch,
			seq:        strPtr("-5"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq is non-numeric",
			epoch:      &validEpoch,
			seq:        strPtr("1e3"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq above max int64",
			epoch:      &validEpoch,
			seq:        strPtr("9223372036854775808"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "epoch length not 32",
			epoch:      strPtr("55555555"),
			seq:        strPtr("1"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "epoch uppercase hex",
			epoch:      strPtr("5555555555555555555555555555555A"),
			seq:        strPtr("1"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "epoch with control chars",
			epoch:      strPtr("5555555555555555\n555555555555555"),
			seq:        strPtr("1"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq 1 with non-empty prev",
			epoch:      &validEpoch,
			seq:        strPtr("1"),
			prev:       &validPrev,
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq 2 with empty prev",
			epoch:      &validEpoch,
			seq:        strPtr("2"),
			prev:       strPtr(""),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq 2 with 63 hex chars prev",
			epoch:      &validEpoch,
			seq:        strPtr("2"),
			prev:       strPtr(strings.Repeat("a", 63)),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
		{
			name:       "seq 2 with uppercase hex prev",
			epoch:      &validEpoch,
			seq:        strPtr("2"),
			prev:       strPtr(strings.Repeat("A", 64)),
			wantCode:   http.StatusBadRequest,
			wantStored: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			aw := audit.NewFakeWriter()
			router, st, _ := newTestChainRouter(t, aw)

			r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", bytes.NewReader(body))
			r.Header.Set("Authorization", "Bearer "+testProbeKey)
			if tc.epoch != nil {
				r.Header.Set(HeaderBatchEpoch, *tc.epoch)
			}
			if tc.seq != nil {
				r.Header.Set(HeaderBatchSeq, *tc.seq)
			}
			if tc.prev != nil {
				r.Header.Set(HeaderBatchPrev, *tc.prev)
			}

			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)

			if w.Code != tc.wantCode {
				t.Errorf("expected status %d, got %d: %s", tc.wantCode, w.Code, w.Body.String())
			}

			obs, _ := st.QueryRange(context.Background(), store.Query{})
			if tc.wantStored && len(obs) != 1 {
				t.Errorf("expected observation stored, got %d", len(obs))
			} else if !tc.wantStored && len(obs) != 0 {
				t.Errorf("expected 0 observations stored on rejection, got %d", len(obs))
			}
		})
	}
}

func strPtr(s string) *string {
	return &s
}

func TestBatchChainStateIsPerKey(t *testing.T) {
	aw := audit.NewFakeWriter()
	st := store.NewMemoryStore()
	h := &Handlers{
		Store: st,
		Audit: aw,
	}

	// Router with key-dispatching authenticator
	authn := keyDispatchAuthenticator{
		keys: map[string]Principal{
			"key-a": {Subject: "static-key/probe-a", TenantID: "tenant-a", Permissions: map[Permission]bool{PermissionObservationWrite: true}},
			"key-b": {Subject: "static-key/probe-b", TenantID: "tenant-b", Permissions: map[Permission]bool{PermissionObservationWrite: true}},
		},
	}
	router, err := NewProtectedRouter(h, authn, aw, http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}

	epoch := "66666666666666666666666666666666"

	// Key A sends seq 1
	body1 := makeBatchObservationWithTenant("obs-a-1", "/etc/a", "tenant-a")
	rA1 := makeChainRequest("key-a", epoch, 1, "", body1)
	wA1 := httptest.NewRecorder()
	router.ServeHTTP(wA1, rA1)
	if wA1.Code != http.StatusCreated {
		t.Fatalf("key-a seq 1: expected 201, got %d", wA1.Code)
	}

	// Key B sends same epoch, seq 1 (should NOT conflict or replay against key A)
	body2 := makeBatchObservationWithTenant("obs-b-1", "/etc/b", "tenant-b")
	rB1 := makeChainRequest("key-b", epoch, 1, "", body2)
	wB1 := httptest.NewRecorder()
	router.ServeHTTP(wB1, rB1)
	if wB1.Code != http.StatusCreated {
		t.Fatalf("key-b seq 1: expected 201, got %d", wB1.Code)
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 2 {
		t.Fatalf("expected 2 epoch_started events, got %d", len(events))
	}

	var dA, dB BatchChainDetail
	_ = json.Unmarshal(events[0].Detail, &dA)
	_ = json.Unmarshal(events[1].Detail, &dB)

	if dA.Subject != "static-key/probe-a" || dA.Outcome != OutcomeEpochStarted {
		t.Errorf("event 0 mismatch: %+v", dA)
	}
	if dB.Subject != "static-key/probe-b" || dB.Outcome != OutcomeEpochStarted {
		t.Errorf("event 1 mismatch: %+v", dB)
	}
}

type keyDispatchAuthenticator struct {
	keys map[string]Principal
}

func (a keyDispatchAuthenticator) Authenticate(r *http.Request) (Principal, error) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return Principal{}, ErrMissingCredential
	}
	tok := strings.TrimPrefix(auth, "Bearer ")
	if p, ok := a.keys[tok]; ok {
		return p, nil
	}
	return Principal{}, ErrInvalidCredential
}

func TestBatchChainStateIsBounded(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, h := newTestChainRouter(t, aw)

	body := makeBatchObservation("obs-bounded", "/etc/test")

	for i := 0; i < 10000; i++ {
		epoch := fmt.Sprintf("%032x", i)
		r := makeChainRequest(testProbeKey, epoch, 1, "", body)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != http.StatusCreated {
			t.Fatalf("epoch %d: expected 201, got %d", i, w.Code)
		}
	}

	// Verify tracker internal epoch count is <= 8
	tracker := h.getBatchChainTracker()
	tracker.mu.Lock()
	s := tracker.subjects[testProbeSubject]
	epochCount := len(s.epochs)
	tracker.mu.Unlock()

	if epochCount > DefaultMaxEpochsPerSubject {
		t.Fatalf("expected tracked epochs <= %d, got %d", DefaultMaxEpochsPerSubject, epochCount)
	}
}

// T3 Tests

func TestBatchChainAuditRowsNameTheKeyNotTheValue(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	secretToken := "secret-bearer-token-12345678901234567890"
	epoch := "77777777777777777777777777777777"
	body := makeBatchObservation("obs-secret", "/etc/secret")

	r := makeChainRequest(secretToken, epoch, 1, "", body)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	events := aw.Events()
	if len(events) == 0 {
		t.Fatal("expected audit events to be written")
	}

	for i, e := range events {
		serialized, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(serialized, []byte(secretToken)) {
			t.Fatalf("event %d leaks secret token value in audit record: %s", i, serialized)
		}
		if !bytes.Contains(serialized, []byte(testProbeSubject)) {
			t.Fatalf("event %d missing key name / subject in audit record: %s", i, serialized)
		}
	}
}

func TestBatchChainAuditStoreDownIs503(t *testing.T) {
	fake := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, fake)

	// Now make audit sink fail
	fake.FailWith = errors.New("postgres connection failed")

	epoch := "88888888888888888888888888888888"
	body := makeBatchObservation("obs-down", "/etc/down")

	// 1. Seq 1 (epoch_started) requires audit write -> should fail with 503
	r1 := makeChainRequest(testProbeKey, epoch, 1, "", body)
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)

	if w1.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when audit sink down on anomaly, got %d: %s", w1.Code, w1.Body.String())
	}

	// Nothing stored
	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) != 0 {
		t.Fatalf("expected 0 stored observations, got %d", len(obs))
	}

	// 2. Anomaly-free batch (contiguous) with sink down:
	// Restore healthy audit to establish seq 1
	fake.FailWith = nil
	r1ok := makeChainRequest(testProbeKey, epoch, 1, "", body)
	w1ok := httptest.NewRecorder()
	router.ServeHTTP(w1ok, r1ok)
	if w1ok.Code != http.StatusCreated {
		t.Fatalf("seq 1 retry: expected 201, got %d", w1ok.Code)
	}

	// Now fail sink again, and send contiguous seq 2
	fake.FailWith = errors.New("postgres connection failed")
	sum := sha256.Sum256(body)
	prev := hex.EncodeToString(sum[:])
	body2 := makeBatchObservation("obs-down-2", "/etc/down-2")
	r2 := makeChainRequest(testProbeKey, epoch, 2, prev, body2)
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)

	// Contiguous batches emit no batch chain audit events, so contiguous succeeds with 201
	if w2.Code != http.StatusCreated {
		t.Fatalf("contiguous batch with sink down: expected 201, got %d: %s", w2.Code, w2.Body.String())
	}
}

// T4 Vector Test

func TestBatchChainVector(t *testing.T) {
	vectorData, err := os.ReadFile("testdata/batch-chain-vector.json")
	if err != nil {
		t.Fatalf("failed to read testdata/batch-chain-vector.json: %v", err)
	}

	var vector []struct {
		Seq  uint64 `json:"seq"`
		Prev string `json:"prev"`
		Body string `json:"body"`
	}
	if err := json.Unmarshal(vectorData, &vector); err != nil {
		t.Fatalf("failed to parse test vector: %v", err)
	}
	if len(vector) != 3 {
		t.Fatalf("expected 3 vector entries, got %d", len(vector))
	}

	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	epoch := "99999999999999999999999999999999"

	// Feed vector entries in order
	for i, v := range vector {
		r := makeChainRequest(testProbeKey, epoch, v.Seq, v.Prev, []byte(v.Body))
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)

		if w.Code != http.StatusCreated {
			t.Fatalf("vector entry %d (seq %d): expected 201, got %d: %s", i, v.Seq, w.Code, w.Body.String())
		}
	}

	// Check that seq 1 is epoch_started, and seq 2 & 3 are contiguous (zero anomalies)
	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 batch_chain event (epoch_started), got %d: %+v", len(events), events)
	}

	// Now re-serialise body 2 with different key ordering to mutate wire bytes and send at seq 2 on new epoch
	epochMutation := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	r1 := makeChainRequest(testProbeKey, epochMutation, 1, "", []byte(vector[0].Body))
	w1 := httptest.NewRecorder()
	router.ServeHTTP(w1, r1)
	if w1.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", w1.Code)
	}

	// Remarshal body 1 so keys might be formatted differently or mutate one byte
	var decoded []map[string]any
	_ = json.Unmarshal([]byte(vector[0].Body), &decoded)
	remarshaled, _ := json.Marshal(decoded) // indented/spaced differently from exact wire bytes

	// If client sends prev computed over remarshaled body instead of exact wire bytes:
	mutatedPrevHash := sha256.Sum256(remarshaled)
	mutatedPrev := hex.EncodeToString(mutatedPrevHash[:])

	// If mutatedPrev != expected vector[1].Prev, seq 2 should produce broken prev anomaly
	r2 := makeChainRequest(testProbeKey, epochMutation, 2, mutatedPrev, []byte(vector[1].Body))
	w2 := httptest.NewRecorder()
	router.ServeHTTP(w2, r2)
	if w2.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", w2.Code)
	}

	mutEvents := aw.EventsByType(audit.EventBatchChain)
	// Expecting: epoch_started (vector 0), epoch_started (mut 0), broken (mut 1)
	if len(mutEvents) < 3 {
		t.Fatalf("expected at least 3 events, got %d", len(mutEvents))
	}
	var dBroken BatchChainDetail
	_ = json.Unmarshal(mutEvents[len(mutEvents)-1].Detail, &dBroken)
	if dBroken.Outcome != OutcomeBroken {
		t.Errorf("expected outcome %q for mutated prev, got %q", OutcomeBroken, dBroken.Outcome)
	}

	_ = st
}

// IngestRestart / Resumed Test
func TestBatchChainIngestRestartIsResumed(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, _, _ := newTestChainRouter(t, aw)

	epoch := "abcdefabcdefabcdefabcdefabcdefab"
	body := makeBatchObservation("obs-resumed", "/etc/restart")

	// Ingest restarts: receives seq 57 of an existing epoch with prev
	dummyPrev := strings.Repeat("e", 64)
	r := makeChainRequest(testProbeKey, epoch, 57, dummyPrev, body)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", w.Code, w.Body.String())
	}

	events := aw.EventsByType(audit.EventBatchChain)
	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	var d BatchChainDetail
	_ = json.Unmarshal(events[0].Detail, &d)
	if d.Outcome != OutcomeResumed {
		t.Errorf("expected outcome %q, got %q (must not be gap)", OutcomeResumed, d.Outcome)
	}
	if d.Seq != 57 {
		t.Errorf("expected seq 57, got %d", d.Seq)
	}
}

// Oversized body limit test (413)
func TestBatchChainOversizedBodyIs413(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	// Set small limit for testing via env
	t.Setenv("SIGNAL_INGEST_MAX_BODY_BYTES", "1024")

	oversizedPayload := strings.Repeat("x", 2048)
	r := httptest.NewRequest(http.MethodPost, "/api/v1/observations", strings.NewReader(oversizedPayload))
	r.Header.Set("Authorization", "Bearer "+testProbeKey)
	r.Header.Set(HeaderBatchEpoch, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	r.Header.Set(HeaderBatchSeq, "1")
	r.Header.Set(HeaderBatchPrev, "")

	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 Payload Too Large, got %d: %s", w.Code, w.Body.String())
	}

	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) != 0 {
		t.Fatalf("expected 0 stored observations, got %d", len(obs))
	}
}

// Race test for concurrent same-key requests
func TestBatchChainConcurrentSameKey(t *testing.T) {
	aw := audit.NewFakeWriter()
	router, st, _ := newTestChainRouter(t, aw)

	epoch := "cccccccccccccccccccccccccccccccc"
	var wg sync.WaitGroup

	for i := 1; i <= 20; i++ {
		wg.Add(1)
		go func(seq int) {
			defer wg.Done()
			body := makeBatchObservation(fmt.Sprintf("obs-race-%d", seq), fmt.Sprintf("/etc/race-%d", seq))
			prev := strings.Repeat("f", 64)
			if seq == 1 {
				prev = ""
			}
			r := makeChainRequest(testProbeKey, epoch, uint64(seq), prev, body)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)
		}(i)
	}

	wg.Wait()

	obs, _ := st.QueryRange(context.Background(), store.Query{})
	if len(obs) == 0 {
		t.Fatal("expected observations to be stored under concurrent race test")
	}
}
