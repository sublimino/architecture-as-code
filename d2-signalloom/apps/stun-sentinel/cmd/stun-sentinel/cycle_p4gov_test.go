// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build linux

// Phase-4 Governor (SLER-P4-GOV) end-to-end freeze-plane cycle tests.
//
// P4-1, P4-2 and P4-3 each ship their own unit tests, and each passes. What no
// card tested is the path this phase actually built: freeze an agent, capture
// its forensic snapshot while it is confirmed frozen, lose the workload, and
// then resume it under an attributable governance token. A freeze/unfreeze test
// with nothing in between re-verifies P1-4's work, not P4-2's or P4-3's.
//
// These tests drive the real HTTP surface (routes(), requireBearer, handleStun,
// handleResume) against a real live process, so the snapshot is taken of an
// actual /proc entry rather than a fixture.
package main

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/auth"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/quarantine"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
)

// ─────────────────────────────────────────────────────────────────────────────
// Harness
// ─────────────────────────────────────────────────────────────────────────────

// spawnCycleTarget starts a real, long-lived child process so the quarantine
// capturer reads a genuine /proc/<pid> tree rather than a fixture. The snapshot
// half of the cycle is worthless against a synthetic PID.
func spawnCycleTarget(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sleep", "120")
	if err := cmd.Start(); err != nil {
		t.Fatalf("spawn cycle target: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	// Wait for /proc/<pid>/maps to be readable before anyone tries to capture it.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(fmt.Sprintf("/proc/%d/maps", cmd.Process.Pid)); err == nil {
			return cmd
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("cycle target pid %d never became visible in /proc", cmd.Process.Pid)
	return nil
}

// mockPodCgroupWithPIDs mirrors mockPodCgroup but publishes real PIDs in
// cgroup.procs, which is what drives FreezeResult.PIDs and therefore whether
// the quarantine capturer fires at all.
func mockPodCgroupWithPIDs(t *testing.T, root string, podUIDUnderscored string, pids ...int) string {
	t.Helper()
	dir := filepath.Join(root, "kubepods.slice", "kubepods-besteffort.slice",
		"kubepods-besteffort-pod"+podUIDUnderscored+".slice")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var procs strings.Builder
	for _, p := range pids {
		fmt.Fprintf(&procs, "%d\n", p)
	}
	for name, body := range map[string]string{
		"cgroup.freeze": "1",
		"cgroup.events": "populated 1\nfrozen 1\n",
		"cgroup.procs":  procs.String(),
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// emulateKernelThaw makes the mock hierarchy behave the way the kernel does on
// the unfreeze half of the cycle.
//
// cgroup.events is a kernel-maintained file: writing "0" to cgroup.freeze
// causes the kernel to flip "frozen 1" to "frozen 0" there. A plain file on
// tmpfs never flips, so the freezer's convergence poll correctly reports
// ErrAncestorFrozen ("cgroup.freeze=0 but cgroup.events still reports frozen
// 1"). That diagnostic is the engine working as designed — it is the ancestor
// check P4-PRE §2.2 item 5 listed as a capability the naive freezer lacked —
// so the fixture, not the product, is what has to move.
func emulateKernelThaw(t *testing.T, cgroupDir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(cgroupDir, "cgroup.events"),
		[]byte("populated 1\nfrozen 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newCycleServer wires the full phase-4 freeze plane: P4-1's unified engine,
// P4-2's quarantine capturer, P4-3's operator key registry and replay ledger.
func newCycleServer(t *testing.T, root string, reg auth.OperatorKeyRegistry, capCfg quarantine.CaptureConfig) (*server, *bytes.Buffer, *quarantine.Capturer) {
	t.Helper()
	buf := &bytes.Buffer{}
	freezeValidate := constantTimeTokenValidator("freeze-token-p4gov")
	policy := auth.DefaultResumeTokenPolicy("osramp-fleet", "sler-root-2026")
	resumeValidate := ed25519ResumeValidator(reg, policy, "")
	capturer := quarantine.New(capCfg)

	srv := &server{
		freezer: cgroup.New(root,
			cgroup.WithDeadline(2*time.Second),
			cgroup.WithFreezeCredentialValidator(freezeValidate),
			cgroup.WithCredentialValidator(resumeValidate),
			cgroup.WithQuarantineCapturer(capturer),
		),
		emitter:        telemetry.NewEmitter(buf),
		capturer:       capturer,
		freezeValidate: freezeValidate,
		resumeValidate: resumeValidate,
		keyRegistry:    reg,
		policy:         policy,
		replayLedger:   auth.NewReplayLedger(),
	}
	return srv, buf, capturer
}

func newCycleOperator(t *testing.T, opID string) (auth.OperatorKeyRegistry, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	reg := auth.NewStaticOperatorKeyRegistry(auth.OperatorKeyEntry{
		OperatorID: opID,
		KeyID:      auth.ComputeKeyID(pub),
		PublicKey:  pub,
	})
	return reg, priv
}

// emittedEvents parses the JSONL telemetry stream into generic maps so the
// tests can assert on the wire shape, not on the Go struct.
func emittedEvents(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	sc := bufio.NewScanner(bytes.NewReader(buf.Bytes()))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("telemetry line is not valid JSON: %q: %v", line, err)
		}
		out = append(out, ev)
	}
	return out
}

func eventsNamed(evs []map[string]any, name string) []map[string]any {
	var out []map[string]any
	for _, e := range evs {
		if e["event"] == name {
			out = append(out, e)
		}
	}
	return out
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. The cycle this phase actually built: stun -> snapshot -> unstun
// ─────────────────────────────────────────────────────────────────────────────

func TestP4GovCycleStunSnapshotUnstunEndToEnd(t *testing.T) {
	target := spawnCycleTarget(t)
	pid := target.Process.Pid

	root := t.TempDir()
	storage := t.TempDir()
	cgDir := mockPodCgroupWithPIDs(t, root, uidUnderscored, pid)

	opID := "spiffe://signalloom.demo/operator/alice"
	reg, priv := newCycleOperator(t, opID)

	srv, telem, capturer := newCycleServer(t, root, reg, quarantine.CaptureConfig{
		StorageDir:         storage,
		MaxMemorySizeBytes: 32 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})
	h := srv.routes()

	// ── Step 1: STUN ────────────────────────────────────────────────────────
	stunBody := fmt.Sprintf(
		`{"pod_uid":%q,"pod":"agent-payment-audit","namespace":"fe-signalloom-agents","capture_quarantine":true}`, uid)
	rec := postJSON(t, h, "/stun", stunBody, authHeader("freeze-token-p4gov"))
	if rec.Code != http.StatusOK {
		t.Fatalf("stun: want 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// ── Step 2: SNAPSHOT captured during the freeze, not after ─────────────
	snapshots, err := capturer.ListSnapshots()
	if err != nil {
		t.Fatalf("ListSnapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("want exactly 1 forensic snapshot captured by the stun path, got %d", len(snapshots))
	}
	snap := snapshots[0]
	if snap.Target.PodUID != uid {
		t.Errorf("snapshot bound to wrong pod: got %q want %q", snap.Target.PodUID, uid)
	}
	if len(snap.Processes) == 0 {
		t.Fatal("snapshot recorded no processes: the capture did not observe the frozen workload")
	}
	foundPID := false
	for _, p := range snap.Processes {
		if p.PID == pid {
			foundPID = true
		}
	}
	if !foundPID {
		t.Errorf("snapshot does not contain the frozen target pid %d", pid)
	}

	// ── Step 3: pod deletion — the snapshot must outlive the workload ──────
	_ = target.Process.Kill()
	_, _ = target.Process.Wait()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(fmt.Sprintf("/proc/%d/maps", pid)); err != nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	if _, err := os.Stat(filepath.Join(snap.StoragePath, "manifest.json")); err != nil {
		t.Fatalf("manifest.json did not survive pod deletion: %v", err)
	}
	reloaded, err := capturer.GetSnapshot(snap.CaptureID)
	if err != nil {
		t.Fatalf("snapshot unreadable after pod deletion: %v", err)
	}
	if reloaded.Target.PodUID != uid {
		t.Errorf("reloaded snapshot lost its target binding: %q", reloaded.Target.PodUID)
	}

	// The unauthenticated read surface is a governor finding, not a pass
	// condition; assert only that the persisted record is the same one.
	if reloaded.CaptureID != snap.CaptureID {
		t.Errorf("GetSnapshot returned a different capture: %q vs %q", reloaded.CaptureID, snap.CaptureID)
	}

	// ── Step 4: UNSTUN under a valid Ed25519 governance token ──────────────
	signed := makeSignedTestToken(t, opID, priv, "agent-payment-audit", "fe-signalloom-agents")
	tokenJSON, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}
	resumeBody := fmt.Sprintf(
		`{"pod_uid":%q,"pod":"agent-payment-audit","namespace":"fe-signalloom-agents","agent_id":"agent-payment-audit","idempotency_key":"idem-p4gov-001","token":%s}`,
		uid, tokenJSON)
	emulateKernelThaw(t, cgDir)
	rec = postJSON(t, h, "/resume", resumeBody, authHeader(string(tokenJSON)))
	if rec.Code != http.StatusOK {
		t.Fatalf("resume: want 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resumeResp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resumeResp); err != nil {
		t.Fatalf("resume response not JSON: %v", err)
	}

	// ── Step 5: attribution actually recorded ──────────────────────────────
	ops, _ := resumeResp["operator_ids"].([]any)
	if len(ops) == 0 || ops[0] != opID {
		t.Fatalf("resume was not attributed to the signing operator: %#v", resumeResp["operator_ids"])
	}
	if resumeResp["token_id"] == "" || resumeResp["token_id"] == nil {
		t.Error("resume response carries no token_id: the decision is not traceable to a token")
	}

	evs := emittedEvents(t, telem)
	halted := eventsNamed(evs, telemetry.EventStunExecutionHalted)
	resumed := eventsNamed(evs, telemetry.EventStunExecutionResumed)
	if len(halted) != 1 {
		t.Errorf("want 1 %s event, got %d", telemetry.EventStunExecutionHalted, len(halted))
	}
	if len(resumed) != 1 {
		t.Fatalf("want 1 %s event, got %d", telemetry.EventStunExecutionResumed, len(resumed))
	}
	gotOps, _ := resumed[0]["operator_ids"].([]any)
	if len(gotOps) == 0 || gotOps[0] != opID {
		t.Errorf("resume telemetry is unattributed: %#v", resumed[0]["operator_ids"])
	}
	if resumed[0]["token_id"] == nil || resumed[0]["token_id"] == "" {
		t.Error("resume telemetry carries no token_id")
	}

	// A quarantine event must accompany the freeze, or P5-1 has nothing to attest.
	quarEvents := append(
		eventsNamed(evs, telemetry.EventQuarantineSnapshotCaptured),
		eventsNamed(evs, telemetry.EventQuarantineSnapshotPartial)...)
	if len(quarEvents) == 0 {
		t.Error("no QuarantineSnapshot* event emitted alongside the freeze")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Over-budget capture must degrade to a reported partial, never hang
// ─────────────────────────────────────────────────────────────────────────────

func TestP4GovCycleUnderOverBudgetSnapshotReportsPartialAndCompletes(t *testing.T) {
	target := spawnCycleTarget(t)
	pid := target.Process.Pid

	root := t.TempDir()
	storage := t.TempDir()
	cgDir := mockPodCgroupWithPIDs(t, root, uidUnderscored, pid)

	opID := "spiffe://signalloom.demo/operator/bob"
	reg, priv := newCycleOperator(t, opID)

	// A 1-byte memory budget guarantees the dump loop trips its ceiling on the
	// first region. This is P4-2's abort path, exercised inside the full cycle
	// rather than in isolation.
	srv, telem, capturer := newCycleServer(t, root, reg, quarantine.CaptureConfig{
		StorageDir:         storage,
		MaxMemorySizeBytes: 1,
		MaxTimeBudget:      1 * time.Nanosecond,
		DumpAnonymousOnly:  true,
	})
	h := srv.routes()

	done := make(chan struct{})
	var stunCode int
	var stunBody string
	go func() {
		defer close(done)
		rec := postJSON(t, h, "/stun", fmt.Sprintf(
			`{"pod_uid":%q,"pod":"agent-overbudget","namespace":"fe-signalloom-agents","capture_quarantine":true}`, uid),
			authHeader("freeze-token-p4gov"))
		stunCode = rec.Code
		stunBody = rec.Body.String()
	}()

	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("stun with an over-budget snapshot hung: the cycle must report partial, not block")
	}

	if stunCode != http.StatusOK {
		t.Fatalf("over-budget stun: want 200 with a partial result, got %d: %s", stunCode, stunBody)
	}

	snapshots, err := capturer.ListSnapshots()
	if err != nil {
		t.Fatalf("ListSnapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("want 1 partial snapshot persisted, got %d", len(snapshots))
	}
	if !snapshots[0].Partial {
		t.Error("over-budget capture was not marked Partial: a truncated snapshot reads as complete")
	}
	if snapshots[0].PartialReason == "" {
		t.Error("Partial snapshot carries no machine-readable PartialReason")
	}

	// The cycle must still complete: resume has to work after a partial capture.
	signed := makeSignedTestToken(t, opID, priv, "agent-overbudget", "fe-signalloom-agents")
	tokenJSON, _ := json.Marshal(signed)
	emulateKernelThaw(t, cgDir)
	rec := postJSON(t, h, "/resume", fmt.Sprintf(
		`{"pod_uid":%q,"pod":"agent-overbudget","namespace":"fe-signalloom-agents","agent_id":"agent-overbudget","idempotency_key":"idem-p4gov-partial","token":%s}`,
		uid, tokenJSON), authHeader(string(tokenJSON)))
	if rec.Code != http.StatusOK {
		t.Fatalf("resume after partial capture: want 200, got %d: %s", rec.Code, rec.Body.String())
	}

	evs := emittedEvents(t, telem)
	if len(eventsNamed(evs, telemetry.EventQuarantineSnapshotPartial)) == 0 {
		t.Errorf("no %s event emitted for an over-budget capture", telemetry.EventQuarantineSnapshotPartial)
	}
	if len(eventsNamed(evs, telemetry.EventStunExecutionResumed)) != 1 {
		t.Error("resume did not complete after a partial forensic capture")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Concurrent nodes each freezing and snapshotting at once
// ─────────────────────────────────────────────────────────────────────────────

func TestP4GovConcurrentMultiNodeFreezeAndSnapshot(t *testing.T) {
	const nodes = 4

	type result struct {
		idx     int
		code    int
		snapIDs []string
		err     error
	}

	results := make([]result, nodes)
	var wg sync.WaitGroup
	start := make(chan struct{})

	for i := 0; i < nodes; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			target := spawnCycleTarget(t)
			pid := target.Process.Pid

			root := t.TempDir()
			storage := t.TempDir()
			mockPodCgroupWithPIDs(t, root, uidUnderscored, pid)

			opID := fmt.Sprintf("spiffe://signalloom.demo/operator/node-%d", i)
			reg, _ := newCycleOperator(t, opID)
			srv, _, capturer := newCycleServer(t, root, reg, quarantine.CaptureConfig{
				StorageDir:         storage,
				MaxMemorySizeBytes: 16 * 1024 * 1024,
				MaxTimeBudget:      5 * time.Second,
				DumpAnonymousOnly:  true,
			})
			h := srv.routes()

			<-start // release all nodes simultaneously

			rec := postJSON(t, h, "/stun", fmt.Sprintf(
				`{"pod_uid":%q,"pod":"agent-node-%d","namespace":"fe-signalloom-agents","capture_quarantine":true}`, uid, i),
				authHeader("freeze-token-p4gov"))

			snaps, err := capturer.ListSnapshots()
			ids := make([]string, 0, len(snaps))
			for _, s := range snaps {
				ids = append(ids, s.CaptureID)
			}
			results[i] = result{idx: i, code: rec.Code, snapIDs: ids, err: err}
		}(i)
	}

	close(start)

	finished := make(chan struct{})
	go func() { wg.Wait(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(90 * time.Second):
		t.Fatal("concurrent freeze+snapshot across nodes did not converge: resource contention or deadlock")
	}

	seen := map[string]int{}
	for _, r := range results {
		if r.err != nil {
			t.Errorf("node %d: ListSnapshots: %v", r.idx, r.err)
			continue
		}
		if r.code != http.StatusOK {
			t.Errorf("node %d: stun returned %d under concurrent load", r.idx, r.code)
		}
		if len(r.snapIDs) != 1 {
			t.Errorf("node %d: want exactly 1 snapshot, got %d", r.idx, len(r.snapIDs))
		}
		for _, id := range r.snapIDs {
			seen[id]++
		}
	}
	for id, n := range seen {
		if n > 1 {
			t.Errorf("capture id %q collided across %d concurrent nodes", id, n)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. One event shape across P4-1, P4-2 and P4-3 — not three
// ─────────────────────────────────────────────────────────────────────────────

func TestP4GovFreezePlaneEmitsOneConsistentEventShape(t *testing.T) {
	target := spawnCycleTarget(t)
	pid := target.Process.Pid

	root := t.TempDir()
	storage := t.TempDir()
	cgDir := mockPodCgroupWithPIDs(t, root, uidUnderscored, pid)

	opID := "spiffe://signalloom.demo/operator/carol"
	reg, priv := newCycleOperator(t, opID)
	srv, telem, _ := newCycleServer(t, root, reg, quarantine.CaptureConfig{
		StorageDir:         storage,
		MaxMemorySizeBytes: 16 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})
	h := srv.routes()

	postJSON(t, h, "/stun", fmt.Sprintf(
		`{"pod_uid":%q,"pod":"agent-shape","namespace":"fe-signalloom-agents","capture_quarantine":true}`, uid),
		authHeader("freeze-token-p4gov"))

	signed := makeSignedTestToken(t, opID, priv, "agent-shape", "fe-signalloom-agents")
	tokenJSON, _ := json.Marshal(signed)
	emulateKernelThaw(t, cgDir)
	postJSON(t, h, "/resume", fmt.Sprintf(
		`{"pod_uid":%q,"pod":"agent-shape","namespace":"fe-signalloom-agents","agent_id":"agent-shape","idempotency_key":"idem-p4gov-shape","token":%s}`,
		uid, tokenJSON), authHeader(string(tokenJSON)))

	evs := emittedEvents(t, telem)
	if len(evs) < 3 {
		t.Fatalf("expected freeze, quarantine and resume events, got %d", len(evs))
	}

	// Every event from every card must carry the same envelope keys. If the
	// three cards had each invented a format, P5-1 would have to reconcile them.
	required := []string{"timestamp", "event", "tier", "frozen", "latency_ms", "pids", "pid_count"}
	families := map[string]bool{}
	for i, ev := range evs {
		for _, k := range required {
			if _, ok := ev[k]; !ok {
				t.Errorf("event %d (%v) is missing shared envelope key %q", i, ev["event"], k)
			}
		}
		name, _ := ev["event"].(string)
		switch {
		case strings.HasPrefix(name, "StunExecution"):
			families["freeze"] = true
		case strings.HasPrefix(name, "QuarantineSnapshot"):
			families["quarantine"] = true
		}
		if tier, _ := ev["tier"].(string); !strings.HasPrefix(tier, "tier-0-") {
			t.Errorf("event %d (%v) carries an off-contract tier %q", i, name, tier)
		}
	}
	if !families["freeze"] {
		t.Error("no P4-1 StunExecution* event observed")
	}
	if !families["quarantine"] {
		t.Error("no P4-2 QuarantineSnapshot* event observed")
	}

	// P4-3's attribution fields must ride the same envelope, not a sidecar record.
	resumed := eventsNamed(evs, telemetry.EventStunExecutionResumed)
	if len(resumed) != 1 {
		t.Fatalf("want 1 resume event, got %d", len(resumed))
	}
	for _, k := range []string{"operator_ids", "token_id"} {
		if _, ok := resumed[0][k]; !ok {
			t.Errorf("P4-3 attribution field %q is absent from the shared event envelope", k)
		}
	}
}
