// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	corev1 "k8s.io/api/core/v1"
)

// captureHarness runs the capture synchronously on each new hold and
// records the trigger it saw, over a fake /proc holding the two pids the
// mock cgroup lists.
type captureHarness struct {
	*holdHarness
	w     *captureWriter
	spool string
	trigs []captureTrigger
	done  chan struct{}
}

func newCaptureHarness(t *testing.T) *captureHarness {
	t.Helper()
	h := newHoldHarness(t)
	spool := t.TempDir()
	proc := t.TempDir()
	for _, pid := range []string{"101", "102"} {
		d := filepath.Join(proc, pid)
		if err := os.MkdirAll(filepath.Join(d, "fd"), 0o755); err != nil {
			t.Fatal(err)
		}
		_ = os.WriteFile(filepath.Join(d, "status"), []byte("Name:\tagent\nState:\tD (disk sleep)\nPid:\t"+pid+"\nPPid:\t1\nVmRSS:\t1024 kB\n"), 0o644)
		_ = os.WriteFile(filepath.Join(d, "cmdline"), []byte("agent\x00--serve\x00"), 0o644)
		_ = os.WriteFile(filepath.Join(d, "maps"), []byte(""), 0o644)
	}
	_ = os.WriteFile(filepath.Join(h.cg, "cpu.stat"), []byte("usage_usec 1234\nuser_usec 1000\nsystem_usec 234\n"), 0o644)
	w := newCaptureWriter(spool, "kusari-prod", "node-a", proc)
	w.now = func() time.Time { return time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC) }
	w.tenantFor = func(*corev1.Pod) string { return "kusari" }
	ch := &captureHarness{holdHarness: h, w: w, spool: spool, done: make(chan struct{}, 4)}
	h.holds.onFreeze = func(pod *corev1.Pod, res *cgroup.FreezeResult, trig captureTrigger) {
		ch.trigs = append(ch.trigs, trig)
		w.capture(context.Background(), pod, res, trig)
		ch.done <- struct{}{}
	}
	return ch
}

func (c *captureHarness) wait(t *testing.T) {
	t.Helper()
	select {
	case <-c.done:
	case <-time.After(scaledDuration(5 * time.Second)):
		t.Fatal("capture did not run")
	}
}

func readManifest(t *testing.T, dir string) wardenCaptureManifest {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(dir, captureManifestFile))
	if err != nil {
		t.Fatal(err)
	}
	var m wardenCaptureManifest
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestLocalFreezeWritesAWardenCaptureWithTheTwoSpecAnalogues(t *testing.T) {
	h := newCaptureHarness(t)
	h.detect()
	h.wait(t)
	if len(h.trigs) != 1 || h.trigs[0].Kind != "local" || h.trigs[0].Syscall != "sys_enter_openat" || h.trigs[0].Target != "/etc/passwd" {
		t.Fatalf("triggers = %+v", h.trigs)
	}
	id := h.trigs[0].StunID
	if !strings.HasPrefix(id, "local-e02fe214-") {
		t.Fatalf("local stun id = %q", id)
	}
	dir := filepath.Join(h.spool, captureSubdir, id)
	m := readManifest(t, dir)
	if m.Kind != captureKind || m.Version != captureVersion || m.StunID != id || m.ClusterID != "kusari-prod" || m.Node != "node-a" {
		t.Fatalf("manifest = %+v", m)
	}
	if m.Pod.Name != h.live.Name || m.Pod.UID != holdPodUID || m.CgroupPath != h.cg || !strings.Contains(m.Relationship, "artifacts 5 and 6") {
		t.Fatalf("manifest = %+v", m)
	}
	if len(m.Artifacts) != 2 || m.Artifacts[0].Name != captureObservationFile || m.Artifacts[1].Name != captureFreezeFile {
		t.Fatalf("artifacts = %+v", m.Artifacts)
	}
	for _, a := range m.Artifacts {
		body, err := os.ReadFile(filepath.Join(dir, a.Name))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(body)
		if hex.EncodeToString(sum[:]) != a.SHA256 || int64(len(body)) != a.Bytes {
			t.Fatalf("%s digest mismatch", a.Name)
		}
	}
	var obs map[string]interface{}
	body, _ := os.ReadFile(filepath.Join(dir, captureObservationFile))
	if err := json.Unmarshal(body, &obs); err != nil {
		t.Fatal(err)
	}
	if obs["syscall"] != "sys_enter_openat" || obs["target"] != "/etc/passwd" || obs["pod_name"] != h.live.Name || obs["cgroup_path"] != h.cg || obs["tenant_id"] != "kusari" || obs["direct_reaction"] != "cgroup_frozen" {
		t.Fatalf("observation = %v", obs)
	}
	freeze, _ := os.ReadFile(filepath.Join(dir, captureFreezeFile))
	text := string(freeze)
	for _, want := range []string{"frozen 1\n", "populated 1\n", "cgroup.procs: 101 102\n", "usage_usec 1234", "cgroup_path: " + h.cg} {
		if !strings.Contains(text, want) {
			t.Fatalf("freeze text lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "frozen 0") {
		t.Fatalf("freeze text must not carry frozen 0:\n%s", text)
	}
	if m.Quarantine.ProcessCount != 2 || m.Quarantine.StoragePath == "" || !strings.HasPrefix(m.Quarantine.StoragePath, filepath.Join(dir, captureQuarantineDir)) {
		t.Fatalf("quarantine = %+v", m.Quarantine)
	}
	if _, err := os.Stat(m.Quarantine.StoragePath); err != nil {
		t.Fatalf("quarantine snapshot dir: %v", err)
	}
	if !strings.Contains(h.log.String(), `"event":"warden_capture_written"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
}

func TestRepeatedLocalDetectionOnAHeldPodDoesNotRecapture(t *testing.T) {
	h := newCaptureHarness(t)
	h.detect()
	h.wait(t)
	h.detect()
	select {
	case <-h.done:
		t.Fatal("a re-freeze of a held pod must not capture again")
	case <-time.After(50 * time.Millisecond):
	}
	if len(h.trigs) != 1 {
		t.Fatalf("triggers = %+v", h.trigs)
	}
}

func TestRemoteFreezeWritesACaptureNamedByTheStunRecord(t *testing.T) {
	h := newCaptureHarness(t)
	if _, err := h.holds.freezeRemote(h.live.DeepCopy(), "st-42", "operator: suspected exfil"); err != nil {
		t.Fatal(err)
	}
	h.wait(t)
	dir := filepath.Join(h.spool, captureSubdir, "st-42")
	m := readManifest(t, dir)
	if m.Trigger.Kind != "remote" || m.Trigger.StunID != "st-42" || m.Trigger.Reason != "operator: suspected exfil" {
		t.Fatalf("trigger = %+v", m.Trigger)
	}
	var obs map[string]interface{}
	body, _ := os.ReadFile(filepath.Join(dir, captureObservationFile))
	_ = json.Unmarshal(body, &obs)
	if obs["syscall"] != "remote_stun" || obs["reason"] != "operator: suspected exfil" || obs["stun_id"] != "st-42" {
		t.Fatalf("observation = %v", obs)
	}
	// The same record again: already held, no second capture.
	if already, err := h.holds.freezeRemote(h.live.DeepCopy(), "st-42", "x"); err != nil || !already {
		t.Fatalf("already=%v err=%v", already, err)
	}
	select {
	case <-h.done:
		t.Fatal("re-asserting the same record must not capture again")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestCaptureRefusesAnUnsafeStunId(t *testing.T) {
	h := newCaptureHarness(t)
	h.w.capture(context.Background(), h.live.DeepCopy(), &cgroup.FreezeResult{CgroupPath: h.cg}, captureTrigger{Kind: "remote", StunID: "../etc"})
	if !strings.Contains(h.log.String(), `"event":"warden_capture_failed"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
	if _, err := os.Stat(filepath.Join(h.spool, "etc")); !os.IsNotExist(err) {
		t.Fatal("traversal must not create anything")
	}
	if ids, _ := h.w.ids(); len(ids) != 0 {
		t.Fatalf("ids = %v", ids)
	}
}

func TestCaptureFailureNeverThawsOrBlocksTheFreeze(t *testing.T) {
	h := newCaptureHarness(t)
	h.w.dir = filepath.Join(h.spool, "unwritable")
	if err := os.WriteFile(h.w.dir, []byte("a file, not a dir"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.detect()
	h.wait(t)
	if !h.frozen() {
		t.Fatal("the freeze stands whatever the capture did")
	}
	if !strings.Contains(h.log.String(), `"event":"warden_capture_failed"`) || !strings.Contains(h.log.String(), "freeze_held_uncaptured") {
		t.Fatalf("log:\n%s", h.log.String())
	}
}

func TestHealthListenerServesCapturesButNeverTheQuarantineDumps(t *testing.T) {
	h := newCaptureHarness(t)
	h.detect()
	h.wait(t)
	id := h.trigs[0].StunID
	srv := newHealthServer(":0", false, t.TempDir(), &atomic.Int64{})
	srv.captures = h.w
	srv.capturesToken = func() string { return "reader-token-123" }
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	get := func(path string) (int, string, string) {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+path, nil)
		req.Header.Set("Authorization", "Bearer reader-token-123")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("Content-Type"), string(b)
	}
	code, ctype, body := get("/captures")
	if code != 200 || !strings.Contains(body, `"`+id+`"`) || ctype != "application/json" {
		t.Fatalf("/captures: %d %s %s", code, ctype, body)
	}
	code, ctype, body = get("/captures/" + id)
	if code != 200 || ctype != "application/json" || !strings.Contains(body, `"kind": "warden-capture"`) {
		t.Fatalf("/captures/<id>: %d %s %s", code, ctype, body)
	}
	code, ctype, body = get("/captures/" + id + "/" + captureFreezeFile)
	if code != 200 || !strings.HasPrefix(ctype, "text/plain") || !strings.Contains(body, "frozen 1") {
		t.Fatalf("freeze artifact: %d %s %s", code, ctype, body)
	}
	if code, _, _ = get("/captures/" + id + "/" + captureObservationFile); code != 200 {
		t.Fatalf("observation artifact: %d", code)
	}
	m := readManifest(t, filepath.Join(h.spool, captureSubdir, id))
	rel, _ := filepath.Rel(filepath.Join(h.spool, captureSubdir, id), m.Quarantine.StoragePath)
	for _, path := range []string{
		"/captures/" + id + "/" + rel + "/manifest.json",
		"/captures/" + id + "/quarantine",
		"/captures/" + id + "/../../remote-stuns",
		"/captures/" + id + "/other.txt",
		"/captures/nope",
	} {
		if code, _, _ := get(path); code != 404 {
			t.Fatalf("%s: want 404, got %d", path, code)
		}
	}
	if resp, _ := http.Post(ts.URL+"/captures/"+id, "text/plain", nil); resp.StatusCode != 405 {
		t.Fatalf("POST: %d", resp.StatusCode)
	}
	bare := newHealthServer(":0", false, t.TempDir(), &atomic.Int64{})
	ts2 := httptest.NewServer(bare.Handler())
	defer ts2.Close()
	if resp, _ := http.Get(ts2.URL + "/captures"); resp.StatusCode != 404 {
		t.Fatalf("no capture writer: %d", resp.StatusCode)
	}
}

func TestLocalStunIDIsSafeAndUnique(t *testing.T) {
	a := localStunID(holdPodUID, time.Unix(0, 1))
	b := localStunID(holdPodUID, time.Unix(0, 2))
	if a == b || !captureIDPattern.MatchString(a) || !strings.HasPrefix(a, "local-e02fe214-") {
		t.Fatalf("a=%q b=%q", a, b)
	}
}

// The captures route is gated twice: the source must be inside the allow-list
// (loopback by default; the warden is hostNetwork, so this is the enforced
// network control) and the request must carry the configured bearer. With no
// token configured the route is disabled.
func TestCapturesRouteRequiresAllowedSourceAndBearer(t *testing.T) {
	h := newCaptureHarness(t)
	h.detect()
	h.wait(t)
	id := h.trigs[0].StunID
	srv := newHealthServer(":0", false, t.TempDir(), &atomic.Int64{})
	srv.captures = h.w
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	do := func(path, bearer string) (int, string) {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+path, nil)
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	// 1. no token configured: disabled, whatever the caller presents.
	if code, body := do("/captures", "anything"); code != 403 || !strings.Contains(body, "captures_disabled") {
		t.Fatalf("no token configured: %d %s", code, body)
	}
	srv.capturesToken = func() string { return "reader-token-123" }
	// 2. missing or wrong bearer: 401, and the id list is not disclosed.
	for _, bearer := range []string{"", "wrong"} {
		if code, body := do("/captures", bearer); code != 401 || strings.Contains(body, id) {
			t.Fatalf("bearer %q: %d %s", bearer, code, body)
		}
	}
	// 3. right bearer from loopback (the httptest client): served.
	if code, body := do("/captures/"+id, "reader-token-123"); code != 200 || !strings.Contains(body, "warden-capture") {
		t.Fatalf("authorised read: %d %s", code, body)
	}
	// 4. right bearer from a source outside the allow-list: refused before
	// the token is even examined, and the body says why.
	allow, err := parseCIDRList("10.42.0.0/16")
	if err != nil {
		t.Fatal(err)
	}
	srv.capturesAllow = allow
	if code, body := do("/captures/"+id, "reader-token-123"); code != 403 || !strings.Contains(body, "captures_source_not_allowed") {
		t.Fatalf("source outside the list: %d %s", code, body)
	}
	// 5. /healthz and /metrics stay open: the gate is on captures only.
	if code, _ := do("/healthz", ""); code != 200 {
		t.Fatalf("/healthz gated by mistake: %d", code)
	}
}

func TestParseCIDRListAcceptsHostsAndRefusesGarbage(t *testing.T) {
	nets, err := parseCIDRList("127.0.0.0/8, 172.19.0.10 ,::1")
	if err != nil || len(nets) != 3 || nets[1].String() != "172.19.0.10/32" || nets[2].String() != "::1/128" {
		t.Fatalf("nets=%v err=%v", nets, err)
	}
	if _, err := parseCIDRList("not-a-network"); err == nil {
		t.Fatal("garbage accepted")
	}
}
